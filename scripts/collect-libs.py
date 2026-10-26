#!/usr/bin/env python3
"""Copy an aarch64 binary and its shared-library closure into an initramfs tree.

The initramfs in this build is busybox-static only, so a dynamically linked tool such as
resize.f2fs needs its interpreter and every NEEDED library copied in at the same paths.
readelf is architecture agnostic, so this runs on the x86 build host against binaries
that were extracted from the aarch64 rootfs.

Usage: collect-libs.py <rootfs> <binary-in-rootfs> <dest-dir>
Example: collect-libs.py out/work/rootfs /usr/sbin/resize.f2fs out/work/initramfs
"""
import os
import shutil
import subprocess
import sys

SEARCH_DIRS = ("lib", "usr/lib", "lib64", "usr/lib64")


def readelf(args, path):
    try:
        return subprocess.run(
            ["readelf"] + args + [path],
            capture_output=True, text=True, check=False,
        ).stdout
    except FileNotFoundError:
        raise SystemExit("readelf is required (binutils)")


def needed(path):
    libs = []
    for line in readelf(["-d"], path).splitlines():
        if "(NEEDED)" in line and "[" in line:
            libs.append(line.split("[", 1)[1].split("]", 1)[0].strip())
    return libs


def interpreter(path):
    for line in readelf(["-l"], path).splitlines():
        if "Requesting program interpreter" in line:
            return line.split(":", 1)[1].strip().rstrip("]")
    return None


def find_in_rootfs(rootfs, name):
    for d in SEARCH_DIRS:
        # a name may be a versioned symlink target, so glob the directory
        base = os.path.join(rootfs, d)
        if not os.path.isdir(base):
            continue
        direct = os.path.join(base, name)
        if os.path.exists(direct):
            return os.path.join(d, name)
        for entry in sorted(os.listdir(base)):
            if entry == name or entry.startswith(name + "."):
                return os.path.join(d, entry)
    # fall back to a walk (some distros nest under usr/lib/<triple>)
    for dirpath, _dirnames, filenames in os.walk(rootfs):
        for f in filenames:
            if f == name:
                return os.path.relpath(os.path.join(dirpath, f), rootfs)
    return None


def main():
    if len(sys.argv) < 4:
        raise SystemExit(__doc__)
    rootfs, binary, dest = sys.argv[1], sys.argv[2], sys.argv[3]
    src = os.path.join(rootfs, binary.lstrip("/"))
    if not os.path.isfile(src):
        raise SystemExit(f"not found in rootfs: {binary}")

    # the binary itself
    out_bin = os.path.join(dest, binary.lstrip("/"))
    os.makedirs(os.path.dirname(out_bin), exist_ok=True)
    shutil.copy2(src, out_bin)
    os.chmod(out_bin, 0o755)
    print(f"  copied {binary}")

    queue = []
    interp = interpreter(src)
    if interp:
        queue.append(interp)
    queue.extend(needed(src))

    seen = set()
    missing = []
    while queue:
        name = queue.pop(0)
        if name in seen:
            continue
        seen.add(name)

        rel = find_in_rootfs(rootfs, os.path.basename(name))
        if rel is None:
            missing.append(name)
            continue
        real = os.path.join(rootfs, rel)
        if not os.path.exists(real):
            missing.append(name)
            continue

        # Arch keeps its libraries in /usr/lib with /lib a symlink to it, and the ELF
        # interpreter asks for /lib/ld-linux-aarch64.so.1 - so place every library at
        # /usr/lib/<soname>; the initramfs makes /lib a symlink to usr/lib.
        out = os.path.join(dest, "usr/lib", os.path.basename(rel))
        os.makedirs(os.path.dirname(out), exist_ok=True)
        if not os.path.exists(out):
            shutil.copy2(os.path.realpath(real), out)
            print(f"  copied {rel} -> usr/lib/{os.path.basename(rel)}")

        for sub in needed(os.path.realpath(real)):
            if sub not in seen:
                queue.append(sub)

    if missing:
        print("  MISSING: " + ", ".join(missing))
        raise SystemExit(1)
    print(f"  {len(seen)} libraries/bits copied")


if __name__ == "__main__":
    main()
