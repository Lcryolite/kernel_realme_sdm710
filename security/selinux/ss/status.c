/*
 * mmap based event notifications for SELinux
 *
 * Author: KaiGai Kohei <kaigai@ak.jp.nec.com>
 *
 * Copyright (C) 2010 NEC corporation
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 2,
 * as published by the Free Software Foundation.
 */
#include <linux/kernel.h>
#include <linux/gfp.h>
#include <linux/mm.h>
#include <linux/mutex.h>
#include "avc.h"
#include "services.h"

/*
 * The selinux_status_page shall be exposed to userspace applications
 * using mmap interface on /selinux/status.
 * It enables to notify applications a few events that will cause reset
 * of userspace access vector without context switching.
 *
 * The selinux_kernel_status structure on the head of status page is
 * protected from concurrent accesses using seqlock logic, so userspace
 * application should reference the status page according to the seqlock
 * logic.
 *
 * Typically, application checks status->sequence at the head of access
 * control routine. If it is odd-number, kernel is updating the status,
 * so please wait for a moment. If it is changed from the last sequence
 * number, it means something happen, so application will reset userspace
 * avc, if needed.
 * In most cases, application shall confirm the kernel status is not
 * changed without any system call invocations.
 */
static struct page *selinux_status_page;
static DEFINE_MUTEX(selinux_status_lock);

/*
 * selinux_kernel_status_page
 *
 * It returns a reference to selinux_status_page. If the status page is
 * not allocated yet, it also tries to allocate it at the first time.
 */
struct page *selinux_kernel_status_page(void)
{
	struct selinux_kernel_status   *status;
	struct page		       *result = NULL;

	pr_emerg("[DEBUG-rmxdiag-r47] status_page lock begin locked=%d page_present=%d\n",
		 mutex_is_locked(&selinux_status_lock), !!selinux_status_page);
	mutex_lock(&selinux_status_lock);
	pr_emerg("[DEBUG-rmxdiag-r47] status_page lock acquired page_present=%d\n",
		 !!selinux_status_page);
	if (!selinux_status_page) {
		pr_emerg("[DEBUG-rmxdiag-r47] status_page alloc begin\n");
		selinux_status_page = alloc_page(GFP_KERNEL|__GFP_ZERO);
		pr_emerg("[DEBUG-rmxdiag-r47] status_page alloc complete page_present=%d\n",
			 !!selinux_status_page);

		if (selinux_status_page) {
			status = page_address(selinux_status_page);

			status->version = SELINUX_KERNEL_STATUS_VERSION;
			status->sequence = 0;
			status->enforcing = selinux_enforcing;
			/*
			 * NOTE: the next policyload event shall set
			 * a positive value on the status->policyload,
			 * although it may not be 1, but never zero.
			 * So, application can know it was updated.
			 */
			status->policyload = 0;
			status->deny_unknown = !security_get_allow_unknown();
		}
	}
	result = selinux_status_page;
	pr_emerg("[DEBUG-rmxdiag-r47] status_page unlock begin\n");
	mutex_unlock(&selinux_status_lock);
	pr_emerg("[DEBUG-rmxdiag-r47] status_page return page_present=%d\n",
		 !!result);

	return result;
}

/*
 * selinux_status_update_setenforce
 *
 * It updates status of the current enforcing/permissive mode.
 */
void selinux_status_update_setenforce(int enforcing)
{
	struct selinux_kernel_status   *status;

	pr_emerg("[DEBUG-rmxdiag-r47] status_setenforce lock begin locked=%d page_present=%d enforcing=%d\n",
		 mutex_is_locked(&selinux_status_lock), !!selinux_status_page,
		 enforcing);
	mutex_lock(&selinux_status_lock);
	pr_emerg("[DEBUG-rmxdiag-r47] status_setenforce lock acquired page_present=%d\n",
		 !!selinux_status_page);
	if (selinux_status_page) {
		status = page_address(selinux_status_page);

		status->sequence++;
		smp_wmb();

		status->enforcing = enforcing;

		smp_wmb();
		status->sequence++;
	}
	pr_emerg("[DEBUG-rmxdiag-r47] status_setenforce unlock begin\n");
	mutex_unlock(&selinux_status_lock);
	pr_emerg("[DEBUG-rmxdiag-r47] status_setenforce return\n");
}

/*
 * selinux_status_update_policyload
 *
 * It updates status of the times of policy reloaded, and current
 * setting of deny_unknown.
 */
void selinux_status_update_policyload(int seqno)
{
	struct selinux_kernel_status   *status;
	int deny_unknown;

	pr_emerg("[DEBUG-rmxdiag-r47] status_policyload lock begin locked=%d page_present=%d seqno=%d\n",
		 mutex_is_locked(&selinux_status_lock), !!selinux_status_page,
		 seqno);
	mutex_lock(&selinux_status_lock);
	pr_emerg("[DEBUG-rmxdiag-r47] status_policyload lock acquired page_present=%d\n",
		 !!selinux_status_page);
	if (selinux_status_page) {
		status = page_address(selinux_status_page);

		pr_emerg("[DEBUG-rmxdiag-r47] status_policyload sequence begin=%u\n",
			 status->sequence);
		status->sequence++;
		smp_wmb();

		status->policyload = seqno;
		pr_emerg("[DEBUG-rmxdiag-r47] status_policyload allow_unknown begin\n");
		deny_unknown = !security_get_allow_unknown();
		pr_emerg("[DEBUG-rmxdiag-r47] status_policyload allow_unknown complete deny_unknown=%d\n",
			 deny_unknown);
		status->deny_unknown = deny_unknown;

		smp_wmb();
		status->sequence++;
		pr_emerg("[DEBUG-rmxdiag-r47] status_policyload sequence complete=%u\n",
			 status->sequence);
	} else {
		pr_emerg("[DEBUG-rmxdiag-r47] status_policyload page absent\n");
	}
	pr_emerg("[DEBUG-rmxdiag-r47] status_policyload unlock begin\n");
	mutex_unlock(&selinux_status_lock);
	pr_emerg("[DEBUG-rmxdiag-r47] status_policyload return\n");
}
