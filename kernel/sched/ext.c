// SPDX-License-Identifier: GPL-2.0
/*
 * sched_ext diagnostics for the 4.9 mobile scheduler.
 *
 * EEVDF remains the scheduler.  A tracepoint-type BPF program may be attached
 * through program_fd and is run at scheduler picks for diagnostics.  It cannot
 * replace EEVDF, WALT, schedtune, or schedutil; detach, timeout, or error always
 * leaves the built-in scheduler in charge.
 */
#include <linux/bpf.h>
#include <linux/filter.h>
#include <linux/jiffies.h>
#include <linux/kernel.h>
#include <linux/kobject.h>
#include <linux/mutex.h>
#include <linux/rcupdate.h>
#include <linux/sched.h>
#include <linux/sched/ext.h>
#include <linux/sysfs.h>
#include <linux/workqueue.h>

#define SCHED_EXT_WATCHDOG_TICKS (5 * HZ)
#define SCHED_EXT_ERROR_LEN 96

enum sched_ext_state {
	SCHED_EXT_OFF,
	SCHED_EXT_ACTIVE,
	SCHED_EXT_ERROR,
};

static DEFINE_MUTEX(sched_ext_lock);
static struct kobject *sched_ext_kobj;
static struct delayed_work sched_ext_watchdog;
static struct bpf_prog __rcu *sched_ext_prog;
static bool sched_ext_enabled;
static bool sched_ext_boot_enable;
static unsigned long sched_ext_last_heartbeat;
static unsigned int sched_ext_recoveries;
static u32 sched_ext_last_bpf_result;
static enum sched_ext_state sched_ext_status = SCHED_EXT_OFF;
static char sched_ext_last_error[SCHED_EXT_ERROR_LEN] = "none";

static const char *sched_ext_state_name(enum sched_ext_state state)
{
	switch (state) {
	case SCHED_EXT_ACTIVE:
		return "active";
	case SCHED_EXT_ERROR:
		return "error";
	default:
		return "off";
	}
}

static void sched_ext_recover_locked(const char *reason)
{
	sched_ext_enabled = false;
	sched_ext_status = SCHED_EXT_ERROR;
	sched_ext_recoveries++;
	strlcpy(sched_ext_last_error, reason ? reason : "extension error",
		 sizeof(sched_ext_last_error));
	cancel_delayed_work(&sched_ext_watchdog);
}

static void sched_ext_watchdog_fn(struct work_struct *work)
{
	mutex_lock(&sched_ext_lock);
	if (sched_ext_enabled) {
		if (time_after(jiffies,
			       sched_ext_last_heartbeat + SCHED_EXT_WATCHDOG_TICKS))
			sched_ext_recover_locked("watchdog timeout; EEVDF restored");
		else
			schedule_delayed_work(&sched_ext_watchdog, HZ);
	}
	mutex_unlock(&sched_ext_lock);
}

void sched_ext_report_error(const char *reason)
{
	mutex_lock(&sched_ext_lock);
	if (sched_ext_enabled)
		sched_ext_recover_locked(reason);
	mutex_unlock(&sched_ext_lock);
}
EXPORT_SYMBOL_GPL(sched_ext_report_error);

void sched_ext_heartbeat(void)
{
	mutex_lock(&sched_ext_lock);
	if (sched_ext_enabled)
		sched_ext_last_heartbeat = jiffies;
	mutex_unlock(&sched_ext_lock);
}
EXPORT_SYMBOL_GPL(sched_ext_heartbeat);

void sched_ext_run_hook(struct sched_ext_context *ctx)
{
	struct bpf_prog *prog;
	u32 result;

	if (!ctx || !READ_ONCE(sched_ext_enabled))
		return;

	rcu_read_lock();
	prog = rcu_dereference(sched_ext_prog);
	if (prog) {
		result = BPF_PROG_RUN(prog, ctx);
		if (result)
			WRITE_ONCE(sched_ext_last_bpf_result, result);
	}
	rcu_read_unlock();
}
EXPORT_SYMBOL_GPL(sched_ext_run_hook);

bool sched_ext_is_active(void)
{
	return READ_ONCE(sched_ext_enabled);
}
EXPORT_SYMBOL_GPL(sched_ext_is_active);

static ssize_t state_show(struct kobject *kobj,
			  struct kobj_attribute *attr, char *buf)
{
	return scnprintf(buf, PAGE_SIZE, "%s\n",
			 sched_ext_state_name(READ_ONCE(sched_ext_status)));
}

static ssize_t enable_show(struct kobject *kobj,
			   struct kobj_attribute *attr, char *buf)
{
	return scnprintf(buf, PAGE_SIZE, "%u\n",
			 READ_ONCE(sched_ext_enabled) ? 1 : 0);
}

static ssize_t enable_store(struct kobject *kobj,
			    struct kobj_attribute *attr,
			    const char *buf, size_t count)
{
	bool enable;

	if (kstrtobool(buf, &enable))
		return -EINVAL;

	mutex_lock(&sched_ext_lock);
	if (enable) {
		if (!rcu_access_pointer(sched_ext_prog)) {
			mutex_unlock(&sched_ext_lock);
			return -ENODEV;
		}
		sched_ext_enabled = true;
		sched_ext_status = SCHED_EXT_ACTIVE;
		sched_ext_last_heartbeat = jiffies;
		sched_ext_last_bpf_result = 0;
		strlcpy(sched_ext_last_error, "none",
			 sizeof(sched_ext_last_error));
		schedule_delayed_work(&sched_ext_watchdog, HZ);
	} else {
		sched_ext_enabled = false;
		sched_ext_status = SCHED_EXT_OFF;
		cancel_delayed_work(&sched_ext_watchdog);
	}
	mutex_unlock(&sched_ext_lock);
	return count;
}

static ssize_t heartbeat_store(struct kobject *kobj,
			       struct kobj_attribute *attr,
			       const char *buf, size_t count)
{
	sched_ext_heartbeat();
	return count;
}

static ssize_t program_fd_show(struct kobject *kobj,
			       struct kobj_attribute *attr, char *buf)
{
	return scnprintf(buf, PAGE_SIZE, "%u\n",
			 rcu_access_pointer(sched_ext_prog) ? 1 : 0);
}

static ssize_t program_fd_store(struct kobject *kobj,
				struct kobj_attribute *attr,
				const char *buf, size_t count)
{
	struct bpf_prog *new_prog = NULL, *old_prog;
	unsigned int fd;
	int ret;

	ret = kstrtouint(buf, 0, &fd);
	if (ret)
		return ret;
	if (fd) {
		new_prog = bpf_prog_get_type(fd, BPF_PROG_TYPE_TRACEPOINT);
		if (IS_ERR(new_prog))
			return PTR_ERR(new_prog);
	}

	mutex_lock(&sched_ext_lock);
	old_prog = rcu_dereference_protected(sched_ext_prog,
					     lockdep_is_held(&sched_ext_lock));
	rcu_assign_pointer(sched_ext_prog, new_prog);
	if (!new_prog) {
		sched_ext_enabled = false;
		sched_ext_status = SCHED_EXT_OFF;
		cancel_delayed_work(&sched_ext_watchdog);
	}
	mutex_unlock(&sched_ext_lock);

	synchronize_rcu();
	if (old_prog)
		bpf_prog_put(old_prog);
	return count;
}

static ssize_t recoveries_show(struct kobject *kobj,
			       struct kobj_attribute *attr, char *buf)
{
	return scnprintf(buf, PAGE_SIZE, "%u\n",
			 READ_ONCE(sched_ext_recoveries));
}

static ssize_t last_error_show(struct kobject *kobj,
			       struct kobj_attribute *attr, char *buf)
{
	return scnprintf(buf, PAGE_SIZE, "%s\n", sched_ext_last_error);
}

static ssize_t last_bpf_result_show(struct kobject *kobj,
				    struct kobj_attribute *attr, char *buf)
{
	return scnprintf(buf, PAGE_SIZE, "%u\n",
			 READ_ONCE(sched_ext_last_bpf_result));
}

static struct kobj_attribute state_attr = __ATTR_RO(state);
static struct kobj_attribute enable_attr = __ATTR_RW(enable);
static struct kobj_attribute heartbeat_attr = __ATTR_WO(heartbeat);
static struct kobj_attribute program_fd_attr = __ATTR_RW(program_fd);
static struct kobj_attribute recoveries_attr = __ATTR_RO(recoveries);
static struct kobj_attribute last_error_attr = __ATTR_RO(last_error);
static struct kobj_attribute last_bpf_result_attr = __ATTR_RO(last_bpf_result);

static struct attribute *sched_ext_attrs[] = {
	&state_attr.attr,
	&enable_attr.attr,
	&heartbeat_attr.attr,
	&program_fd_attr.attr,
	&recoveries_attr.attr,
	&last_error_attr.attr,
	&last_bpf_result_attr.attr,
	NULL,
};

static const struct attribute_group sched_ext_attr_group = {
	.attrs = sched_ext_attrs,
};

static int __init sched_ext_boot_param(char *str)
{
	return kstrtobool(str, &sched_ext_boot_enable);
}
__setup("sched_ext=", sched_ext_boot_param);

static int __init sched_ext_init(void)
{
	int ret;

	INIT_DELAYED_WORK(&sched_ext_watchdog, sched_ext_watchdog_fn);
	sched_ext_kobj = kobject_create_and_add("sched_ext", kernel_kobj);
	if (!sched_ext_kobj)
		return -ENOMEM;

	ret = sysfs_create_group(sched_ext_kobj, &sched_ext_attr_group);
	if (ret) {
		kobject_put(sched_ext_kobj);
		sched_ext_kobj = NULL;
		return ret;
	}

	if (sched_ext_boot_enable)
		sched_ext_recover_locked("boot enable requires program_fd; EEVDF kept");
	return 0;
}
subsys_initcall(sched_ext_init);
