// SPDX-License-Identifier: GPL-2.0
/*
 * Proxy execution for the 4.9 scheduler.
 *
 * This is deliberately gated out of PREEMPT_RT and disabled by default.  A
 * blocked waiter remains schedulable only while proxy execution is enabled;
 * the scheduler keeps its scheduling identity in rq->donor and runs the
 * same-CPU mutex owner as rq->curr.  Cross-CPU and unstable owner chains fall
 * back to ordinary wakeup/dequeue handling.
 */
#if !defined(CONFIG_PREEMPT_RT)

#include <linux/kernel.h>
#include <linux/kobject.h>
#include <linux/mutex.h>
#include <linux/sched.h>
#include <linux/sched/proxy_exec.h>
#include <linux/sysfs.h>

#include "sched.h"

#define PROXY_EXEC_MAX_DEPTH 8

bool sched_proxy_exec __read_mostly;
EXPORT_SYMBOL_GPL(sched_proxy_exec);

static DEFINE_MUTEX(proxy_exec_lock);

bool sched_proxy_enabled(void)
{
	return READ_ONCE(sched_proxy_exec);
}
EXPORT_SYMBOL_GPL(sched_proxy_enabled);

bool sched_proxy_task_blocked(struct task_struct *task)
{
	return sched_proxy_enabled() && task &&
		READ_ONCE(task->sched_proxy_blocked_on);
}
EXPORT_SYMBOL_GPL(sched_proxy_task_blocked);

void sched_proxy_set_blocked_on(struct task_struct *task, struct mutex *lock)
{
	if (task && sched_proxy_enabled())
		WRITE_ONCE(task->sched_proxy_blocked_on, lock);
}
EXPORT_SYMBOL_GPL(sched_proxy_set_blocked_on);

void sched_proxy_clear_blocked_on(struct task_struct *task, struct mutex *lock)
{
	if (task && (!lock ||
			READ_ONCE(task->sched_proxy_blocked_on) == lock))
		WRITE_ONCE(task->sched_proxy_blocked_on, NULL);
}
EXPORT_SYMBOL_GPL(sched_proxy_clear_blocked_on);

void sched_proxy_set_donor(struct rq *rq, struct task_struct *task)
{
	if (rq)
		WRITE_ONCE(rq->donor, sched_proxy_enabled() ? task : NULL);
}
EXPORT_SYMBOL_GPL(sched_proxy_set_donor);

static void proxy_deactivate(struct rq *rq, struct task_struct *donor,
				     int wake_cpu)
{
	if (!donor)
		return;
	if (wake_cpu >= 0 && cpumask_test_cpu(wake_cpu,
					      &donor->cpus_allowed))
		donor->wake_cpu = wake_cpu;
	if (!task_on_rq_queued(donor))
		return;
	sched_proxy_set_donor(rq, rq->idle);
	deactivate_task(rq, donor, DEQUEUE_SLEEP);
	donor->on_rq = 0;
}

/*
 * Follow task -> mutex -> owner while holding each mutex wait lock.  The
 * donor is migrated by normal wakeup when the owner is not runnable here.
 */
struct task_struct *sched_proxy_find(struct rq *rq,
				     struct task_struct *donor)
{
	struct task_struct *task = donor;
	struct task_struct *owner = NULL;
	int depth;

	if (!rq || !donor || !sched_proxy_enabled())
		return donor;

	for (depth = 0; depth < PROXY_EXEC_MAX_DEPTH &&
		       sched_proxy_task_blocked(task); depth++) {
		struct mutex *lock = READ_ONCE(task->sched_proxy_blocked_on);

		if (!lock)
			break;
		spin_lock(&lock->wait_lock);
		if (READ_ONCE(task->sched_proxy_blocked_on) != lock) {
			spin_unlock(&lock->wait_lock);
			proxy_deactivate(rq, donor, -1);
			return NULL;
		}

		if (READ_ONCE(task->state) == TASK_RUNNING) {
			sched_proxy_clear_blocked_on(task, lock);
			spin_unlock(&lock->wait_lock);
			return task;
		}
		owner = READ_ONCE(lock->owner);
		if (!owner) {
			sched_proxy_clear_blocked_on(task, lock);
			spin_unlock(&lock->wait_lock);
			return task;
		}
		if (owner == task) {
			spin_unlock(&lock->wait_lock);
			proxy_deactivate(rq, donor, -1);
			return NULL;
		}
		if (!task_on_rq_queued(owner) || owner->se.sched_delayed ||
			    task_cpu(owner) != cpu_of(rq)) {
			spin_unlock(&lock->wait_lock);
			proxy_deactivate(rq, donor,
					 task_cpu(owner) == cpu_of(rq) ? -1 :
					 task_cpu(owner));
			return NULL;
		}
		spin_unlock(&lock->wait_lock);
		task = owner;
	}

	if (sched_proxy_task_blocked(task)) {
		proxy_deactivate(rq, donor, -1);
		return NULL;
	}
	return task;
}
EXPORT_SYMBOL_GPL(sched_proxy_find);


static ssize_t proxy_exec_show(struct kobject *kobj,
			       struct kobj_attribute *attr, char *buf)
{
	return scnprintf(buf, PAGE_SIZE, "%u\n", sched_proxy_enabled() ? 1 : 0);
}

static ssize_t proxy_exec_store(struct kobject *kobj,
				struct kobj_attribute *attr,
				const char *buf, size_t count)
{
	bool enable;

	if (kstrtobool(buf, &enable))
		return -EINVAL;
	if (!enable)
		return -EPERM; /* one-way until reboot */

	mutex_lock(&proxy_exec_lock);
	WRITE_ONCE(sched_proxy_exec, true);
	mutex_unlock(&proxy_exec_lock);
	return count;
}

static struct kobj_attribute proxy_exec_attr =
	__ATTR(sched_proxy_exec, 0644, proxy_exec_show, proxy_exec_store);

static int __init sched_proxy_exec_boot_param(char *str)
{
	bool enable;

	if (!kstrtobool(str, &enable) && enable)
		WRITE_ONCE(sched_proxy_exec, true);
	return 1;
}
__setup("sched_proxy_exec=", sched_proxy_exec_boot_param);

static int __init sched_proxy_exec_init(void)
{
	if (!kernel_kobj)
		return -ENODEV;
	return sysfs_create_file(kernel_kobj, &proxy_exec_attr.attr);
}
subsys_initcall(sched_proxy_exec_init);

#endif /* !CONFIG_PREEMPT_RT */
