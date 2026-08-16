// SPDX-License-Identifier: GPL-2.0
/*
 * Small static arm64 loader for the 4.9 sched_ext diagnostics hook.
 *
 * It loads a verifier-safe no-op tracepoint BPF program with bpf(2), hands its
 * fd to the kernel through program_fd, and then enables the watchdog.  EEVDF
 * remains the scheduler; unload, timeout, or a kernel-side error disables the
 * hook.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/bpf.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

#define SCX_ROOT "/sys/kernel/sched_ext"
#define SCX_ENABLE SCX_ROOT "/enable"
#define SCX_PROGRAM_FD SCX_ROOT "/program_fd"
#define SCX_STATE SCX_ROOT "/state"
#define SCX_HEARTBEAT SCX_ROOT "/heartbeat"

static volatile sig_atomic_t stop;

static void on_signal(int signo)
{
	(void)signo;
	stop = 1;
}

static int write_value(const char *path, const char *value)
{
	int fd = open(path, O_WRONLY | O_CLOEXEC);
	ssize_t len;

	if (fd < 0) {
		fprintf(stderr, "%s: %s\n", path, strerror(errno));
		return -1;
	}
	len = write(fd, value, strlen(value));
	close(fd);
	if (len != (ssize_t)strlen(value)) {
		fprintf(stderr, "%s: %s\n", path, strerror(errno));
		return -1;
	}
	return 0;
}

static int read_value(const char *path, char *buf, size_t size)
{
	int fd = open(path, O_RDONLY | O_CLOEXEC);
	ssize_t len;

	if (fd < 0) {
		fprintf(stderr, "%s: %s\n", path, strerror(errno));
		return -1;
	}
	len = read(fd, buf, size - 1);
	close(fd);
	if (len < 0) {
		fprintf(stderr, "%s: %s\n", path, strerror(errno));
		return -1;
	}
	buf[len] = '\0';
	return 0;
}

static int load_noop_program(void)
{
	static const struct bpf_insn insns[] = {
		{
			.code = BPF_ALU64 | BPF_MOV | BPF_K,
			.dst_reg = BPF_REG_0,
			.imm = 0,
		},
		{
			.code = BPF_JMP | BPF_EXIT,
		},
	};
	static char log_buf[4096];
	union bpf_attr attr;
	const char license[] = "GPL";
	int fd;

	memset(&attr, 0, sizeof(attr));
	attr.prog_type = BPF_PROG_TYPE_TRACEPOINT;
	attr.insn_cnt = (uint32_t)(sizeof(insns) / sizeof(insns[0]));
	attr.insns = (uint64_t)(uintptr_t)insns;
	attr.license = (uint64_t)(uintptr_t)license;
	attr.log_buf = (uint64_t)(uintptr_t)log_buf;
	attr.log_size = sizeof(log_buf);
	attr.log_level = 1;

	fd = syscall(SYS_bpf, BPF_PROG_LOAD, &attr, sizeof(attr));
	if (fd < 0) {
		fprintf(stderr, "BPF_PROG_LOAD: %s\n%s", strerror(errno), log_buf);
		return -1;
	}
	return fd;
}

static int attach_noop_program(void)
{
	char fd_text[32];
	int fd;

	fd = load_noop_program();
	if (fd < 0)
		return -1;
	(void)snprintf(fd_text, sizeof(fd_text), "%d\n", fd);
	if (write_value(SCX_PROGRAM_FD, fd_text)) {
		close(fd);
		return -1;
	}
	close(fd); /* the kernel now owns its reference */
	return 0;
}

static int load_extension(void)
{
	if (attach_noop_program())
		return -1;
	return write_value(SCX_ENABLE, "1\n");
}

static int unload_extension(void)
{
	int ret;

	ret = write_value(SCX_ENABLE, "0\n");
	if (write_value(SCX_PROGRAM_FD, "0\n"))
		ret = -1;
	return ret;
}

static int run_owner(void)
{
	char state[32];

	signal(SIGINT, on_signal);
	signal(SIGTERM, on_signal);
	while (!stop) {
		if (write_value(SCX_HEARTBEAT, "1\n"))
			return 1;
		if (!read_value(SCX_STATE, state, sizeof(state)) &&
		    !strncmp(state, "error", 5))
			return 1;
		sleep(1);
	}
	return unload_extension() ? 1 : 0;
}

static void usage(const char *name)
{
	fprintf(stderr,
		"usage: %s [--load|--unload|--status|--run]\n"
		"  --load    load a no-op BPF hook and enable the watchdog\n"
		"  --unload  detach the hook and restore EEVDF\n"
		"  --status  print the kernel state\n"
		"  --run     load, enable, and send watchdog heartbeats\n", name);
}

int main(int argc, char **argv)
{
	char state[32];
	const char *op;

	if (argc != 2) {
		usage(argv[0]);
		return 2;
	}
	op = argv[1];
	if (!strcmp(op, "--load"))
		return load_extension() ? 1 : 0;
	if (!strcmp(op, "--unload"))
		return unload_extension() ? 1 : 0;
	if (!strcmp(op, "--status")) {
		if (read_value(SCX_STATE, state, sizeof(state)))
			return 1;
		fputs(state, stdout);
		return 0;
	}
	if (!strcmp(op, "--run")) {
		if (load_extension())
			return 1;
		return run_owner();
	}
	usage(argv[0]);
	return 2;
}
