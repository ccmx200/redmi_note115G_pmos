// SPDX-License-Identifier: GPL-2.0
/*
 * wmt-init - bring up the MediaTek CONNSYS block on the evergo (MT6833) and
 *            serve the WMT ROM-patch launcher, so the built-in gen4m WLAN
 *            driver can create wlan0.
 *
 * The vendor stack drives this from two Android daemons:
 *   wmt_loader   -> /dev/wmtdetect : chip detect, CONN hardware init, module init
 *   wmt_launcher -> /dev/stpwmt    : WMT config name, STP mode, and a responder
 *                                    loop that answers "srh_rom_patch" with the
 *                                    ROM-patch descriptors for the CONNSYS MCU,
 *                                    Bluetooth and WiFi images
 * Both are reimplemented here, because the pmos images have neither an Android
 * userspace nor a shell script that could do raw ioctls.
 *
 * The CONN firmware itself (WMT_SOC.cfg + soc2_2_ram_{mcu,bt,wifi}_1_1_hdr.bin)
 * is read from /lib/firmware: the launcher only passes the descriptor (type and
 * load address) to the kernel, the kernel then request_firmware()s the file by
 * name.  WIFI_RAM_CODE_soc2_2_1a_1.bin (the gen4m firmware body) is fetched by
 * the WLAN driver from the same directory, or from the kernel's built-in
 * firmware copy if it was embedded at build time.
 *
 * The device sequence was taken from the author's bring-up init for this board
 * (KevinLmK0702/initramfs, init.c, GPL-2.0) and is what was verified on real
 * hardware:
 *
 *   1. /dev/wmtdetect COMBO_IOCTL_CONNSYS_SOC_HW_INIT
 *      -> mtk_wcn_consys_hw_init(): platform driver register + probe, CONN
 *         MTCMOS on, A-die identification, EMI window published
 *   2. COMBO_IOCTL_GET_SOC_CHIP_ID, COMBO_IOCTL_SET_CHIP_ID
 *   3. COMBO_IOCTL_DO_MODULE_INIT(chip)
 *      -> WMT core (/dev/stpwmt) init.  Do NOT call GET_ADIE_CHIP_ID before
 *         this: it runs the A-die flow, which ends in consys_dl_rom_patch() ->
 *         wmt_ctrl() and that dereferences the WMT wake-up queue, which only
 *         exists after the core is up (observed as a NULL dereference in
 *         __wake_up_common during bring-up).
 *   4. /dev/stpwmt: WMT_IOCTL_WMT_CFG_NAME "WMT_SOC.cfg",
 *      WMT_IOCTL_SET_STP_MODE 0x23, then answer "srh_rom_patch" requests.
 *   5. /dev/wmtWifi write "1" -> mtk_wcn_wmt_func_on(WIFI) -> CONN power-on,
 *      ROM patch download, gen4m firmware download, hifAxiProbe() -> wlan0.
 *
 * The launcher loop must stay alive for the whole uptime: the WMT core asks it
 * again on every WiFi power cycle.  Run it as a systemd service (Type=simple);
 * the process never exits on its own.
 */

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#ifndef _IOW
#include <asm/ioctl.h>
#endif

#define WMT_DETECT_IOC_MAGIC		'w'
#define COMBO_IOCTL_SET_CHIP_ID		_IOW(WMT_DETECT_IOC_MAGIC, 1, int)
#define COMBO_IOCTL_GET_SOC_CHIP_ID	_IOR(WMT_DETECT_IOC_MAGIC, 3, int)
#define COMBO_IOCTL_DO_MODULE_INIT	_IOR(WMT_DETECT_IOC_MAGIC, 4, int)
#define COMBO_IOCTL_CONNSYS_SOC_HW_INIT	_IOR(WMT_DETECT_IOC_MAGIC, 10, int)

#define WMT_IOC_MAGIC			0xa0
#define WMT_IOCTL_SET_STP_MODE		_IOW(WMT_IOC_MAGIC, 5, int)
#define WMT_IOCTL_SET_ROM_PATCH_INFO	_IOW(WMT_IOC_MAGIC, 31, char *)
#define WMT_IOCTL_WMT_CFG_NAME		_IOWR(WMT_IOC_MAGIC, 21, char *)

/* STP_BTIF_FULL | (WMT_FM_COM << 4), the value the Android launcher sets */
#define STP_MODE_BTIF			0x23

#define FW_DIR				"/lib/firmware"
#define WMT_CFG_FILE			"WMT_SOC.cfg"

#define LOCK_FILE			"/run/wmt-init.lock"
#define WIFI_IFACE			"wlan0"
#define WIFI_POWER_WAIT_MS		20000
#define CONN_SOC_CHIP_ID_DEFAULT	0x6833

/*
 * What WMT_IOCTL_SET_ROM_PATCH_INFO expects: a 4-byte type, the 4-byte load
 * address exactly as it appears at offset 0x18..0x20 of the
 * soc2_2_ram_*_hdr.bin header, then the file name.
 */
struct wmt_rom_patch_info {
	unsigned int type;
	char addr[4];
	char name[256];
};

static const char *const conn_ram_patch[] = { "mcu", "bt", "wifi" };

static int verbose = 1;

static void msg(const char *fmt, ...)
{
	va_list ap;
	char buf[512];
	int n;
	int kfd;

	va_start(ap, fmt);
	n = vsnprintf(buf, sizeof(buf), fmt, ap);
	va_end(ap);
	if (n < 0)
		return;
	if (n > (int)sizeof(buf) - 1)
		n = sizeof(buf) - 1;

	if (verbose) {
		fputs(buf, stdout);
		fflush(stdout);
	}

	/* also drop it into the kernel log so a boot problem is visible in dmesg */
	kfd = open("/dev/kmsg", O_WRONLY | O_CLOEXEC);
	if (kfd >= 0) {
		char line[560];
		int m = snprintf(line, sizeof(line), "wmt-init: %s", buf);

		if (m > 0 && write(kfd, line, m) < 0) {
			/* best effort: the kernel log is only for diagnostics */
		}
		close(kfd);
	}
}

static int msleep(unsigned int ms)
{
	struct timespec ts = { ms / 1000, (ms % 1000) * 1000000L };

	return nanosleep(&ts, NULL);
}

static int netif_exists(const char *iface)
{
	char path[128];

	snprintf(path, sizeof(path), "/sys/class/net/%s", iface);
	return access(path, F_OK) == 0;
}

/*
 * Read the patch descriptor out of soc2_2_ram_<x>_1_1_hdr.bin and hand it to
 * the WMT core.  The header carries the descriptor at 0x18: byte 7 is the
 * image type, bytes 1..3 are the load address in big-endian order.
 */
static int wmt_rom_patch_info(int fd, const char *dir)
{
	unsigned char hdr[32];
	char path[160];
	int i, ok = 0;

	for (i = 0; i < (int)(sizeof(conn_ram_patch) / sizeof(conn_ram_patch[0])); i++) {
		struct wmt_rom_patch_info info;
		const unsigned char *p;
		int f, n;

		snprintf(path, sizeof(path), "%s/soc2_2_ram_%s_1_1_hdr.bin",
			 dir, conn_ram_patch[i]);
		f = open(path, O_RDONLY | O_CLOEXEC);
		if (f < 0) {
			msg("conn: %s: %s\n", path, strerror(errno));
			continue;
		}
		n = read(f, hdr, sizeof(hdr));
		close(f);
		if (n < 32) {
			msg("conn: %s: short header\n", path);
			continue;
		}

		p = hdr + 0x18;
		memset(&info, 0, sizeof(info));
		info.type = p[7];
		info.addr[0] = 0;
		info.addr[1] = (char)p[1];
		info.addr[2] = (char)p[2];
		info.addr[3] = (char)p[3];
		snprintf(info.name, sizeof(info.name), "soc2_2_ram_%s_1_1_hdr.bin",
			 conn_ram_patch[i]);

		if (ioctl(fd, WMT_IOCTL_SET_ROM_PATCH_INFO, &info) < 0)
			msg("conn: rom patch %s: %s\n", conn_ram_patch[i],
			    strerror(errno));
		else
			ok++;
	}
	return ok;
}

/*
 * Answer the WMT core's request strings.  The kernel side blocks in read() on
 * /dev/stpwmt until we write a reply, so a reply must always be produced.
 */
static void launcher_loop(int fd)
{
	char cmd[256];
	char cfg[256];

	memset(cfg, 0, sizeof(cfg));
	snprintf(cfg, sizeof(cfg), "%s", WMT_CFG_FILE);
	if (ioctl(fd, WMT_IOCTL_WMT_CFG_NAME, cfg) < 0)
		msg("conn: WMT_CFG_NAME %s: %s\n", cfg, strerror(errno));

	if (ioctl(fd, WMT_IOCTL_SET_STP_MODE, STP_MODE_BTIF) < 0)
		msg("conn: SET_STP_MODE: %s\n", strerror(errno));

	msg("conn launcher ready\n");

	for (;;) {
		fd_set rfds;
		struct timeval tv;
		int r;

		FD_ZERO(&rfds);
		FD_SET(fd, &rfds);
		tv.tv_sec = 5;
		tv.tv_usec = 0;
		r = select(fd + 1, &rfds, NULL, NULL, &tv);
		if (r < 0) {
			if (errno == EINTR)
				continue;
			msg("conn: select: %s\n", strerror(errno));
			_exit(2);
		}
		if (r == 0)
			continue;

		memset(cmd, 0, sizeof(cmd));
		r = read(fd, cmd, sizeof(cmd) - 1);
		if (r < 0) {
			if (errno == EINTR)
				continue;
			msg("conn: read: %s\n", strerror(errno));
			_exit(2);
		}
		if (r == 0) {
			msleep(100);
			continue;
		}
		cmd[sizeof(cmd) - 1] = '\0';

		if (!strcmp(cmd, "srh_rom_patch")) {
			int n = wmt_rom_patch_info(fd, FW_DIR);

			if (write(fd, n ? "ok" : "fail", n ? 2 : 4) < 0)
				msg("conn: reply rom_patch: %s\n", strerror(errno));
		} else if (!strcmp(cmd, "srh_patch")) {
			/* no separate patch file: the ROM patches carry it */
			if (write(fd, "fail", 4) < 0)
				msg("conn: reply patch: %s\n", strerror(errno));
		} else {
			/* any other request is just acknowledged */
			if (write(fd, "ok", 2) < 0)
				msg("conn: reply: %s\n", strerror(errno));
		}
	}
}

/* 1. CONN hardware init, 2. WMT core init.  Returns 0 on success. */
static int conn_module_init(void)
{
	int fd, chip, ret = 0;

	fd = open("/dev/wmtdetect", O_RDWR | O_CLOEXEC);
	if (fd < 0) {
		msg("open /dev/wmtdetect: %s\n", strerror(errno));
		return -1;
	}

	/* CONN hardware init: MTCMOS, A-die identify, EMI window */
	if (ioctl(fd, COMBO_IOCTL_CONNSYS_SOC_HW_INIT) < 0) {
		msg("CONNSYS_SOC_HW_INIT: %s\n", strerror(errno));
		ret = -1;
		goto out;
	}

	chip = ioctl(fd, COMBO_IOCTL_GET_SOC_CHIP_ID);
	if (chip < 0) {
		msg("GET_SOC_CHIP_ID: %s, assuming 0x%x\n", strerror(errno),
		    CONN_SOC_CHIP_ID_DEFAULT);
		chip = CONN_SOC_CHIP_ID_DEFAULT;
	}
	msg("soc chip id 0x%x\n", chip);

	if (ioctl(fd, COMBO_IOCTL_SET_CHIP_ID, chip) < 0)
		msg("SET_CHIP_ID: %s\n", strerror(errno));

	/* WMT core: creates /dev/stpwmt and starts the wmt daemon threads */
	if (ioctl(fd, COMBO_IOCTL_DO_MODULE_INIT, chip) < 0) {
		msg("DO_MODULE_INIT: %s\n", strerror(errno));
		ret = -1;
	}
out:
	close(fd);
	return ret;
}

static int wifi_power_on(void)
{
	int fd, ret = 0;
	unsigned int i;

	if (netif_exists(WIFI_IFACE)) {
		msg("%s already present\n", WIFI_IFACE);
		return 0;
	}

	fd = open("/dev/wmtWifi", O_WRONLY | O_CLOEXEC);
	if (fd < 0) {
		msg("open /dev/wmtWifi: %s\n", strerror(errno));
		return -1;
	}
	if (write(fd, "1", 1) != 1) {
		msg("WiFi power-on: %s\n", strerror(errno));
		ret = -1;
	}
	close(fd);
	if (ret)
		return ret;

	for (i = 0; i < WIFI_POWER_WAIT_MS / 100; i++) {
		if (netif_exists(WIFI_IFACE)) {
			msg("%s is up\n", WIFI_IFACE);
			return 0;
		}
		msleep(100);
	}
	msg("%s did not appear after %d ms\n", WIFI_IFACE, WIFI_POWER_WAIT_MS);
	return -1;
}

/* The launcher has to outlive the parent; the parent waits for it so that a
 * systemd service can supervise the pair. */
static void serve_launcher(int ready_fd)
{
	int fd;
	int i;

	/* /dev/stpwmt is created by COMBO_IOCTL_DO_MODULE_INIT, so retry briefly:
	 * the parent has already returned from that ioctl, but udev may still be
	 * catching up on the device node. */
	for (i = 0; i < 100; i++) {
		fd = open("/dev/stpwmt", O_RDWR | O_NOCTTY | O_CLOEXEC);
		if (fd >= 0)
			break;
		msleep(100);
	}
	if (fd < 0) {
		msg("open /dev/stpwmt: %s\n", strerror(errno));
		if (ready_fd >= 0 && write(ready_fd, "E", 1) < 0) {
			/* parent will time out */
		}
		exit(1);
	}
	if (ready_fd >= 0) {
		if (write(ready_fd, "R", 1) < 0) {
			/* parent will time out; still serve */
		}
		close(ready_fd);
	}
	launcher_loop(fd);	/* never returns */
}

static int lock_instance(void)
{
	int fd = open(LOCK_FILE, O_CREAT | O_RDWR | O_CLOEXEC, 0600);

	if (fd < 0)
		return -1;
	if (flock(fd, LOCK_EX | LOCK_NB) < 0) {
		if (errno == EWOULDBLOCK)
			msg("already running\n");
		return -1;
	}
	/* keep the fd open for the process lifetime */
	return 0;
}

int main(int argc, char **argv)
{
	int conn_only = 0;
	pid_t child;
	int status;
	int i;
	int ready_pipe[2] = { -1, -1 };
	char ready = 0;
	int waited = 0;

	for (i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--conn-only"))
			conn_only = 1;
		else if (!strcmp(argv[i], "--shutdown"))
			/* nothing to tear down: the WMT core has no exit path */
			return 0;
		else if (!strcmp(argv[i], "--quiet"))
			verbose = 0;
	}

	if (lock_instance() < 0)
		return 0;

	msg("initialising CONNSYS\n");
	if (conn_module_init() < 0) {
		msg("CONN/WMT init failed\n");
		return 1;
	}
	msg("CONN/WMT core up\n");

	/* The responder has to exist before the WMT core asks for patches, which
	 * happens while the WiFi function is being powered on. */
	if (pipe(ready_pipe) < 0)
		ready_pipe[0] = ready_pipe[1] = -1;
	child = fork();
	if (child == 0) {
		if (ready_pipe[0] >= 0)
			close(ready_pipe[0]);
		serve_launcher(ready_pipe[1]);	/* does not return */
	}
	if (child < 0) {
		msg("fork: %s\n", strerror(errno));
		if (conn_only)
			return 1;
		/* no separate process: still serve from here */
		if (wifi_power_on() < 0)
			msg("WiFi power-on failed\n");
		serve_launcher(-1);
	}

	if (ready_pipe[0] >= 0) {
		close(ready_pipe[1]);
		while (waited < 100) {
			struct pollfd pfd;
			int pr;

			pfd.fd = ready_pipe[0];
			pfd.events = POLLIN;
			pr = poll(&pfd, 1, 100);
			waited++;
			if (pr > 0) {
				if (read(ready_pipe[0], &ready, 1) == 1)
					break;
			}
		}
		close(ready_pipe[0]);
		if (ready == 'R')
			msg("conn launcher ready\n");
		else
			msg("conn launcher not ready yet, powering on anyway\n");
	}

	msleep(300);

	if (!conn_only) {
		msg("powering WiFi on\n");
		if (wifi_power_on() < 0)
			msg("WiFi power-on failed, launcher stays up\n");
	}

	/* Stay alive as the parent of the launcher; restart it if it dies. */
	for (;;) {
		if (waitpid(child, &status, 0) == child) {
			msg("launcher exited, status %d\n", status);
			child = fork();
			if (child == 0)
				serve_launcher(-1);
			if (child < 0)
				return 1;
			continue;
		}
		if (errno == EINTR)
			continue;
		msleep(1000);
	}
}
