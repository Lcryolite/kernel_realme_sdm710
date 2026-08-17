// SPDX-License-Identifier: GPL-2.0
/*
 * Multi-generational LRU for the 4.9 VM, ported from AOSP 6.18.
 *
 * Struct-page based port (no folio).  Aging uses the existing rmap
 * reference scanner because 4.9 arm64 has no ARCH_HAS_HW_PTE_YOUNG
 * page-table walker; eviction reuses the classic shrink_page_list()
 * path for writeback, unmapping, swap and final freeing.
 *
 * Runtime state is disabled by default: /sys/kernel/mm/lru_gen/enabled
 * must be written to enable it.
 */

#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/mm.h>
#include <linux/mm_inline.h>
#include <linux/mmzone.h>
#include <linux/memcontrol.h>
#include <linux/rmap.h>
#include <linux/swap.h>
#include <linux/freezer.h>
#include <linux/kobject.h>
#include <linux/sysfs.h>
#include <linux/seq_file.h>

#ifdef CONFIG_LRU_GEN

static bool lru_gen_global_enabled = IS_ENABLED(CONFIG_LRU_GEN_ENABLED);
static unsigned long lru_gen_min_ttl __read_mostly;

bool lru_gen_enabled(struct lruvec *lruvec)
{
	return lru_gen_global_enabled && lruvec->lrugen.enabled;
}

bool lru_gen_is_enabled(void)
{
	return lru_gen_global_enabled;
}
EXPORT_SYMBOL_GPL(lru_gen_is_enabled);

static int get_nr_gens(struct lruvec *lruvec, int type)
{
	return lruvec->lrugen.max_seq - lruvec->lrugen.min_seq[type] + 1;
}

static bool seq_is_valid(struct lruvec *lruvec)
{
	int type;

	for (type = 0; type < ANON_AND_FILE; type++) {
		int n = get_nr_gens(lruvec, type);

		if (n < MIN_NR_GENS || n > MAX_NR_GENS)
			return false;
	}
	return true;
}

static bool lru_gen_empty(struct lruvec *lruvec, int gen, int type)
{
	int zone;

	for (zone = 0; zone < MAX_NR_ZONES; zone++)
		if (lruvec->lrugen.nr_pages[gen][type][zone])
			return false;
	return true;
}

static void lru_gen_refresh_vmstats(struct lruvec *lruvec, int old_max,
					int new_max, int type)
{
	int gen, zone;

	if (old_max == new_max)
		return;

	for (gen = 0; gen < MAX_NR_GENS; gen++) {
		bool old_active = gen == lru_gen_from_seq(old_max) ||
				  gen == lru_gen_from_seq(old_max - 1);
		bool new_active = gen == lru_gen_from_seq(new_max) ||
				  gen == lru_gen_from_seq(new_max - 1);

		if (old_active == new_active)
			continue;

		for (zone = 0; zone < MAX_NR_ZONES; zone++) {
			long nr = lruvec->lrugen.nr_pages[gen][type][zone];
			enum lru_list lru = type ? LRU_INACTIVE_FILE :
						 LRU_INACTIVE_ANON;

			if (!nr)
				continue;
			if (old_active)
				update_lru_size(lruvec, lru + LRU_ACTIVE, zone, -nr);
			else
				update_lru_size(lruvec, lru, zone, -nr);
			if (new_active)
				update_lru_size(lruvec, lru + LRU_ACTIVE, zone, nr);
			else
				update_lru_size(lruvec, lru, zone, nr);
		}
	}
}

/* Advance the oldest generation; the slot about to be evicted is empty. */
static void inc_min_seq(struct lruvec *lruvec, int type)
{
	unsigned long min_seq = lruvec->lrugen.min_seq[type];
	unsigned long max_seq = lruvec->lrugen.max_seq;

	while (min_seq + MIN_NR_GENS <= max_seq &&
	       lru_gen_empty(lruvec, lru_gen_from_seq(min_seq), type))
		min_seq++;

	lruvec->lrugen.min_seq[type] = min_seq;
}

void lru_gen_init_lruvec(struct lruvec *lruvec)
{
	unsigned int gen, type, zone;
	struct lru_gen_struct *lrugen = &lruvec->lrugen;

	BUILD_BUG_ON(MIN_NR_GENS < 2U);
	BUILD_BUG_ON(MIN_NR_GENS >= MAX_NR_GENS);

	lrugen->max_seq = MIN_NR_GENS - 1;
	lrugen->min_seq[LRU_GEN_ANON] = 0;
	lrugen->min_seq[LRU_GEN_FILE] = 0;
	lrugen->enabled = true;

	for (gen = 0; gen < MAX_NR_GENS; gen++) {
		lrugen->timestamps[gen] = jiffies;
		for (type = 0; type < ANON_AND_FILE; type++)
			for (zone = 0; zone < MAX_NR_ZONES; zone++) {
				INIT_LIST_HEAD(&lrugen->lists[gen][type][zone]);
				lrugen->nr_pages[gen][type][zone] = 0;
			}
	}
}

struct lru_gen_scan_page {
	struct list_head list;
	struct page *page;
	int gen;
	int type;
	unsigned int nr_pages;
	bool referenced;
};

/*
 * Scan a bounded batch of the oldest generation for young pages.
 *
 * A generation list is the LRU list while CONFIG_LRU_GEN is enabled: the
 * page->lru entry must never be linked into a classic list and a generation
 * list at the same time.  Pages are fully isolated (including PageLRU and
 * generation accounting) before dropping lru_lock for the rmap walk.
 */
/* Advance the epoch when the slot about to be reused is empty. */
void lru_gen_age(struct lruvec *lruvec, int type)
{
	unsigned long next = lruvec->lrugen.max_seq + 1;
	int old_max, gen;

	gen = lru_gen_from_seq(next);
	if (!lru_gen_empty(lruvec, gen, type))
		return;

	old_max = lruvec->lrugen.max_seq;
	lruvec->lrugen.max_seq = next;
	lruvec->lrugen.timestamps[lru_gen_from_seq(next)] = jiffies;
	lru_gen_refresh_vmstats(lruvec, old_max, next, type);
	inc_min_seq(lruvec, type);
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
		struct list_head *src;
		struct page *page;
		int gen, aging_gen, zone;

		/* Keep the aging interruptible for the suspend freezer. */
		if (unlikely(freezing(current)))
			break;

		aging_gen = lru_gen_from_seq(lruvec->lrugen.min_seq[type]);
		src = NULL;
		for (zone = 0; zone <= zone_idx && zone < MAX_NR_ZONES; zone++)
			if (!list_empty(&lruvec->lrugen.lists[aging_gen][type][zone])) {
				src = &lruvec->lrugen.lists[aging_gen][type][zone];
				break;
			}
		if (!src)
			break;

		page = lru_to_page(src);
		if (!get_page_unless_zero(page)) {
			list_move_tail(&page->lru, src);
			nr++;
			continue;
		}

		gen = page_lru_gen(page);
		ClearPageLRU(page);
		if (unlikely(!lru_gen_del_page(lruvec, page, true))) {
			SetPageLRU(page);
			put_page(page);
			list_move_tail(&page->lru, src);
			nr++;
			continue;
		}

		item = &batch[nr++];
		INIT_LIST_HEAD(&item->list);
		item->page = page;
		item->gen = gen;
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

		/* page_referenced() clears PTE young bits through the rmap walk. */
		item->referenced = page_referenced(item->page, 0, memcg,
						  &vm_flags) > 0;
	}

	spin_lock_irq(&pgdat->lru_lock);

	while (!list_empty(&pages)) {
		struct lruvec *dst;
		struct page *page;
		int gen;

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
			gen = item->referenced ?
				lru_gen_from_seq(dst->lrugen.max_seq) : item->gen;
			SetPageLRU(page);
			if (dst == lruvec &&
			    page_is_file_cache(page) == type &&
			    lru_gen_add_page_gen(dst, page, gen, true)) {
				/* Reinserted in the exact generation. */
			} else {
				add_page_to_lru_list_tail(page, dst,
							  page_lru_base_type(page));
			}
		}
		__mod_node_page_state(pgdat, NR_ISOLATED_ANON + item->type,
				      -item->nr_pages);
		put_page(page);
	}
}

struct list_head *lru_gen_get_list(struct lruvec *lruvec, int type,
					bool active, int zone_idx)
{
	unsigned long seq;
	int gen, zone;

	if (!lru_gen_enabled(lruvec))
		return NULL;

	/* Oldest-to-youngest for reclaim, second-youngest-to-youngest for aging. */
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
	unsigned long nr = 0;
	int gen, zone;

	for (gen = 0; gen < MAX_NR_GENS; gen++) {
		if (lru_gen_is_active(lruvec, gen) != active)
			continue;
		for (zone = 0; zone <= zone_idx && zone < MAX_NR_ZONES; zone++)
			nr += max_t(long, 0, lruvec->lrugen.nr_pages[gen][type][zone]);
	}
	return nr;
}

void lru_gen_online_memcg(struct mem_cgroup *memcg)
{
}

void lru_gen_offline_memcg(struct mem_cgroup *memcg)
{
}

bool lru_gen_soft_reclaim(struct mem_cgroup *memcg, int nid)
{
	return false;
}

/******************************************************************************
 *                          sysfs interface
 ******************************************************************************/

static ssize_t enabled_show(struct kobject *kobj, struct kobj_attribute *attr,
			    char *buf)
{
	return snprintf(buf, PAGE_SIZE, "%d\n", lru_gen_global_enabled);
}

static ssize_t enabled_store(struct kobject *kobj, struct kobj_attribute *attr,
			     const char *buf, size_t count)
{
	bool enable;
	int nid;

	if (kstrtobool(buf, &enable))
		return -EINVAL;

	lru_gen_global_enabled = enable;
	for_each_node(nid) {
		struct lruvec *lruvec = mem_cgroup_lruvec(NODE_DATA(nid), NULL);

		WRITE_ONCE(lruvec->lrugen.enabled, enable);
	}
	return count;
}

static ssize_t min_ttl_ms_show(struct kobject *kobj, struct kobj_attribute *attr,
			       char *buf)
{
	return snprintf(buf, PAGE_SIZE, "%lu\n", lru_gen_min_ttl);
}

static ssize_t min_ttl_ms_store(struct kobject *kobj,
				struct kobj_attribute *attr,
				const char *buf, size_t count)
{
	unsigned long msecs;

	if (kstrtoul(buf, 0, &msecs))
		return -EINVAL;

	lru_gen_min_ttl = msecs;
	return count;
}

static ssize_t stats_show(struct kobject *kobj, struct kobj_attribute *attr,
			  char *buf)
{
	int nid, type, gen, zone;
	unsigned long total = 0;
	ssize_t len = 0;

	for_each_node(nid) {
		struct lruvec *lruvec = mem_cgroup_lruvec(NODE_DATA(nid), NULL);

		for (type = 0; type < ANON_AND_FILE; type++)
			for (gen = 0; gen < MAX_NR_GENS; gen++)
				for (zone = 0; zone < MAX_NR_ZONES; zone++)
					total += max_t(long, 0,
						lruvec->lrugen.nr_pages[gen][type][zone]);
	}
	len += snprintf(buf + len, PAGE_SIZE - len,
			"total %lu\n", total);
	return len;
}

static struct kobj_attribute lru_gen_enabled_attr =
	__ATTR(enabled, 0644, enabled_show, enabled_store);
static struct kobj_attribute lru_gen_min_ttl_attr =
	__ATTR(min_ttl_ms, 0644, min_ttl_ms_show, min_ttl_ms_store);
static struct kobj_attribute lru_gen_stats_attr =
	__ATTR_RO(stats);

static struct attribute *lru_gen_attrs[] = {
	&lru_gen_enabled_attr.attr,
	&lru_gen_min_ttl_attr.attr,
	&lru_gen_stats_attr.attr,
	NULL,
};

static const struct attribute_group lru_gen_attr_group = {
	.attrs = lru_gen_attrs,
};

static int __init lru_gen_init(void)
{
	struct kobject *lru_gen_kobj;

	/* mm_kobj is created by mm_sysfs_init(); reuse it. */
	lru_gen_kobj = kobject_create_and_add("lru_gen", mm_kobj);
	if (!lru_gen_kobj)
		return -ENOMEM;

	return sysfs_create_group(lru_gen_kobj, &lru_gen_attr_group);
}
/* mm_kobj is created by mm_sysfs_init() (__initcall); run after it. */
late_initcall(lru_gen_init);

#endif /* CONFIG_LRU_GEN */
