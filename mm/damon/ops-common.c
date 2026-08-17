// SPDX-License-Identifier: GPL-2.0
/*
 * Common Code for Data Access Monitoring
 *
 * Author: SeongJae Park <sj@kernel.org>
 *
 * 4.9 struct-page port of the 6.18 implementation.
 */

#include <linux/migrate.h>
#include <linux/mmu_notifier.h>
#include <linux/page_idle.h>
#include <linux/pagemap.h>
#include <linux/rmap.h>
#include <linux/swap.h>
#include <linux/swapops.h>
#include <linux/mm_inline.h>
#include <linux/memcontrol.h>

#include "../internal.h"
#include "ops-common.h"

/*
 * Get an online page for a pfn if it's in the LRU list.  Otherwise, returns
 * NULL.
 */
struct page *damon_get_page(unsigned long pfn)
{
	struct page *page;

	if (!pfn_valid(pfn))
		return NULL;
	page = pfn_to_page(pfn);
	if (!PageLRU(page) || !get_page_unless_zero(page))
		return NULL;
	if (unlikely(!PageLRU(page))) {
		put_page(page);
		page = NULL;
	}
	return page;
}

void damon_ptep_mkold(pte_t *pte, struct vm_area_struct *vma, unsigned long addr)
{
	pte_t pteval = *pte;
	struct page *page;
	bool young = false;
	unsigned long pfn;

	if (likely(pte_present(pteval)))
		pfn = pte_pfn(pteval);
	else
		pfn = swp_offset(pte_to_swp_entry(pteval));

	page = damon_get_page(pfn);
	if (!page)
		return;

	/*
	 * PFN swap PTEs, such as device-exclusive ones, that actually map pages
	 * are "old" from a CPU perspective. The MMU notifier takes care of any
	 * device aspects.
	 */
	if (likely(pte_present(pteval)))
		young |= ptep_test_and_clear_young(vma, addr, pte);
	young |= mmu_notifier_clear_young(vma->vm_mm, addr, addr + PAGE_SIZE);
	if (young)
		SetPageReferenced(page);

	set_page_idle(page);
	put_page(page);
}

void damon_pmdp_mkold(pmd_t *pmd, struct vm_area_struct *vma, unsigned long addr)
{
#ifdef CONFIG_TRANSPARENT_HUGEPAGE
	struct page *page = damon_get_page(pmd_pfn(*pmd));

	if (!page)
		return;

	if (pmdp_clear_young_notify(vma, addr, pmd))
		SetPageReferenced(page);

	set_page_idle(page);
	put_page(page);
#endif /* CONFIG_TRANSPARENT_HUGEPAGE */
}

#define DAMON_MAX_SUBSCORE	(100)
#define DAMON_MAX_AGE_IN_LOG	(32)

int damon_hot_score(struct damon_ctx *c, struct damon_region *r,
			struct damos *s)
{
	int freq_subscore;
	unsigned int age_in_sec;
	int age_in_log, age_subscore;
	unsigned int freq_weight = s->quota.weight_nr_accesses;
	unsigned int age_weight = s->quota.weight_age;
	int hotness;

	freq_subscore = r->nr_accesses * DAMON_MAX_SUBSCORE /
		damon_max_nr_accesses(&c->attrs);

	age_in_sec = (unsigned long)r->age * c->attrs.aggr_interval / 1000000;
	for (age_in_log = 0; age_in_log < DAMON_MAX_AGE_IN_LOG && age_in_sec;
			age_in_log++, age_in_sec >>= 1)
		;

	/* If frequency is 0, higher age means it's colder */
	if (freq_subscore == 0)
		age_in_log *= -1;

	/*
	 * Now age_in_log is in [-DAMON_MAX_AGE_IN_LOG, DAMON_MAX_AGE_IN_LOG].
	 * Scale it to be in [0, 100] and set it as age subscore.
	 */
	age_in_log += DAMON_MAX_AGE_IN_LOG;
	age_subscore = age_in_log * DAMON_MAX_SUBSCORE /
		DAMON_MAX_AGE_IN_LOG / 2;

	hotness = (freq_weight * freq_subscore + age_weight * age_subscore);
	if (freq_weight + age_weight)
		hotness /= freq_weight + age_weight;
	/*
	 * Transform it to fit in [0, DAMOS_MAX_SCORE]
	 */
	hotness = hotness * DAMOS_MAX_SCORE / DAMON_MAX_SUBSCORE;

	return hotness;
}

int damon_cold_score(struct damon_ctx *c, struct damon_region *r,
			struct damos *s)
{
	int hotness = damon_hot_score(c, r, s);

	/* Return coldness of the region */
	return DAMOS_MAX_SCORE - hotness;
}

static int damon_page_mkold_one(struct page *page,
		struct vm_area_struct *vma, unsigned long addr, void *arg)
{
	struct page_vma_mapped_walk pvmw = {
		.page = page,
		.vma = vma,
		.address = addr,
	};

	while (page_vma_mapped_walk(&pvmw)) {
		addr = pvmw.address;
		if (pvmw.pte)
			damon_ptep_mkold(pvmw.pte, vma, addr);
		else
			damon_pmdp_mkold(pvmw.pmd, vma, addr);
	}
	return 0;
}

void damon_page_mkold(struct page *page)
{
	struct rmap_walk_control rwc = {
		.rmap_one = damon_page_mkold_one,
		.anon_lock = page_lock_anon_vma_read,
	};
	bool need_lock;

	if (!page_mapped(page) || !page_rmapping(page)) {
		set_page_idle(page);
		return;
	}

	need_lock = !PageAnon(page) || PageKsm(page);
	if (need_lock && !trylock_page(page))
		return;

	rmap_walk(page, &rwc);

	if (need_lock)
		unlock_page(page);

}

static int damon_page_young_one(struct page *page,
		struct vm_area_struct *vma, unsigned long addr, void *arg)
{
	bool *accessed = arg;
	struct page_vma_mapped_walk pvmw = {
		.page = page,
		.vma = vma,
		.address = addr,
	};
	pte_t pte;

	*accessed = false;
	while (page_vma_mapped_walk(&pvmw)) {
		addr = pvmw.address;
		if (pvmw.pte) {
			pte = *pvmw.pte;

			/*
			 * PFN swap PTEs, such as device-exclusive ones, that
			 * actually map pages are "old" from a CPU perspective.
			 * The MMU notifier takes care of any device aspects.
			 */
			*accessed = (pte_present(pte) && pte_young(pte)) ||
				!page_is_idle(page) ||
				mmu_notifier_test_young(vma->vm_mm, addr);
		} else {
#ifdef CONFIG_TRANSPARENT_HUGEPAGE
			*accessed = pmd_young(*pvmw.pmd) ||
				!page_is_idle(page) ||
				mmu_notifier_test_young(vma->vm_mm, addr);
#else
			WARN_ON_ONCE(1);
#endif	/* CONFIG_TRANSPARENT_HUGEPAGE */
		}
		if (*accessed) {
			page_vma_mapped_walk_done(&pvmw);
			break;
		}
	}

	/* If accessed, stop walking */
	return *accessed == false ? 0 : 1;
}

bool damon_page_young(struct page *page)
{
	bool accessed = false;
	struct rmap_walk_control rwc = {
		.arg = &accessed,
		.rmap_one = damon_page_young_one,
		.anon_lock = page_lock_anon_vma_read,
	};
	bool need_lock;

	if (!page_mapped(page) || !page_rmapping(page)) {
		if (page_is_idle(page))
			return false;
		else
			return true;
	}

	need_lock = !PageAnon(page) || PageKsm(page);
	if (need_lock && !trylock_page(page))
		return false;

	rmap_walk(page, &rwc);

	if (need_lock)
		unlock_page(page);

	return accessed;
}

bool damos_page_filter_match(struct damos_filter *filter, struct page *page)
{
	bool matched = false;
	struct mem_cgroup *memcg;
	size_t page_sz;

	switch (filter->type) {
	case DAMOS_FILTER_TYPE_ANON:
		matched = PageAnon(page);
		break;
	case DAMOS_FILTER_TYPE_ACTIVE:
		matched = PageActive(page);
		break;
	case DAMOS_FILTER_TYPE_MEMCG:
		rcu_read_lock();
		memcg = page->mem_cgroup;
		if (!memcg)
			matched = false;
		else
			matched = filter->memcg_id == mem_cgroup_id(memcg);
		rcu_read_unlock();
		break;
	case DAMOS_FILTER_TYPE_YOUNG:
		matched = damon_page_young(page);
		if (matched)
			damon_page_mkold(page);
		break;
	case DAMOS_FILTER_TYPE_HUGEPAGE_SIZE:
		page_sz = hpage_nr_pages(page) << PAGE_SHIFT;
		matched = filter->sz_range.min <= page_sz &&
			  page_sz <= filter->sz_range.max;
		break;
	case DAMOS_FILTER_TYPE_UNMAPPED:
		matched = !page_mapped(page) || !page_rmapping(page);
		break;
	default:
		break;
	}

	return matched == filter->matching;
}

/*
 * Allocate a migration target page on the target node (4.9 new_page_t).
 */
static struct page *damon_alloc_migration_target(struct page *page,
		unsigned long private, int **reason)
{
	return alloc_pages_node((int)private,
			GFP_HIGHUSER_MOVABLE | __GFP_THISNODE, 0);
}

static unsigned int __damon_migrate_page_list(
		struct list_head *migrate_pages_list, struct pglist_data *pgdat,
		int target_nid)
{
	unsigned int nr_succeeded = 0;

	if (pgdat->node_id == target_nid || target_nid == NUMA_NO_NODE)
		return 0;

	if (list_empty(migrate_pages_list))
		return 0;

	/* Migration ignores all cpuset and mempolicy settings */
	nr_succeeded = migrate_pages(migrate_pages_list,
			damon_alloc_migration_target, NULL,
			(unsigned long)target_nid, MIGRATE_ASYNC,
			MR_NUMA_MISPLACED);

	return nr_succeeded;
}

static unsigned int damon_migrate_page_list(struct list_head *page_list,
						struct pglist_data *pgdat,
						int target_nid)
{
	unsigned int nr_migrated = 0;
	struct page *page;
	LIST_HEAD(ret_pages);
	LIST_HEAD(migrate_pages_list);

	while (!list_empty(page_list)) {
		cond_resched();

		page = lru_to_page(page_list);
		list_del(&page->lru);

		if (!trylock_page(page))
			goto keep;

		/* Relocate its contents to another node. */
		list_add(&page->lru, &migrate_pages_list);
		unlock_page(page);
		continue;
keep:
		list_add(&page->lru, &ret_pages);
	}
	/* 'page_list' is always empty here */

	/* Migrate pages selected for migration */
	nr_migrated += __damon_migrate_page_list(
			&migrate_pages_list, pgdat, target_nid);
	/*
	 * Pages that could not be migrated are still in @migrate_pages.  Add
	 * those back on @page_list
	 */
	if (!list_empty(&migrate_pages_list))
		list_splice_init(&migrate_pages_list, page_list);

	try_to_unmap_flush();

	list_splice(&ret_pages, page_list);

	while (!list_empty(page_list)) {
		page = lru_to_page(page_list);
		list_del(&page->lru);
		putback_lru_page(page);
	}

	return nr_migrated;
}

unsigned long damon_migrate_pages(struct list_head *page_list, int target_nid)
{
	int nid;
	unsigned long nr_migrated = 0;
	LIST_HEAD(node_page_list);

	if (list_empty(page_list))
		return nr_migrated;

	if (target_nid < 0 || target_nid >= MAX_NUMNODES ||
			!node_state(target_nid, N_MEMORY))
		return nr_migrated;

	nid = page_to_nid(lru_to_page(page_list));
	do {
		struct page *page = lru_to_page(page_list);

		if (nid == page_to_nid(page)) {
			list_move(&page->lru, &node_page_list);
			continue;
		}

		nr_migrated += damon_migrate_page_list(&node_page_list,
						       NODE_DATA(nid),
						       target_nid);
		nid = page_to_nid(lru_to_page(page_list));
	} while (!list_empty(page_list));

	nr_migrated += damon_migrate_page_list(&node_page_list,
					       NODE_DATA(nid),
					       target_nid);

	return nr_migrated;
}

bool damos_ops_has_filter(struct damos *s)
{
	struct damos_filter *f;

	damos_for_each_ops_filter(f, s)
		return true;
	return false;
}
