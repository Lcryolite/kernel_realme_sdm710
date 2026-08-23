// SPDX-License-Identifier: GPL-2.0
/*
 * Minimal multi-generational LRU for the 4.9 VM.
 *
 * Generation lists select pages for aging and isolation. The existing 4.9
 * shrink_page_list() path remains responsible for writeback, unmapping, swap
 * and final freeing. Runtime switching is deliberately unsupported because
 * moving live pages between the classic and generation lists is not atomic.
 */

#include <linux/freezer.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/kobject.h>
#include <linux/memcontrol.h>
#include <linux/mm.h>
#include <linux/mm_inline.h>
#include <linux/mmzone.h>
#include <linux/rmap.h>
#include <linux/swap.h>
#include <linux/sysfs.h>

static bool lru_gen_empty(struct lruvec *lruvec, int gen, int type)
{
	int zone;

	for (zone = 0; zone < MAX_NR_ZONES; zone++)
		if (lruvec->lrugen.nr_pages[gen][type][zone])
			return false;
	return true;
}

static bool lru_gen_slot_empty(struct lruvec *lruvec, int gen)
{
	return lru_gen_empty(lruvec, gen, MGLRU_ANON) &&
	       lru_gen_empty(lruvec, gen, MGLRU_FILE);
}

static void lru_gen_refresh_vmstats(struct lruvec *lruvec,
					 unsigned long old_max,
					 unsigned long new_max)
{
	int gen, type, zone;

	if (old_max == new_max)
		return;

	for (gen = 0; gen < MGLRU_MAX_NR_GENS; gen++) {
		bool old_active = gen == lru_gen_from_seq(old_max) ||
				  gen == lru_gen_from_seq(old_max - 1);
		bool new_active = gen == lru_gen_from_seq(new_max) ||
				  gen == lru_gen_from_seq(new_max - 1);

		if (old_active == new_active)
			continue;

		for (type = 0; type < MGLRU_NR_TYPES; type++) {
			enum lru_list lru = type ? LRU_INACTIVE_FILE :
							 LRU_INACTIVE_ANON;

			for (zone = 0; zone < MAX_NR_ZONES; zone++) {
				long nr = lruvec->lrugen.nr_pages[gen][type][zone];

				if (!nr)
					continue;
				if (old_active)
					update_lru_size(lruvec, lru + LRU_ACTIVE,
							zone, -nr);
				else
					update_lru_size(lruvec, lru, zone, -nr);
				if (new_active)
					update_lru_size(lruvec, lru + LRU_ACTIVE,
							zone, nr);
				else
					update_lru_size(lruvec, lru, zone, nr);
			}
		}
	}
}

static void lru_gen_advance_min_seq(struct lruvec *lruvec, int type)
{
	unsigned long min_seq = lruvec->lrugen.min_seq[type];
	unsigned long max_seq = lruvec->lrugen.max_seq;

	/* Always retain one inactive generation below the two active ones. */
	while (min_seq + MGLRU_NR_ACTIVE_GENS < max_seq &&
	       lru_gen_empty(lruvec, lru_gen_from_seq(min_seq), type))
		min_seq++;

	lruvec->lrugen.min_seq[type] = min_seq;
}

void lru_gen_init_lruvec(struct lruvec *lruvec)
{
	unsigned int gen, type, zone;
	struct lru_gen_struct *lrugen = &lruvec->lrugen;

	BUILD_BUG_ON(MGLRU_NR_ACTIVE_GENS < 2U);
	BUILD_BUG_ON(MGLRU_NR_ACTIVE_GENS >= MGLRU_MAX_NR_GENS);

	/* gen0 starts inactive; gen1 and gen2 start active. */
	lrugen->max_seq = MGLRU_NR_ACTIVE_GENS;
	lrugen->min_seq[MGLRU_ANON] = 0;
	lrugen->min_seq[MGLRU_FILE] = 0;

	for (gen = 0; gen < MGLRU_MAX_NR_GENS; gen++)
		for (type = 0; type < MGLRU_NR_TYPES; type++)
			for (zone = 0; zone < MAX_NR_ZONES; zone++) {
				INIT_LIST_HEAD(&lrugen->lists[gen][type][zone]);
				lrugen->nr_pages[gen][type][zone] = 0;
			}
}

struct lru_gen_scan_page {
	struct list_head list;
	struct page *page;
	unsigned long seq;
	int type;
	unsigned int nr_pages;
	bool referenced;
};

static unsigned long lru_gen_seq(struct lruvec *lruvec, int type, int gen)
{
	unsigned long seq;

	for (seq = lruvec->lrugen.min_seq[type];
	     seq <= lruvec->lrugen.max_seq; seq++)
		if (lru_gen_from_seq(seq) == gen)
			return seq;

	return lruvec->lrugen.min_seq[type];
}

void lru_gen_scan(struct lruvec *lruvec, int type,
		  struct mem_cgroup *memcg, int zone_idx)
{
	struct pglist_data *pgdat = lruvec_pgdat(lruvec);
	struct lru_gen_scan_page batch[SWAP_CLUSTER_MAX];
	LIST_HEAD(pages);
	struct lru_gen_scan_page *item;
	unsigned int nr = 0;

	lockdep_assert_held(&pgdat->lru_lock);

	while (nr < SWAP_CLUSTER_MAX) {
		struct list_head *src = NULL;
		struct page *page;
		int gen, zone;

		if (unlikely(freezing(current)))
			break;

		gen = lru_gen_from_seq(lruvec->lrugen.min_seq[type]);
		for (zone = 0; zone <= zone_idx && zone < MAX_NR_ZONES; zone++)
			if (!list_empty(&lruvec->lrugen.lists[gen][type][zone])) {
				src = &lruvec->lrugen.lists[gen][type][zone];
				break;
			}
		if (!src)
			break;

		page = lru_to_page(src);
		if (!get_page_unless_zero(page)) {
			list_move(&page->lru, src);
			nr++;
			continue;
		}

		gen = page_lru_gen(page);
		ClearPageLRU(page);
		if (unlikely(!lru_gen_del_page(lruvec, page))) {
			SetPageLRU(page);
			put_page(page);
			list_move_tail(&page->lru, src);
			nr++;
			continue;
		}

		item = &batch[nr++];
		INIT_LIST_HEAD(&item->list);
		item->page = page;
		item->seq = lru_gen_seq(lruvec, type, gen);
		item->type = type;
		item->nr_pages = hpage_nr_pages(page);
		item->referenced = false;
		__mod_node_page_state(pgdat, NR_ISOLATED_ANON + type,
				      item->nr_pages);
		list_add_tail(&item->list, &pages);
	}

	if (list_empty(&pages))
		return;

	spin_unlock_irq(&pgdat->lru_lock);
	list_for_each_entry(item, &pages, list) {
		unsigned long vm_flags;

		item->referenced = page_referenced(item->page, 0, memcg,
						  &vm_flags) > 0;
	}
	spin_lock_irq(&pgdat->lru_lock);

	while (!list_empty(&pages)) {
		struct lruvec *dst;
		struct page *page;
		unsigned long seq;

		item = list_first_entry(&pages, struct lru_gen_scan_page, list);
		list_del(&item->list);
		page = item->page;
		dst = mem_cgroup_page_lruvec(page, pgdat);

		if (unlikely(!page_evictable(page))) {
			ClearPageActive(page);
			SetPageUnevictable(page);
			SetPageLRU(page);
			add_page_to_lru_list(page, dst, LRU_UNEVICTABLE);
		} else {
			seq = item->referenced ? dst->lrugen.max_seq : item->seq;
			if (seq < dst->lrugen.min_seq[item->type] ||
			    seq > dst->lrugen.max_seq)
				seq = dst->lrugen.min_seq[item->type];

			SetPageLRU(page);
			if (dst == lruvec && page_is_file_cache(page) == type &&
			    lru_gen_add_page_gen(dst, page, lru_gen_from_seq(seq),
						  true)) {
				/* Reinserted with a sequence valid in the current epoch. */
			} else {
				add_page_to_lru_list_tail(page, dst,
							  page_lru_base_type(page));
			}
		}
		__mod_node_page_state(pgdat, NR_ISOLATED_ANON + item->type,
				      -(long)item->nr_pages);
		put_page(page);
	}
}

void lru_gen_age(struct lruvec *lruvec)
{
	unsigned long old_max = lruvec->lrugen.max_seq;
	unsigned long next = old_max + 1;
	int gen = lru_gen_from_seq(next);
	int type;

	lockdep_assert_held(&lruvec_pgdat(lruvec)->lru_lock);

	/* max_seq is shared: never reuse a slot occupied by either type. */
	if (!lru_gen_slot_empty(lruvec, gen))
		return;

	lruvec->lrugen.max_seq = next;
	lru_gen_refresh_vmstats(lruvec, old_max, next);
	for (type = 0; type < MGLRU_NR_TYPES; type++)
		lru_gen_advance_min_seq(lruvec, type);
}

struct list_head *lru_gen_get_list(struct lruvec *lruvec, int type,
				   bool active, int zone_idx)
{
	unsigned long seq;
	int gen, zone;

	for (seq = lruvec->lrugen.min_seq[type];
	     seq <= lruvec->lrugen.max_seq; seq++) {
		gen = lru_gen_from_seq(seq);
		if (lru_gen_is_active(lruvec, gen) != active)
			continue;
		for (zone = 0; zone <= zone_idx && zone < MAX_NR_ZONES; zone++)
			if (!list_empty(&lruvec->lrugen.lists[gen][type][zone]))
				return &lruvec->lrugen.lists[gen][type][zone];
	}
	return NULL;
}

unsigned long lru_gen_size(struct lruvec *lruvec, int type,
			   bool active, int zone_idx)
{
	unsigned long max_seq = READ_ONCE(lruvec->lrugen.max_seq);
	unsigned long nr = 0;
	int gen, zone;

	for (gen = 0; gen < MGLRU_MAX_NR_GENS; gen++) {
		bool gen_active = gen == lru_gen_from_seq(max_seq) ||
				  gen == lru_gen_from_seq(max_seq - 1);

		if (gen_active != active)
			continue;
		for (zone = 0; zone <= zone_idx && zone < MAX_NR_ZONES; zone++)
			nr += max_t(long, 0,
				    READ_ONCE(lruvec->lrugen.nr_pages[gen][type][zone]));
	}
	return nr;
}

static ssize_t enabled_show(struct kobject *kobj,
			    struct kobj_attribute *attr, char *buf)
{
	return scnprintf(buf, PAGE_SIZE, "1\n");
}

static ssize_t stats_show(struct kobject *kobj, struct kobj_attribute *attr,
			  char *buf)
{
	ssize_t len = 0;
	int nid;

	for_each_node(nid) {
		struct pglist_data *pgdat = NODE_DATA(nid);
		struct lruvec *lruvec = mem_cgroup_lruvec(pgdat, NULL);
		unsigned long flags, max_seq, min_seq[MGLRU_NR_TYPES];
		long nr_pages[MGLRU_MAX_NR_GENS][MGLRU_NR_TYPES] = { { 0 } };
		int gen, type, zone;

		spin_lock_irqsave(&pgdat->lru_lock, flags);
		max_seq = lruvec->lrugen.max_seq;
		for (type = 0; type < MGLRU_NR_TYPES; type++)
			min_seq[type] = lruvec->lrugen.min_seq[type];
		for (gen = 0; gen < MGLRU_MAX_NR_GENS; gen++)
			for (type = 0; type < MGLRU_NR_TYPES; type++)
				for (zone = 0; zone < MAX_NR_ZONES; zone++)
					nr_pages[gen][type] +=
						lruvec->lrugen.nr_pages[gen][type][zone];
		spin_unlock_irqrestore(&pgdat->lru_lock, flags);

		len += scnprintf(buf + len, PAGE_SIZE - len,
				 "node %d min %lu %lu max %lu\n", nid,
				 min_seq[MGLRU_ANON], min_seq[MGLRU_FILE], max_seq);
		for (gen = 0; gen < MGLRU_MAX_NR_GENS && len < PAGE_SIZE; gen++)
			len += scnprintf(buf + len, PAGE_SIZE - len,
					 "node %d gen %d anon %ld file %ld\n",
					 nid, gen, nr_pages[gen][MGLRU_ANON],
					 nr_pages[gen][MGLRU_FILE]);
	}

	return len;
}

static struct kobj_attribute lru_gen_enabled_attr = __ATTR_RO(enabled);
static struct kobj_attribute lru_gen_stats_attr = __ATTR_RO(stats);

static struct attribute *lru_gen_attrs[] = {
	&lru_gen_enabled_attr.attr,
	&lru_gen_stats_attr.attr,
	NULL,
};

static const struct attribute_group lru_gen_attr_group = {
	.attrs = lru_gen_attrs,
};

static int __init lru_gen_init(void)
{
	struct kobject *lru_gen_kobj;

	lru_gen_kobj = kobject_create_and_add("lru_gen", mm_kobj);
	if (!lru_gen_kobj)
		return -ENOMEM;

	return sysfs_create_group(lru_gen_kobj, &lru_gen_attr_group);
}
late_initcall(lru_gen_init);
