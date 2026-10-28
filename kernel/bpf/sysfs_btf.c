// SPDX-License-Identifier: GPL-2.0
/*
 * Provide kernel BTF information for introspection and use by eBPF tools.
 */
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/kobject.h>
#include <linux/init.h>
#include <linux/mutex.h>
#include <linux/sysfs.h>

/* See scripts/link-vmlinux.sh, gen_btf() func for details */
extern char __weak __start_BTF[];
extern char __weak __stop_BTF[];

static ssize_t
btf_vmlinux_read(struct file *file, struct kobject *kobj,
		 struct bin_attribute *bin_attr,
		 char *buf, loff_t off, size_t len)
{
	memcpy(buf, __start_BTF + off, len);
	return len;
}

static struct bin_attribute bin_attr_btf_vmlinux = {
	.attr = { .name = "vmlinux", .mode = 0444, },
	.read = btf_vmlinux_read,
};

static struct kobject *btf_kobj;
static DEFINE_MUTEX(btf_publish_mutex);
static bool rmxdiag_publish_btf;

static int btf_vmlinux_publish(void)
{
	int ret;

	mutex_lock(&btf_publish_mutex);
	if (btf_kobj) {
		mutex_unlock(&btf_publish_mutex);
		return 0;
	}

	bin_attr_btf_vmlinux.size = __stop_BTF - __start_BTF;

	if (!__start_BTF || bin_attr_btf_vmlinux.size == 0) {
		mutex_unlock(&btf_publish_mutex);
		return 0;
	}

	btf_kobj = kobject_create_and_add("btf", kernel_kobj);
	if (!btf_kobj) {
		mutex_unlock(&btf_publish_mutex);
		return -ENOMEM;
	}

	ret = sysfs_create_bin_file(btf_kobj, &bin_attr_btf_vmlinux);
	if (ret) {
		kobject_put(btf_kobj);
		btf_kobj = NULL;
	}
	mutex_unlock(&btf_publish_mutex);
	return ret;
}

static int param_set_publish_btf(const char *value,
				 const struct kernel_param *kp)
{
	bool requested;
	int ret;

	(void)kp;
	ret = kstrtobool(value, &requested);
	if (ret)
		return ret;
	if (!requested)
		return -EINVAL;

	ret = btf_vmlinux_publish();
	if (!ret)
		rmxdiag_publish_btf = true;
	return ret;
}

static const struct kernel_param_ops param_ops_publish_btf = {
	.set = param_set_publish_btf,
	.get = param_get_bool,
};

module_param_cb(rmxdiag_publish_btf, &param_ops_publish_btf,
			&rmxdiag_publish_btf, 0644);
MODULE_PARM_DESC(rmxdiag_publish_btf,
		 "Publish /sys/kernel/btf/vmlinux after boot for diagnosis");

static int __init btf_vmlinux_init(void)
{
	if (!rmxdiag_publish_btf) {
		pr_info("BTF: vmlinux sysfs publication deferred by rmxdiag\n");
		return 0;
	}

	return btf_vmlinux_publish();
}

subsys_initcall(btf_vmlinux_init);
