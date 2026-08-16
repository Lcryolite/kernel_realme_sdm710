/* SPDX-License-Identifier: GPL-2.0 */
#ifndef _LINUX_SCHED_EXT_H
#define _LINUX_SCHED_EXT_H

#include <linux/types.h>

struct sched_ext_context {
	u64 now;
	u32 cpu;
	u32 pid;
	u32 nr_running;
};

#ifdef CONFIG_SCHED_EXT
void sched_ext_report_error(const char *reason);
void sched_ext_heartbeat(void);
bool sched_ext_is_active(void);
void sched_ext_run_hook(struct sched_ext_context *ctx);
#else
static inline void sched_ext_report_error(const char *reason) { }
static inline void sched_ext_heartbeat(void) { }
static inline bool sched_ext_is_active(void) { return false; }
static inline void sched_ext_run_hook(struct sched_ext_context *ctx) { }
#endif

#endif /* _LINUX_SCHED_EXT_H */
