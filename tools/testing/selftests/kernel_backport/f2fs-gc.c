// SPDX-License-Identifier: GPL-2.0
/* Synchronous GC requests for disposable F2FS filesystems inside the guest. */
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <linux/f2fs.h>
#include <linux/magic.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/vfs.h>
#include <unistd.h>

/* Match the native ARM64 ABI in this tree's fs/f2fs/f2fs.h. */
_Static_assert(sizeof(struct f2fs_gc_range) == 24, "GC range ABI");
_Static_assert(offsetof(struct f2fs_gc_range, start) == 8, "GC start ABI");
_Static_assert(offsetof(struct f2fs_gc_range, len) == 16, "GC length ABI");
_Static_assert(F2FS_IOC_GARBAGE_COLLECT == 0x4004f506UL, "GC ioctl ABI");
_Static_assert(F2FS_IOC_GARBAGE_COLLECT_RANGE == 0x4018f50bUL,
	       "GC range ioctl ABI");

static void usage(FILE *stream)
{
	fputs("Usage: f2fs-gc gc MOUNTPOINT\n"
	      "       f2fs-gc range MOUNTPOINT START_BLOCK BLOCK_COUNT\n"
	      "       f2fs-gc --help\n"
	      "Run only on a disposable mounted F2FS fixture in the guest.\n"
	      "Both operations request synchronous GC. Range units are physical\n"
	      "4096-byte filesystem blocks, expressed as decimal integers.\n"
	      "GC moves whole sections; align the start to a section boundary.\n"
	      "Exit: 0 ioctl completed, 1 error, 2 usage, 3 EAGAIN, 4 ENODATA.\n"
	      "A completed ioctl alone does not prove data was relocated.\n",
	      stream);
}

static int parse_number(const char *text, uint64_t *value)
{
	char *end;
	unsigned long long parsed;

	if (*text < '0' || *text > '9')
		return -1;
	errno = 0;
	parsed = strtoull(text, &end, 10);
	if (errno || *end)
		return -1;
	*value = parsed;
	return 0;
}

static int report_error(const char *operation, int error)
{
	if (error == EAGAIN) {
		fprintf(stderr, "F2FS_GC_RETRY: %s: EAGAIN; full section not freed, movement unverified\n",
			operation);
		return 3;
	}
	if (error == ENODATA) {
		fprintf(stderr, "F2FS_GC_NO_VICTIM: %s: ENODATA; no eligible victim\n",
			operation);
		return 4;
	}
	fprintf(stderr, "F2FS_GC_ERROR: %s: errno=%d (%s)\n",
		operation, error, strerror(error));
	return 1;
}

int main(int argc, char **argv)
{
	struct f2fs_gc_range range = { .sync = 1 };
	struct statfs filesystem;
	uint64_t start = 0, count = 0;
	uint32_t sync = 1;
	int ranged, fd, ret, saved_errno;

	if (argc == 2 && !strcmp(argv[1], "--help")) {
		usage(stdout);
		return 0;
	}
	if (argc == 3 && !strcmp(argv[1], "gc")) {
		ranged = 0;
	} else if (argc == 5 && !strcmp(argv[1], "range")) {
		ranged = 1;
		if (parse_number(argv[3], &start) ||
		    parse_number(argv[4], &count) || !count ||
		    start > UINT64_MAX - (count - 1)) {
			fputs("f2fs-gc: invalid or overflowing block range\n", stderr);
			return 2;
		}
		range.start = start;
		/* This tree visits sections while start <= original start + len. */
		range.len = count - 1;
	} else {
		usage(stderr);
		return 2;
	}

	fd = open(argv[2], O_RDONLY | O_DIRECTORY | O_CLOEXEC);
	if (fd < 0)
		return report_error("open mount point", errno);
	if (fstatfs(fd, &filesystem) < 0) {
		ret = report_error("inspect filesystem", errno);
		close(fd);
		return ret;
	}
	if ((unsigned long)filesystem.f_type != F2FS_SUPER_MAGIC) {
		fputs("F2FS_GC_ERROR: mount point is not F2FS\n", stderr);
		close(fd);
		return 1;
	}

	if (ranged)
		ret = ioctl(fd, F2FS_IOC_GARBAGE_COLLECT_RANGE, &range);
	else
		ret = ioctl(fd, F2FS_IOC_GARBAGE_COLLECT, &sync);
	saved_errno = errno;
	if (close(fd) < 0 && ret == 0)
		return report_error("close mount point", errno);
	if (ret < 0)
		return report_error(argv[1], saved_errno);

	if (ranged)
		printf("F2FS_GC_IOCTL_DONE: range start=%" PRIu64 " blocks=%" PRIu64
		       " sync=1 movement=unverified\n", start, count);
	else
		puts("F2FS_GC_IOCTL_DONE: gc sync=1 movement=unverified");
	return 0;
}
