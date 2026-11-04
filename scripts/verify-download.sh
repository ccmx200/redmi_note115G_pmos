#!/bin/bash
# verify-download.sh - shared checksum/signature verification for rootfs downloads.
#
# Sourced by scripts/distro-*.sh:
#     . "$HERE/verify-download.sh"
#
# Why this exists: every distro script downloads a 35 MB .. 830 MB prebuilt
# rootfs tarball from a mirror.  A truncated, corrupted or substituted download
# used to surface much later as a cryptic tar/qemu-user failure inside the
# build; nothing checked it against the hash the distribution publishes next to
# the file.  All three distributions publish one:
#
#   Ubuntu    SHA256SUMS in the same release directory (sha256sum -c format)
#   Fedora    a PGP-signed *-CHECKSUM file in the same images/ directory,
#             with "SHA256 (name) = <hex>" lines
#   Arch ARM  ArchLinuxARM-aarch64-latest.tar.gz.{md5,sig}; the .sig is a
#             detached GPG signature by the Arch Linux ARM Build System key
#             (shipped in config/keys/archlinuxarm.asc)
#
# Behaviour:
#   * a hash/signature mismatch is always a hard failure;
#   * when the published checksum *file* cannot be fetched (mirror without the
#     file, no network to the checksum host), the build prints a loud warning
#     and continues, so an otherwise healthy build is not broken by a mirror
#     quirk.  EVERGO_VERIFY_DOWNLOADS=strict turns that case into a failure and
#     =0 disables verification entirely (debugging only).
#
# Everything logs through printf so the build output stays consistent.
set -u

: "${EVERGO_VERIFY_DOWNLOADS:=1}"

_verify_log() { printf '    %s\n' "$*"; }
_verify_warn() { printf '    !! %s\n' "$*" >&2; }
_verify_die() { printf '    !! %s\n' "$*" >&2; exit 1; }

# verify_download FILE REMOTE_NAME LABEL SUMS_URL...
#
# FILE        local path of the downloaded artifact
# REMOTE_NAME the filename as it appears in the published checksum file
# LABEL       human readable name for messages
# SUMS_URL    one or more URLs of checksum files; each is tried until one
#             contains REMOTE_NAME.  They may use any of the formats above.
verify_download() {
    local file="$1" remote="$2" label="$3"
    shift 3
    local sums_urls=("$@")

    [ -s "$file" ] || _verify_die "$label: $file is missing or empty"

    case "$EVERGO_VERIFY_DOWNLOADS" in
        0|no|off)
            _verify_warn "$label: download verification disabled (EVERGO_VERIFY_DOWNLOADS=0)"
            return 0
            ;;
        strict)
            ;;
        1|yes|on|warn|*)
            ;;
    esac

    local sums_tmp expected actual
    sums_tmp="$(mktemp "${TMPDIR:-/tmp}/evergo-sums.XXXXXX")"

    expected=""
    local url
    for url in "${sums_urls[@]}"; do
        [ -n "$url" ] || continue
        if ! curl -fsSL --max-time 120 -o "$sums_tmp" "$url" 2>/dev/null; then
            _verify_warn "$label: cannot fetch checksum file $url"
            continue
        fi
        # sha256sum format:  "<sha256> *<name>" / "<sha256>  <name>"
        expected="$(awk -v name="$remote" '
            {
                # strip a leading "*" from the filename field (binary marker)
                fn = $2; sub(/^\*/, "", fn)
                if (fn == name) { print $1; exit }
            }' "$sums_tmp")"
        # Fedora CHECKSUM format:  "SHA256 (<name>) = <hex>"
        if [ -z "$expected" ]; then
            expected="$(awk -v name="$remote" '
                index($0, "SHA256 (" name ") = ") == 1 { print $NF; exit }' "$sums_tmp")"
        fi
        [ -n "$expected" ] && break
        _verify_warn "$label: $remote is not listed in $url"
    done

    if [ -z "$expected" ]; then
        rm -f "$sums_tmp"
        if [ "$EVERGO_VERIFY_DOWNLOADS" = strict ]; then
            _verify_die "$label: no published SHA256 for $remote and EVERGO_VERIFY_DOWNLOADS=strict"
        fi
        _verify_warn "$label: NO PUBLISHED SHA256 COULD BE FETCHED - artifact is unverified"
        return 0
    fi

    actual="$(sha256sum "$file" | awk '{print $1}')"
    rm -f "$sums_tmp"
    if [ "$actual" != "$expected" ]; then
        _verify_die "$label: SHA256 MISMATCH for $file
      expected $expected
      actual   $actual
      (truncated download or tampered mirror; remove the file and retry)"
    fi
    _verify_log "$label: sha256 ok ($actual)"
}

# verify_md5 FILE MD5_URL LABEL - published MD5 (Arch publishes one next to the
# tarball; weaker than a SHA256 but catches truncation/corruption).  Same
# fail/warn policy as verify_download.
verify_md5() {
    local file="$1" url="$2" label="$3" tmp expected actual
    case "$EVERGO_VERIFY_DOWNLOADS" in
        0|no|off) return 0 ;;
    esac
    tmp="$(mktemp "${TMPDIR:-/tmp}/evergo-md5.XXXXXX")"
    if ! curl -fsSL --max-time 60 -o "$tmp" "$url" 2>/dev/null; then
        rm -f "$tmp"
        if [ "$EVERGO_VERIFY_DOWNLOADS" = strict ]; then
            _verify_die "$label: cannot fetch MD5 $url and EVERGO_VERIFY_DOWNLOADS=strict"
        fi
        _verify_warn "$label: cannot fetch MD5 $url - artifact is unverified"
        return 0
    fi
    expected="$(awk -v name="$(basename "$file")" '{ print $1; exit }' "$tmp")"
    rm -f "$tmp"
    actual="$(md5sum "$file" | awk '{print $1}')"
    if [ -n "$expected" ] && [ "$actual" != "$expected" ]; then
        _verify_die "$label: MD5 MISMATCH for $file (expected $expected, actual $actual)"
    fi
    _verify_log "$label: md5 ok ($actual)"
}

# verify_gpg_detached FILE SIGNATURE_URL KEY_FILE LABEL - verify a detached GPG
# signature in a throw-away keyring seeded with the distribution's public key.
# A present-but-invalid signature is a hard failure; a missing gpg binary or an
# unreadable signature only warns (the MD5 check still ran).
verify_gpg_detached() {
    local file="$1" sig_url="$2" key_file="$3" label="$4"
    local tmpdir rc
    case "$EVERGO_VERIFY_DOWNLOADS" in
        0|no|off) return 0 ;;
    esac
    if ! command -v gpg >/dev/null 2>&1; then
        _verify_warn "$label: gpg not installed - GPG signature NOT checked"
        return 0
    fi
    if [ ! -s "$key_file" ]; then
        _verify_warn "$label: signing key $key_file missing - GPG signature NOT checked"
        return 0
    fi
    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/evergo-gpg.XXXXXX")"
    if ! curl -fsSL --max-time 60 -o "$tmpdir/artifact.sig" "$sig_url" 2>/dev/null; then
        rm -rf "$tmpdir"
        _verify_warn "$label: cannot fetch signature $sig_url - GPG signature NOT checked"
        return 0
    fi
    # gpg requires GNUPGHOME to exist with 0700 permissions; it will not create a
    # missing directory itself in batch mode ("no writable keyring found").
    mkdir -p "$tmpdir/gnupg"
    chmod 700 "$tmpdir/gnupg"
    if ! GNUPGHOME="$tmpdir/gnupg" gpg --batch --quiet --import "$key_file" 2>/dev/null; then
        rm -rf "$tmpdir"
        _verify_warn "$label: cannot import $key_file - GPG signature NOT checked"
        return 0
    fi
    GNUPGHOME="$tmpdir/gnupg" gpg --batch --quiet --verify \
        "$tmpdir/artifact.sig" "$file" >/dev/null 2>&1
    rc=$?
    rm -rf "$tmpdir"
    if [ "$rc" != 0 ]; then
        _verify_die "$label: GPG SIGNATURE INVALID for $file (bad mirror response?)"
    fi
    _verify_log "$label: gpg signature ok"
}
