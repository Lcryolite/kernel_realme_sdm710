// SPDX-License-Identifier: GPL-2.0
/* Public-interface fscrypt v1 fixture for disposable guest filesystems. */
#include <errno.h>
#include <fcntl.h>
#include <linux/fscrypt.h>
#include <linux/keyctl.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#include <unistd.h>

/* Match this tree's legacy struct fscrypt_policy and struct fscrypt_key. */
_Static_assert(sizeof(struct fscrypt_policy_v1) == 12, "policy ABI");
_Static_assert(sizeof(struct fscrypt_key) == 72, "key ABI");
_Static_assert(offsetof(struct fscrypt_key, raw) == 4, "key data ABI");
_Static_assert(offsetof(struct fscrypt_key, size) == 68, "key size ABI");
_Static_assert(FSCRYPT_POLICY_V1 == 0, "v1 policy version");
_Static_assert(FSCRYPT_MODE_AES_256_XTS == 1, "contents mode");
_Static_assert(FSCRYPT_MODE_AES_256_CTS == 4, "filenames mode");
_Static_assert(FS_IOC_SET_ENCRYPTION_POLICY == 0x800c6613UL, "set policy ABI");
_Static_assert(FS_IOC_GET_ENCRYPTION_POLICY == 0x400c6615UL, "get policy ABI");

/* "backport", encoded as eight descriptor bytes and lowercase hexadecimal. */
static const char key_description[] = "fscrypt:6261636b706f7274";
static const struct fscrypt_policy_v1 test_policy = {
	.version = FSCRYPT_POLICY_V1,
	.contents_encryption_mode = FSCRYPT_MODE_AES_256_XTS,
	.filenames_encryption_mode = FSCRYPT_MODE_AES_256_CTS,
	.flags = 0,
	.master_key_descriptor = { 'b', 'a', 'c', 'k', 'p', 'o', 'r', 't' },
};

static int fail(const char *operation)
{
	fprintf(stderr, "fscrypt-test: %s: %s\n", operation, strerror(errno));
	return 1;
}

static void usage(FILE *stream)
{
	fputs("Usage: fscrypt-test session COMMAND [ARG...]\n"
	      "       fscrypt-test add-known-key | add-wrong-key | remove-key\n"
	      "       fscrypt-test set-policy DIR | verify-policy PATH\n"
	      "       fscrypt-test --help\n"
	      "Run key operations inside the session command's descendants.\n"
	      "Keys are public test fixtures, never production credentials.\n",
	      stream);
}

static int enter_session(char **command)
{
	/* NULL creates a fresh anonymous ring inherited across fork and exec. */
	if (syscall(SYS_keyctl, KEYCTL_JOIN_SESSION_KEYRING,
		    NULL, 0L, 0L, 0L) < 0)
		return fail("create session keyring");
	execvp(command[0], command);
	return fail("exec session command");
}

static int add_test_key(int wrong)
{
	struct fscrypt_key key = {
		.mode = FSCRYPT_MODE_AES_256_XTS,
		.size = FSCRYPT_MAX_KEY_SIZE,
	};
	size_t i;

	/* Deterministic, deliberately public fixtures; neither is a real key. */
	for (i = 0; i < sizeof(key.raw); i++)
		key.raw[i] = (unsigned char)(i + (wrong ? 0x80 : 1));

	if (syscall(SYS_add_key, "logon", key_description,
		    &key, sizeof(key), (long)KEY_SPEC_SESSION_KEYRING) < 0)
		return fail("add test key");
	return 0;
}

static int remove_test_key(void)
{
	long serial;

	serial = syscall(SYS_keyctl, KEYCTL_SEARCH,
			 (long)KEY_SPEC_SESSION_KEYRING,
			 "logon", key_description, 0L);
	if (serial < 0)
		return fail("find test key");
	/* Revoke while the session link still grants possession of the key. */
	if (syscall(SYS_keyctl, KEYCTL_REVOKE, serial, 0L, 0L, 0L) < 0)
		return fail("revoke test key");
	if (syscall(SYS_keyctl, KEYCTL_UNLINK, serial,
		    (long)KEY_SPEC_SESSION_KEYRING, 0L, 0L) < 0)
		return fail("unlink test key");
	/* Cached inode keys remain until eviction: the caller must unmount. */
	return 0;
}

static int check_policy(int fd)
{
	struct fscrypt_policy_v1 actual = { 0 };

	if (ioctl(fd, FS_IOC_GET_ENCRYPTION_POLICY, &actual) < 0)
		return fail("get encryption policy");
	if (memcmp(&actual, &test_policy, sizeof(actual))) {
		fputs("fscrypt-test: encryption policy does not match fixture\n",
		      stderr);
		return 1;
	}
	return 0;
}

static int policy_command(const char *path, int set)
{
	int fd, ret;

	fd = open(path, O_RDONLY | O_CLOEXEC | (set ? O_DIRECTORY : 0));
	if (fd < 0)
		return fail("open policy path");
	if (set && ioctl(fd, FS_IOC_SET_ENCRYPTION_POLICY, &test_policy) < 0)
		ret = fail("set encryption policy");
	else
		ret = check_policy(fd);
	if (close(fd) < 0 && !ret)
		ret = fail("close policy path");
	return ret;
}

int main(int argc, char **argv)
{
	if (argc == 2 && !strcmp(argv[1], "--help")) {
		usage(stdout);
		return 0;
	}
	if (argc >= 3 && !strcmp(argv[1], "session"))
		return enter_session(&argv[2]);
	if (argc == 2 && !strcmp(argv[1], "add-known-key"))
		return add_test_key(0);
	if (argc == 2 && !strcmp(argv[1], "add-wrong-key"))
		return add_test_key(1);
	if (argc == 2 && !strcmp(argv[1], "remove-key"))
		return remove_test_key();
	if (argc == 3 && !strcmp(argv[1], "set-policy"))
		return policy_command(argv[2], 1);
	if (argc == 3 && !strcmp(argv[1], "verify-policy"))
		return policy_command(argv[2], 0);
	usage(stderr);
	return 2;
}
