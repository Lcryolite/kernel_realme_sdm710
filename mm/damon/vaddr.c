// SPDX-License-Identifier: GPL-2.0
/*
 * DAMON Code for Virtual Address Spaces
 *
 * Author: SeongJae Park <sj@kernel.org>
 */

#define pr_fmt(fmt) "damon-va: " fmt

#include <linux/highmem.h>
#include <linux/hugetlb.h>
#include <linux/mman.h>
#include <linux/slab.h>
#include <linux/mmu_notifier.h>
#include <linux/page_idle.h>
#include <linux/mm.h>

#include "../internal.h"
#include "ops-common.h"

#ifdef CONFIG_DAMON_VADDR_KUNIT_TEST
#undef DAMON_MIN_REGION
#define DAMON_MIN_REGION 1
#endif

/*
 * 't->pid' should be the pointer to the relevant 'struct pid' having reference
 * count.  Caller must put the returned task, unless it is NULL.
 */
static inline struct task_struct *damon_get_task_struct(struct damon_target *t)
{
	return get_pid_task(t->pid, PIDTYPE_PID);
}

/*
 * Get the mm_struct of the given target
 *
 * Caller _must_ put the mm_struct after use, unless it is NULL.
 *
 * Returns the mm_struct of the target on success, NULL on failure
 */
static struct mm_struct *damon_get_mm(struct damon_target *t)
{
	struct task_struct *task;
	struct mm_struct *mm;

	task = damon_get_task_struct(t);
	if (!task)
		return NULL;

	mm = get_task_mm(task);
	put_task_struct(task);
	return mm;
}

/*
 * Functions for the initial monitoring target regions construction
 */

/*
 * Size-evenly split a region into 'nr_pieces' small regions
 *
 * Returns 0 on success, or negative error code otherwise.
 */
static int damon_va_evenly_split_region(struct damon_target *t,
		struct damon_region *r, unsigned int nr_pieces)
{
	unsigned long sz_orig, sz_piece, orig_end;
	struct damon_region *n = NULL, *next;
	unsigned long start;
	unsigned int i;

	if (!r || !nr_pieces)
		return -EINVAL;

	if (nr_pieces == 1)
		return 0;

	orig_end = r->ar.end;
	sz_orig = damon_sz_region(r);
	sz_piece = ALIGN_DOWN(sz_orig / nr_pieces, DAMON_MIN_REGION);

	if (!sz_piece)
		return -EINVAL;

	r->ar.end = r->ar.start + sz_piece;
	next = damon_next_region(r);
	for (start = r->ar.end, i = 1; i < nr_pieces; start += sz_piece, i++) {
		n = damon_new_region(start, start + sz_piece);
		if (!n)
			return -ENOMEM;
		damon_insert_region(n, r, next, t);
		r = n;
	}
	/* complement last region for possible rounding error */
	if (n)
		n->ar.end = orig_end;

	return 0;
}

static unsigned long sz_range(struct damon_addr_range *r)
{
	return r->end - r->start;
}

/*
 * Find three regions separated by two biggest unmapped regions
 *
 * vma		the head vma of the target address space
 * regions	an array of three address ranges that results will be saved
 *
 * This function receives an address space and finds three regions in it which
 * separated by the two biggest unmapped regions in the space.  Please refer to
 * below comments of '__damon_va_init_regions()' function to know why this is
 * necessary.
 *
 * Returns 0 if success, or negative error code otherwise.
 */
static int __damon_va_three_regions(struct mm_struct *mm,
				       struct damon_addr_range regions[3])
{
	struct damon_addr_range first_gap = {0}, second_gap = {0};
	struct vm_area_struct *vma, *prev = NULL;
	unsigned long start;

	/*
	 * Find the two biggest gaps so that first_gap > second_gap > others.
	 */
	down_read(&mm->mmap_sem);
	for (vma = mm->mmap; vma; vma = vma->vm_next) {
		unsigned long gap;

		if (!prev) {
			start = vma->vm_start;
			goto next;
		}
		gap = vma->vm_start - prev->vm_end;

		if (gap > sz_range(&first_gap)) {
			second_gap = first_gap;
			first_gap.start = prev->vm_end;
			first_gap.end = vma->vm_start;
		} else if (gap > sz_range(&second_gap)) {
			second_gap.start = prev->vm_end;
			second_gap.end = vma->vm_start;
		}
next:
		prev = vma;
	}
	up_read(&mm->mmap_sem);

	if (!sz_range(&second_gap) || !sz_range(&first_gap))
		return -EINVAL;

	/* Sort the two biggest gaps by address */
	if (first_gap.start > second_gap.start)
		swap(first_gap, second_gap);

	/* Store the result */
	regions[0].start = ALIGN(start, DAMON_MIN_REGION);
	regions[0].end = ALIGN(first_gap.start, DAMON_MIN_REGION);
	regions[1].start = ALIGN(first_gap.end, DAMON_MIN_REGION);
	regions[1].end = ALIGN(second_gap.start, DAMON_MIN_REGION);
	regions[2].start = ALIGN(second_gap.end, DAMON_MIN_REGION);
	regions[2].end = ALIGN(prev->vm_end, DAMON_MIN_REGION);

	return 0;
}

/*
 * Get the three regions in the given target (task)
 *
 * Returns 0 on success, negative error code otherwise.
 */
static int damon_va_three_regions(struct damon_target *t,
				struct damon_addr_range regions[3])
{
	struct mm_struct *mm;
	int rc;

	mm = damon_get_mm(t);
	if (!mm)
		return -EINVAL;

	down_read(&mm->mmap_sem);
	rc = __damon_va_three_regions(mm, regions);
	up_read(&mm->mmap_sem);

	mmput(mm);
	return rc;
}

/*
 * Initialize the monitoring target regions for the given target (task)
 *
 * t	the given target
 *
 * Because only a number of small portions of the entire address space
 * is actually mapped to the memory and accessed, monitoring the unmapped
 * regions is wasteful.  That said, because we can deal with small noises,
 * tracking every mapping is not strictly required but could even incur a high
 * overhead if the mapping frequently changes or the number of mappings is
 * high.  The adaptive regions adjustment mechanism will further help to deal
 * with the noise by simply identifying the unmapped areas as a region that
 * has no access.  Moreover, applying the real mappings that would have many
 * unmapped areas inside will make the adaptive mechanism quite complex.  That
 * said, too huge unmapped areas inside the monitoring target should be removed
 * to not take the time for the adaptive mechanism.
 *
 * For the reason, we convert the complex mappings to three distinct regions
 * that cover every mapped area of the address space.  Also the two gaps
 * between the three regions are the two biggest unmapped areas in the given
 * address space.  In detail, this function first identifies the start and the
 * end of the mappings and the two biggest unmapped areas of the address space.
 * Then, it constructs the three regions as below:
 *
 *     [mappings[0]->start, big_two_unmapped_areas[0]->start)
 *     [big_two_unmapped_areas[0]->end, big_two_unmapped_areas[1]->start)
 *     [big_two_unmapped_areas[1]->end, mappings[nr_mappings - 1]->end)
 *
 * As usual memory map of processes is as below, the gap between the heap and
 * the uppermost mmap()-ed region, and the gap between the lowermost mmap()-ed
 * region and the stack will be two biggest unmapped regions.  Because these
 * gaps are exceptionally huge areas in usual address space, excluding these
 * two biggest unmapped regions will be sufficient to make a trade-off.
 *
 *   <heap>
 *   <BIG UNMAPPED REGION 1>
 *   <uppermost mmap()-ed region>
 *   (other mmap()-ed regions and small unmapped regions)
 *   <lowermost mmap()-ed region>
 *   <BIG UNMAPPED REGION 2>
 *   <stack>
 */
static void __damon_va_init_regions(struct damon_ctx *ctx,
				     struct damon_target *t)
{
	struct damon_target *ti;
	struct damon_region *r;
	struct damon_addr_range regions[3];
	unsigned long sz = 0, nr_pieces;
	int i, tidx = 0;

	if (damon_va_three_regions(t, regions)) {
		damon_for_each_target(ti, ctx) {
			if (ti == t)
				break;
			tidx++;
		}
		pr_debug("Failed to get three regions of %dth target\n", tidx);
		return;
	}

	for (i = 0; i < 3; i++)
		sz += regions[i].end - regions[i].start;
	if (ctx->attrs.min_nr_regions)
		sz /= ctx->attrs.min_nr_regions;
	if (sz < DAMON_MIN_REGION)
		sz = DAMON_MIN_REGION;

	/* Set the initial three regions of the target */
	for (i = 0; i < 3; i++) {
		r = damon_new_region(regions[i].start, regions[i].end);
		if (!r) {
			pr_err("%d'th init region creation failed\n", i);
			return;
		}
		damon_add_region(r, t);

		nr_pieces = (regions[i].end - regions[i].start) / sz;
		damon_va_evenly_split_region(t, r, nr_pieces);
	}
}

/* Initialize '->regions_list' of every target (task) */
static void damon_va_init(struct damon_ctx *ctx)
{
	struct damon_target *t;

	damon_for_each_target(t, ctx) {
		/* the user may set the target regions as they want */
		if (!damon_nr_regions(t))
			__damon_va_init_regions(ctx, t);
	}
}

/*
 * Update regions for current memory mappings
 */
static void damon_va_update(struct damon_ctx *ctx)
{
	struct damon_addr_range three_regions[3];
	struct damon_target *t;

	damon_for_each_target(t, ctx) {
		if (damon_va_three_regions(t, three_regions))
			continue;
		damon_set_regions(t, three_regions, 3, DAMON_MIN_REGION);
	}
}

static int damon_mkold_pmd_entry(pmd_t *pmd, unsigned long addr,
		unsigned long next, struct mm_walk *walk)
{
	pte_t *pte;
	pmd_t pmde;
	spinlock_t *ptl;

	if (pmd_trans_huge(*pmd)) {
		ptl = pmd_lock(walk->mm, pmd);
		pmde = *pmd;

		if (!pmd_present(pmde)) {
			spin_unlock(ptl);
			return 0;
		}

		if (pmd_trans_huge(pmde)) {
			damon_pmdp_mkold(pmd, walk->vma, addr);
			spin_unlock(ptl);
			return 0;
		}
		spin_unlock(ptl);
	}

	pte = pte_offset_map_lock(walk->mm, pmd, addr, &ptl);
	if (!pte)
		return 0;
	if (!pte_present(*pte))
		goto out;
	damon_ptep_mkold(pte, walk->vma, addr);
out:
	pte_unmap_unlock(pte, ptl);
	return 0;
}

#ifdef CONFIG_HUGETLB_PAGE
static void damon_hugetlb_mkold(pte_t *pte, struct mm_struct *mm,
				struct vm_area_struct *vma, unsigned long addr)
{
	bool referenced = false;
	pte_t entry = huge_ptep_get(mm, addr, pte);
	struct page *page = pfn_to_page(pte_pfn(entry));
	unsigned long psize = huge_page_size(hstate_vma(vma));

	get_page(folio);

	if (pte_young(entry)) {
		referenced = true;
		entry = pte_mkold(entry);
		set_huge_pte_at(mm, addr, pte, entry, psize);
	}

	if (mmu_notifier_clear_young(mm, addr,
				     addr + huge_page_size(hstate_vma(vma))))
		referenced = true;

	if (referenced)
		SetPageReferenced(folio);

	page_set_idle(folio);
	put_page(folio);
}

static int damon_mkold_hugetlb_entry(pte_t *pte, unsigned long hmask,
				     unsigned long addr, unsigned long end,
				     struct mm_walk *walk)
{
	struct hstate *h = hstate_vma(walk->vma);
	spinlock_t *ptl;
	pte_t entry;

	ptl = huge_pte_lock(h, walk->mm, pte);
	entry = huge_ptep_get(walk->mm, addr, pte);
	if (!pte_present(entry))
		goto out;

	damon_hugetlb_mkold(pte, walk->mm, walk->vma, addr);

out:
	spin_unlock(ptl);
	return 0;
}
#else
#define damon_mkold_hugetlb_entry NULL
#endif /* CONFIG_HUGETLB_PAGE */

static const struct mm_walk damon_mkold_walk_template = {
	.pmd_entry = damon_mkold_pmd_entry,
	.hugetlb_entry = damon_mkold_hugetlb_entry,
};

static void damon_va_mkold(struct mm_struct *mm, unsigned long addr)
{
	struct mm_walk walk = damon_mkold_walk_template;

	down_read(&mm->mmap_sem);
	walk.mm = mm;
	walk_page_range(addr, addr + 1, &walk);
	up_read(&mm->mmap_sem);
}

/*
 * Functions for the access checking of the regions
 */

static void __damon_va_prepare_access_check(struct mm_struct *mm,
					struct damon_region *r)
{
	r->sampling_addr = damon_rand(r->ar.start, r->ar.end);

	damon_va_mkold(mm, r->sampling_addr);
}

static void damon_va_prepare_access_checks(struct damon_ctx *ctx)
{
	struct damon_target *t;
	struct mm_struct *mm;
	struct damon_region *r;

	damon_for_each_target(t, ctx) {
		mm = damon_get_mm(t);
		if (!mm)
			continue;
		damon_for_each_region(r, t)
			__damon_va_prepare_access_check(mm, r);
		mmput(mm);
	}
}

struct damon_young_walk_private {
	/* size of the folio for the access checked virtual memory address */
	unsigned long *folio_sz;
	bool young;
};

static int damon_young_pmd_entry(pmd_t *pmd, unsigned long addr,
		unsigned long next, struct mm_walk *walk)
{
	pte_t *pte;
	pte_t ptent;
	spinlock_t *ptl;
	struct page *page;
	struct damon_young_walk_private *priv = walk->private;

#ifdef CONFIG_TRANSPARENT_HUGEPAGE
	if (pmd_trans_huge(*pmd)) {
		pmd_t pmde;

		ptl = pmd_lock(walk->mm, pmd);
		pmde = *pmd;

		if (!pmd_present(pmde)) {
			spin_unlock(ptl);
			return 0;
		}

		if (!pmd_trans_huge(pmde)) {
			spin_unlock(ptl);
			goto regular_page;
		}
		page = damon_get_page(pmd_pfn(pmde));
		if (!folio)
			goto huge_out;
		if (pmd_young(pmde) || !folio_test_idle(folio) ||
					mmu_notifier_test_young(walk->mm,
						addr))
			priv->young = true;
		*priv->folio_sz = HPAGE_PMD_SIZE;
		put_page(folio);
huge_out:
		spin_unlock(ptl);
		return 0;
	}

regular_page:
#endif	/* CONFIG_TRANSPARENT_HUGEPAGE */

	pte = pte_offset_map_lock(walk->mm, pmd, addr, &ptl);
	if (!pte)
		return 0;
	ptent = *pte;
	if (!pte_present(ptent))
		goto out;
	page = damon_get_page(pte_pfn(ptent));
	if (!page)
		goto out;
	if (pte_young(ptent) || !PageIdle(page) ||
			mmu_notifier_test_young(walk->mm, addr))
		priv->young = true;
	*priv->folio_sz = hpage_nr_pages(page) << PAGE_SHIFT;
	put_page(page);
out:
	pte_unmap_unlock(pte, ptl);
	return 0;
}

#ifdef CONFIG_HUGETLB_PAGE
static int damon_young_hugetlb_entry(pte_t *pte, unsigned long hmask,
				     unsigned long addr, unsigned long end,
				     struct mm_walk *walk)
{
	struct damon_young_walk_private *priv = walk->private;
	struct hstate *h = hstate_vma(walk->vma);
	struct page *page;
	spinlock_t *ptl;
	pte_t entry;

	ptl = huge_pte_lock(h, walk->mm, pte);
	entry = huge_ptep_get(walk->mm, addr, pte);
	if (!pte_present(entry))
		goto out;

	folio = pfn_to_page(pte_pfn(entry));
	get_page(folio);

	if (pte_young(entry) || !folio_test_idle(folio) ||
	    mmu_notifier_test_young(walk->mm, addr))
		priv->young = true;
	*priv->folio_sz = huge_page_size(h);

	put_page(folio);

out:
	spin_unlock(ptl);
	return 0;
}
#else
#define damon_young_hugetlb_entry NULL
#endif /* CONFIG_HUGETLB_PAGE */

static const struct mm_walk damon_young_walk_template = {
	.pmd_entry = damon_young_pmd_entry,
	.hugetlb_entry = damon_young_hugetlb_entry,
};

static bool damon_va_young(struct mm_struct *mm, unsigned long addr,
		unsigned long *folio_sz)
{
	struct damon_young_walk_private arg = {
		.folio_sz = folio_sz,
		.young = false,
	};

	struct mm_walk walk = damon_young_walk_template;

	down_read(&mm->mmap_sem);
	walk.mm = mm;
	walk.private = &arg;
	walk_page_range(addr, addr + 1, &walk);
	up_read(&mm->mmap_sem);
	return arg.young;
}

/*
 * Check whether the region was accessed after the last preparation
 *
 * mm	'mm_struct' for the given virtual address space
 * r	the region to be checked
 */
static void __damon_va_check_access(struct mm_struct *mm,
				struct damon_region *r, bool same_target,
				struct damon_attrs *attrs)
{
	static unsigned long last_addr;
	static unsigned long last_folio_sz = PAGE_SIZE;
	static bool last_accessed;

	if (!mm) {
		damon_update_region_access_rate(r, false, attrs);
		return;
	}

	/* If the region is in the last checked page, reuse the result */
	if (same_target && (ALIGN_DOWN(last_addr, last_folio_sz) ==
				ALIGN_DOWN(r->sampling_addr, last_folio_sz))) {
		damon_update_region_access_rate(r, last_accessed, attrs);
		return;
	}

	last_accessed = damon_va_young(mm, r->sampling_addr, &last_folio_sz);
	damon_update_region_access_rate(r, last_accessed, attrs);

	last_addr = r->sampling_addr;
}

static unsigned int damon_va_check_accesses(struct damon_ctx *ctx)
{
	struct damon_target *t;
	struct mm_struct *mm;
	struct damon_region *r;
	unsigned int max_nr_accesses = 0;
	bool same_target;

	damon_for_each_target(t, ctx) {
		mm = damon_get_mm(t);
		same_target = false;
		damon_for_each_region(r, t) {
			__damon_va_check_access(mm, r, same_target,
					&ctx->attrs);
			max_nr_accesses = max(r->nr_accesses, max_nr_accesses);
			same_target = true;
		}
		if (mm)
			mmput(mm);
	}

	return max_nr_accesses;
}

static bool damos_va_filter_young_match(struct damos_filter *filter,
		struct page *page, struct vm_area_struct *vma,
		unsigned long addr, pte_t *ptep, pmd_t *pmdp)
{
	bool young = false;

	if (ptep)
		young = pte_young(*ptep);
	else if (pmdp)
		young = pmd_young(*pmdp);

	young = young || !PageIdle(page) ||
		mmu_notifier_test_young(vma->vm_mm, addr);

	if (young && ptep)
		damon_ptep_mkold(ptep, vma, addr);
	else if (young && pmdp)
		damon_pmdp_mkold(pmdp, vma, addr);

	return young == filter->matching;
}

static bool damos_va_filter_out(struct damos *scheme, struct page *page,
		struct vm_area_struct *vma, unsigned long addr,
		pte_t *ptep, pmd_t *pmdp)
{
	struct damos_filter *filter;
	bool matched;

	if (scheme->core_filters_allowed)
		return false;

	damos_for_each_ops_filter(filter, scheme) {
		/*
		 * damos_folio_filter_match checks the young filter by doing an
		 * rmap on the folio to find its page table. However, being the
		 * vaddr scheme, we have direct access to the page tables, so
		 * use that instead.
		 */
		if (filter->type == DAMOS_FILTER_TYPE_YOUNG)
			matched = damos_va_filter_young_match(filter, page,
				vma, addr, ptep, pmdp);
		else
			matched = damos_page_filter_match(filter, page);

		if (matched)
			return !filter->allow;
	}
	return scheme->ops_filters_default_reject;
}

struct damos_va_migrate_private {
	struct list_head *migration_lists;
	struct damos *scheme;
};

/*
 * Place the given folio in the migration_list corresponding to where the folio
 * should be migrated.
 *
 * The algorithm used here is similar to weighted_interleave_nid()
 */
static void damos_va_migrate_dests_add(struct page *page,
		struct vm_area_struct *vma, unsigned long addr,
		struct damos_migrate_dests *dests,
		struct list_head *migration_lists)
{
	pgoff_t ilx;
	int order;
	unsigned int target;
	unsigned int weight_total = 0;
	int i;

	/*
	 * If dests is empty, there is only one migration list corresponding
	 * to s->target_nid.
	 */
	if (!dests->nr_dests) {
		i = 0;
		goto isolate;
	}

	order = compound_order(page);
	ilx = vma->vm_pgoff >> order;
	ilx += (addr - vma->vm_start) >> (PAGE_SHIFT + order);

	for (i = 0; i < dests->nr_dests; i++)
		weight_total += dests->weight_arr[i];

	/* If the total weights are somehow 0, don't migrate at all */
	if (!weight_total)
		return;

	target = ilx % weight_total;
	for (i = 0; i < dests->nr_dests; i++) {
		if (target < dests->weight_arr[i])
			break;
		target -= dests->weight_arr[i];
	}

	/* If the folio is already in the right node, don't do anything */
	if (page_to_nid(page) == dests->node_id_arr[i])
		return;

isolate:
	if (!isolate_lru_page(page))
		return;

	list_add(&page->lru, &migration_lists[i]);
}

#ifdef CONFIG_TRANSPARENT_HUGEPAGE
static int damos_va_migrate_pmd_entry(pmd_t *pmd, unsigned long addr,
		unsigned long next, struct mm_walk *walk)
{
	struct damos_va_migrate_private *priv = walk->private;
	struct list_head *migration_lists = priv->migration_lists;
	struct damos *s = priv->scheme;
	struct damos_migrate_dests *dests = &s->migrate_dests;
	struct page *page;
	spinlock_t *ptl;
	pmd_t pmde;

	ptl = pmd_lock(walk->mm, pmd);
	pmde = *pmd;

	if (!pmd_present(pmde) || !pmd_trans_huge(pmde))
		goto unlock;

	/* Tell page walk code to not split the PMD */
	walk->action = ACTION_CONTINUE;

	page = damon_get_page(pmd_pfn(pmde));
	if (!folio)
		goto unlock;

	if (damos_va_filter_out(s, folio, walk->vma, addr, NULL, pmd))
		goto put_folio;

	damos_va_migrate_dests_add(page, walk->vma, addr, dests,
		migration_lists);

put_folio:
	put_page(folio);
unlock:
	spin_unlock(ptl);
	return 0;
}
#else
#define damos_va_migrate_pmd_entry NULL
#endif /* CONFIG_TRANSPARENT_HUGEPAGE */

static int damos_va_migrate_pte_entry(pte_t *pte, unsigned long addr,
		unsigned long next, struct mm_walk *walk)
{
	struct damos_va_migrate_private *priv = walk->private;
	struct list_head *migration_lists = priv->migration_lists;
	struct damos *s = priv->scheme;
	struct damos_migrate_dests *dests = &s->migrate_dests;
	struct page *page;
	pte_t ptent;

	ptent = *pte;
	if (pte_none(ptent) || !pte_present(ptent))
		return 0;

	page = damon_get_page(pte_pfn(ptent));
	if (!page)
		return 0;

	if (damos_va_filter_out(s, page, walk->vma, addr, pte, NULL))
		goto put_page;

	damos_va_migrate_dests_add(page, walk->vma, addr, dests,
		migration_lists);

put_page:
	put_page(page);
	return 0;
}

/*
 * Functions for the target validity check and cleanup
 */

static bool damon_va_target_valid(struct damon_target *t)
{
	struct task_struct *task;

	task = damon_get_task_struct(t);
	if (task) {
		put_task_struct(task);
		return true;
	}

	return false;
}

static void damon_va_cleanup_target(struct damon_target *t)
{
	put_pid(t->pid);
}

#ifndef CONFIG_ADVISE_SYSCALLS
static unsigned long damos_madvise(struct damon_target *target,
		struct damon_region *r, int behavior)
{
	return 0;
}
#else
static unsigned long damos_madvise(struct damon_target *target,
		struct damon_region *r, int behavior)
{
	/*
	 * 4.9 has no exported do_madvise(); madvise-class actions on the
	 * vaddr ops are not available.  Use the paddr ops for pageout,
	 * lru_prio and lru_deprio instead.
	 */
	return 0;
}
#endif	/* CONFIG_ADVISE_SYSCALLS */

static unsigned long damos_va_migrate(struct damon_target *target,
		struct damon_region *r, struct damos *s,
		unsigned long *sz_filter_passed)
{
	LIST_HEAD(folio_list);
	struct damos_va_migrate_private priv;
	struct mm_struct *mm;
	int nr_dests;
	int nid;
	bool use_target_nid;
	unsigned long applied = 0;
	int i;
	struct damos_migrate_dests *dests = &s->migrate_dests;
	struct mm_walk walk = {
		.pmd_entry = damos_va_migrate_pmd_entry,
		.pte_entry = damos_va_migrate_pte_entry,
		};

	use_target_nid = dests->nr_dests == 0;
	nr_dests = use_target_nid ? 1 : dests->nr_dests;
	priv.scheme = s;
	priv.migration_lists = kmalloc_array(nr_dests,
		sizeof(*priv.migration_lists), GFP_KERNEL);
	if (!priv.migration_lists)
		return 0;

		for (i = 0; i < nr_dests; i++)
		INIT_LIST_HEAD(&priv.migration_lists[i]);


	mm = damon_get_mm(target);
	if (!mm)
		goto free_lists;

	down_read(&mm->mmap_sem);
	walk.mm = mm;
	walk.private = &priv;
	walk_page_range(r->ar.start, r->ar.end, &walk);
	up_read(&mm->mmap_sem);
	mmput(mm);

	for (i = 0; i < nr_dests; i++) {
		nid = use_target_nid ? s->target_nid : dests->node_id_arr[i];
		applied += damon_migrate_pages(&priv.migration_lists[i], nid);
		cond_resched();
	}

free_lists:
	kfree(priv.migration_lists);
	return applied * PAGE_SIZE;
}

struct damos_va_stat_private {
	struct damos *scheme;
	unsigned long *sz_filter_passed;
};

static inline bool damos_va_invalid_page(struct page *page,
		struct damos *s)
{
	return !page || page == s->last_applied;
}

static int damos_va_stat_pmd_entry(pmd_t *pmd, unsigned long addr,
		unsigned long next, struct mm_walk *walk)
{
	struct damos_va_stat_private *priv = walk->private;
	struct damos *s = priv->scheme;
	unsigned long *sz_filter_passed = priv->sz_filter_passed;
	struct vm_area_struct *vma = walk->vma;
	struct page *page;
	spinlock_t *ptl;
	pte_t *start_pte, *pte, ptent;
	int nr;

#ifdef CONFIG_TRANSPARENT_HUGEPAGE
	if (pmd_trans_huge(*pmd)) {
		pmd_t pmde;

		ptl = pmd_trans_huge_lock(pmd, vma);
		if (!ptl)
			return 0;
		pmde = *pmd;
		if (!pmd_present(pmde))
			goto huge_unlock;

		page = vm_normal_page(vma, addr, pmd_page(pmde));

		if (damos_va_invalid_page(page, s))
			goto huge_unlock;

		if (!damos_va_filter_out(s, folio, vma, addr, NULL, pmd))
			*sz_filter_passed += folio_size(folio);
		s->last_applied = folio;

huge_unlock:
		spin_unlock(ptl);
		return 0;
	}
#endif
	start_pte = pte = pte_offset_map_lock(vma->vm_mm, pmd, addr, &ptl);
	if (!start_pte)
		return 0;

	for (; addr < next; pte += nr, addr += nr * PAGE_SIZE) {
		nr = 1;
		ptent = *pte;

		if (pte_none(ptent) || !pte_present(ptent))
			continue;

		page = vm_normal_page(vma, addr, ptent);

		if (damos_va_invalid_page(page, s))
			continue;

		if (!damos_va_filter_out(s, page, vma, addr, pte, NULL))
			*sz_filter_passed += hpage_nr_pages(page) << PAGE_SHIFT;
		nr = hpage_nr_pages(page);
		s->last_applied = page;
	}
	pte_unmap_unlock(start_pte, ptl);
	return 0;
}

static unsigned long damos_va_stat(struct damon_target *target,
		struct damon_region *r, struct damos *s,
		unsigned long *sz_filter_passed)
{
	struct damos_va_stat_private priv;
	struct mm_struct *mm;
	struct mm_walk walk = {
		.pmd_entry = damos_va_stat_pmd_entry,
		};

	priv.scheme = s;
	priv.sz_filter_passed = sz_filter_passed;

	if (!damos_ops_has_filter(s))
		return 0;

	mm = damon_get_mm(target);
	if (!mm)
		return 0;

	down_read(&mm->mmap_sem);
	walk.mm = mm;
	walk.private = &priv;
	walk_page_range(r->ar.start, r->ar.end, &walk);
	up_read(&mm->mmap_sem);
	mmput(mm);
	return 0;
}

static unsigned long damon_va_apply_scheme(struct damon_ctx *ctx,
		struct damon_target *t, struct damon_region *r,
		struct damos *scheme, unsigned long *sz_filter_passed)
{
	int madv_action;

	switch (scheme->action) {
	case DAMOS_WILLNEED:
		madv_action = MADV_WILLNEED;
		break;
	case DAMOS_COLD:
	case DAMOS_PAGEOUT:
		/* 4.9 has no MADV_COLD/MADV_PAGEOUT; drop the pages instead. */
		madv_action = MADV_DONTNEED;
		break;
	case DAMOS_HUGEPAGE:
		madv_action = MADV_HUGEPAGE;
		break;
	case DAMOS_NOHUGEPAGE:
		madv_action = MADV_NOHUGEPAGE;
		break;
	case DAMOS_MIGRATE_HOT:
	case DAMOS_MIGRATE_COLD:
		return damos_va_migrate(t, r, scheme, sz_filter_passed);
	case DAMOS_STAT:
		return damos_va_stat(t, r, scheme, sz_filter_passed);
	default:
		/*
		 * DAMOS actions that are not yet supported by 'vaddr'.
		 */
		return 0;
	}

	return damos_madvise(t, r, madv_action);
}

static int damon_va_scheme_score(struct damon_ctx *context,
		struct damon_target *t, struct damon_region *r,
		struct damos *scheme)
{

	switch (scheme->action) {
	case DAMOS_PAGEOUT:
		return damon_cold_score(context, r, scheme);
	case DAMOS_MIGRATE_HOT:
		return damon_hot_score(context, r, scheme);
	case DAMOS_MIGRATE_COLD:
		return damon_cold_score(context, r, scheme);
	default:
		break;
	}

	return DAMOS_MAX_SCORE;
}

static int __init damon_va_initcall(void)
{
	struct damon_operations ops = {
		.id = DAMON_OPS_VADDR,
		.init = damon_va_init,
		.update = damon_va_update,
		.prepare_access_checks = damon_va_prepare_access_checks,
		.check_accesses = damon_va_check_accesses,
		.target_valid = damon_va_target_valid,
		.cleanup_target = damon_va_cleanup_target,
		.cleanup = NULL,
		.apply_scheme = damon_va_apply_scheme,
		.get_scheme_score = damon_va_scheme_score,
	};
	/* ops for fixed virtual address ranges */
	struct damon_operations ops_fvaddr = ops;
	int err;

	/* Don't set the monitoring target regions for the entire mapping */
	ops_fvaddr.id = DAMON_OPS_FVADDR;
	ops_fvaddr.init = NULL;
	ops_fvaddr.update = NULL;

	err = damon_register_ops(&ops);
	if (err)
		return err;
	return damon_register_ops(&ops_fvaddr);
};

subsys_initcall(damon_va_initcall);

