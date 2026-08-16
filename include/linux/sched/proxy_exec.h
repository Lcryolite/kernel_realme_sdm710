/* SPDX-License-Identifier: GPL-2.0 */
#ifndef _LINUX_SCHED_PROXY_EXEC_H
#define _LINUX_SCHED_PROXY_EXEC_H

struct mutex;
struct rq;
struct task_struct;

#ifdef CONFIG_SCHED_PROXY_EXEC
extern bool sched_proxy_exec;
bool sched_proxy_enabled(void);
bool sched_proxy_task_blocked(struct task_struct *task);
void sched_proxy_set_blocked_on(struct task_struct *task,
					struct mutex *lock);
void sched_proxy_clear_blocked_on(struct task_struct *task, struct mutex *lock);
void sched_proxy_set_donor(struct rq *rq, struct task_struct *task);
struct task_struct *sched_proxy_find(struct rq *rq,
					struct task_struct *donor);
void sched_proxy_tag_curr(struct rq *rq, struct task_struct *owner);
#else
static inline bool sched_proxy_enabled(void) { return false; }
static inline bool sched_proxy_task_blocked(struct task_struct *task)
{
	return false;
}
static inline void sched_proxy_set_blocked_on(struct task_struct *task,
					      struct mutex *lock) { }
static inline void sched_proxy_clear_blocked_on(struct task_struct *task,
						struct mutex *lock) { }
static inline void sched_proxy_set_donor(struct rq *rq,
					struct task_struct *task) { }
static inline struct task_struct *sched_proxy_find(struct rq *rq,
						struct task_struct *donor)
{
	return donor;
}
static inline void sched_proxy_tag_curr(struct rq *rq,
					struct task_struct *owner) { }
#endif

#endif /* _LINUX_SCHED_PROXY_EXEC_H */
