// SPDX-License-Identifier: GPL-2.0
/*
 * Minimal multi-generational LRU for the 4.9 VM.
 *
 * Generation lists select pages for aging and isolation. The existing 4.9
 * shrink_page_list() path remains responsible for writeback, unmapping, swap
 * and final freeing. Runtime switching is deliberately unsupported because
 * moving live pages between the classic and generation lists is not atomic.
 */

#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/kobject.h>
#include <linux/memcontrol.h>
#include <linux/mm.h>
#include <linux/mm_inline.h>
#include <linux/mmzone.h>
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
