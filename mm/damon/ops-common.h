/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Common Code for Data Access Monitoring
 *
 * Author: SeongJae Park <sj@kernel.org>
 *
 * 4.9 struct-page port of the 6.18 implementation.
 */

#include <linux/damon.h>

struct page *damon_get_page(unsigned long pfn);

void damon_ptep_mkold(pte_t *pte, struct vm_area_struct *vma, unsigned long addr);
void damon_pmdp_mkold(pmd_t *pmd, struct vm_area_struct *vma, unsigned long addr);
void damon_page_mkold(struct page *page);
bool damon_page_young(struct page *page);

int damon_cold_score(struct damon_ctx *c, struct damon_region *r,
			struct damos *s);
int damon_hot_score(struct damon_ctx *c, struct damon_region *r,
			struct damos *s);

bool damos_page_filter_match(struct damos_filter *filter, struct page *page);
unsigned long damon_migrate_pages(struct list_head *page_list, int target_nid);

bool damos_ops_has_filter(struct damos *s);
