#ifndef LINUX_MM_INLINE_H
#define LINUX_MM_INLINE_H

#include <linux/huge_mm.h>
#include <linux/swap.h>

/**
 * page_is_file_cache - should the page be on a file LRU or anon LRU?
 * @page: the page to test
 *
 * Returns 1 if @page is page cache page backed by a regular filesystem,
 * or 0 if @page is anonymous, tmpfs or otherwise ram or swap backed.
 * Used by functions that manipulate the LRU lists, to sort a page
 * onto the right LRU list.
 *
 * We would like to get this info without a page flag, but the state
 * needs to survive until the page is last deleted from the LRU, which
 * could be as far down as __page_cache_release.
 */
static inline int page_is_file_cache(struct page *page)
{
	return !PageSwapBacked(page);
}

static __always_inline void __update_lru_size(struct lruvec *lruvec,
				enum lru_list lru, enum zone_type zid,
				int nr_pages)
{
	struct pglist_data *pgdat = lruvec_pgdat(lruvec);

	__mod_node_page_state(pgdat, NR_LRU_BASE + lru, nr_pages);
	__mod_zone_page_state(&pgdat->node_zones[zid],
				NR_ZONE_LRU_BASE + lru, nr_pages);
}

static __always_inline void update_lru_size(struct lruvec *lruvec,
				enum lru_list lru, enum zone_type zid,
				int nr_pages)
{
	__update_lru_size(lruvec, lru, zid, nr_pages);
#ifdef CONFIG_MEMCG
	mem_cgroup_update_lru_size(lruvec, lru, zid, nr_pages);
#endif
}

#ifdef CONFIG_LRU_GEN
static __always_inline int page_lru_gen(struct page *page)
{
	unsigned long flags = READ_ONCE(page->flags);

	return ((flags & LRU_GEN_MASK) >> LRU_GEN_PGOFF) - 1;
}

static __always_inline int lru_gen_from_seq(unsigned long seq)
{
	return seq % MGLRU_MAX_NR_GENS;
}

static __always_inline unsigned long lru_gen_max_seq(struct lruvec *lruvec)
{
	return lruvec->lrugen.max_seq;
}

static __always_inline unsigned long lru_gen_min_seq(struct lruvec *lruvec,
						      int type)
{
	return lruvec->lrugen.min_seq[type];
}

static __always_inline bool lru_gen_is_active(struct lruvec *lruvec, int gen)
{
	unsigned long max_seq = READ_ONCE(lruvec->lrugen.max_seq);

	return gen == lru_gen_from_seq(max_seq) ||
	       gen == lru_gen_from_seq(max_seq - 1);
}

static __always_inline bool lru_gen_page_active(struct lruvec *lruvec,
						 struct page *page)
{
	int gen = page_lru_gen(page);

	return gen >= 0 && lru_gen_is_active(lruvec, gen);
}

static __always_inline bool lru_gen_page_youngest(struct lruvec *lruvec,
						   struct page *page)
{
	return page_lru_gen(page) == lru_gen_from_seq(lruvec->lrugen.max_seq);
}

static __always_inline void lru_gen_update_size(struct lruvec *lruvec,
						 struct page *page,
						 int old_gen, int new_gen)
{
	int type = page_is_file_cache(page);
	int zone = page_zonenum(page);
	int delta = hpage_nr_pages(page);
	enum lru_list lru = type ? LRU_INACTIVE_FILE : LRU_INACTIVE_ANON;
	struct lru_gen_struct *lrugen = &lruvec->lrugen;
	long nr;

	if (old_gen >= 0) {
		nr = lrugen->nr_pages[old_gen][type][zone] -= delta;
		VM_WARN_ON_ONCE(nr < 0);
	}
	if (new_gen >= 0)
		lrugen->nr_pages[new_gen][type][zone] += delta;

	if (old_gen < 0) {
		if (lru_gen_is_active(lruvec, new_gen))
			lru += LRU_ACTIVE;
		update_lru_size(lruvec, lru, zone, delta);
	} else if (new_gen < 0) {
		if (lru_gen_is_active(lruvec, old_gen))
			lru += LRU_ACTIVE;
		update_lru_size(lruvec, lru, zone, -delta);
	} else if (!lru_gen_is_active(lruvec, old_gen) &&
		   lru_gen_is_active(lruvec, new_gen)) {
		update_lru_size(lruvec, lru, zone, -delta);
		update_lru_size(lruvec, lru + LRU_ACTIVE, zone, delta);
	} else if (lru_gen_is_active(lruvec, old_gen) &&
		   !lru_gen_is_active(lruvec, new_gen)) {
		update_lru_size(lruvec, lru + LRU_ACTIVE, zone, -delta);
		update_lru_size(lruvec, lru, zone, delta);
	}
}

static __always_inline bool lru_gen_add_page_gen(struct lruvec *lruvec,
						  struct page *page, int gen,
						  bool tail)
{
	int type, zone;

	if (PageUnevictable(page) || gen < 0 || gen >= MGLRU_MAX_NR_GENS)
		return false;

	type = page_is_file_cache(page);
	zone = page_zonenum(page);
	set_mask_bits(&page->flags, LRU_GEN_MASK | BIT(PG_active),
		      (gen + 1UL) << LRU_GEN_PGOFF);
	lru_gen_update_size(lruvec, page, -1, gen);
	if (tail)
		list_add_tail(&page->lru, &lruvec->lrugen.lists[gen][type][zone]);
	else
		list_add(&page->lru, &lruvec->lrugen.lists[gen][type][zone]);
	return true;
}

static __always_inline bool lru_gen_add_page(struct lruvec *lruvec,
						struct page *page, bool tail)
{
	unsigned long seq;
	int type;

	if (PageUnevictable(page))
		return false;

	type = page_is_file_cache(page);
	if (PageActive(page))
		seq = lruvec->lrugen.max_seq;
	else if (!type && !PageSwapCache(page))
		seq = lruvec->lrugen.min_seq[type] + 1;
	else if (PageReclaim(page) && (PageDirty(page) || PageWriteback(page)))
		seq = lruvec->lrugen.min_seq[type] + 1;
	else
		seq = lruvec->lrugen.min_seq[type];

	return lru_gen_add_page_gen(lruvec, page, lru_gen_from_seq(seq), tail);
}

static __always_inline bool lru_gen_del_page(struct lruvec *lruvec,
						struct page *page)
{
	int gen = page_lru_gen(page);

	if (gen < 0)
		return false;

	set_mask_bits(&page->flags, LRU_GEN_MASK | BIT(PG_active),
		      lru_gen_is_active(lruvec, gen) ? BIT(PG_active) : 0);
	lru_gen_update_size(lruvec, page, gen, -1);
	list_del(&page->lru);
	return true;
}

static __always_inline bool lru_gen_move_page(struct lruvec *lruvec,
						 struct page *page,
						 unsigned long seq, bool tail)
{
	if (!lru_gen_del_page(lruvec, page))
		return false;

	ClearPageActive(page);
	return lru_gen_add_page_gen(lruvec, page, lru_gen_from_seq(seq), tail);
}
#else
static __always_inline int page_lru_gen(struct page *page)
{
	return -1;
}
static __always_inline unsigned long lru_gen_max_seq(struct lruvec *lruvec)
{
	return 0;
}
static __always_inline unsigned long lru_gen_min_seq(struct lruvec *lruvec,
						      int type)
{
	return 0;
}
static __always_inline bool lru_gen_page_active(struct lruvec *lruvec,
						 struct page *page)
{
	return false;
}
static __always_inline bool lru_gen_page_youngest(struct lruvec *lruvec,
						   struct page *page)
{
	return false;
}
static __always_inline bool lru_gen_add_page_gen(struct lruvec *lruvec,
						  struct page *page, int gen,
						  bool tail)
{
	return false;
}
static __always_inline bool lru_gen_add_page(struct lruvec *lruvec,
						struct page *page, bool tail)
{
	return false;
}
static __always_inline bool lru_gen_del_page(struct lruvec *lruvec,
						struct page *page)
{
	return false;
}
static __always_inline bool lru_gen_move_page(struct lruvec *lruvec,
						 struct page *page,
						 unsigned long seq, bool tail)
{
	return false;
}
#endif

static __always_inline void add_page_to_lru_list(struct page *page,
				struct lruvec *lruvec, enum lru_list lru)
{
	if (lru_gen_add_page(lruvec, page, false))
		return;
	update_lru_size(lruvec, lru, page_zonenum(page), hpage_nr_pages(page));
	list_add(&page->lru, &lruvec->lists[lru]);
}

static __always_inline void add_page_to_lru_list_tail(struct page *page,
				struct lruvec *lruvec, enum lru_list lru)
{
	if (lru_gen_add_page(lruvec, page, true))
		return;
	update_lru_size(lruvec, lru, page_zonenum(page), hpage_nr_pages(page));
	list_add_tail(&page->lru, &lruvec->lists[lru]);
}

static __always_inline void del_page_from_lru_list(struct page *page,
				struct lruvec *lruvec, enum lru_list lru)
{
	if (lru_gen_del_page(lruvec, page))
		return;
	list_del(&page->lru);
	update_lru_size(lruvec, lru, page_zonenum(page), -hpage_nr_pages(page));
}

/**
 * page_lru_base_type - which LRU list type should a page be on?
 * @page: the page to test
 *
 * Used for LRU list index arithmetic.
 *
 * Returns the base LRU type - file or anon - @page should be on.
 */
static inline enum lru_list page_lru_base_type(struct page *page)
{
	if (page_is_file_cache(page))
		return LRU_INACTIVE_FILE;
	return LRU_INACTIVE_ANON;
}

/**
 * page_off_lru - which LRU list was page on? clearing its lru flags.
 * @page: the page to test
 *
 * Returns the LRU list a page was on, as an index into the array of LRU
 * lists; and clears its Unevictable or Active flags, ready for freeing.
 */
static __always_inline enum lru_list page_off_lru(struct page *page)
{
	enum lru_list lru;

	if (PageUnevictable(page)) {
		__ClearPageUnevictable(page);
		lru = LRU_UNEVICTABLE;
	} else {
		lru = page_lru_base_type(page);
		if (PageActive(page)) {
			__ClearPageActive(page);
			lru += LRU_ACTIVE;
		}
	}
	return lru;
}

/**
 * page_lru - which LRU list should a page be on?
 * @page: the page to test
 *
 * Returns the LRU list a page should be on, as an index
 * into the array of LRU lists.
 */
static __always_inline enum lru_list page_lru(struct page *page)
{
	enum lru_list lru;

	if (PageUnevictable(page))
		lru = LRU_UNEVICTABLE;
	else {
		lru = page_lru_base_type(page);
		if (PageActive(page))
			lru += LRU_ACTIVE;
	}
	return lru;
}

#define lru_to_page(head) (list_entry((head)->prev, struct page, lru))

#endif
