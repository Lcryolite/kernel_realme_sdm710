/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Copyright (C) 2020 Oplus. All rights reserved.
 */


#ifdef OPLUS_FEATURE_UIFIRST
#ifndef _OPLUS_WORKQUEUE_H_
#define _OPLUS_WORKQUEUE_H_

struct worker;
#ifdef CONFIG_OPLUS_SYSTEM_KERNEL_QCOM
int is_uxwork(struct work_struct *work);
int set_uxwork(struct work_struct *work);
void reset_uxwork(struct work_struct *work);
void set_ux_worker_task(struct task_struct *task);
void reset_ux_worker_task(struct task_struct *task);
#else /* CONFIG_OPLUS_SYSTEM_KERNEL_QCOM */
static inline int is_uxwork(struct work_struct *work) { return false; }
static inline int set_uxwork(struct work_struct *work) { return false; }
static inline int unset_uxwork(struct work_struct *work) { return false; }
static inline void set_ux_worker_task(struct task_struct *task) {}
static inline void reset_ux_worker_task(struct task_struct *task) {}
#endif /* CONFIG_OPLUS_SYSTEM_KERNEL_QCOM */

#endif//_OPPO_WORKQUEUE_H_
#endif
