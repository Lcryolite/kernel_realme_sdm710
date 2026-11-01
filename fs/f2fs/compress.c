// SPDX-License-Identifier: GPL-2.0
/*
 * F2FS compression format from Linux commit 4c8ff7095bef.
 * Copyright (c) 2019 Chao Yu <chao@kernel.org>
 *
 * This 4.9 adapter uses the existing read/decryption completion path. Temporary
 * storage pages carry the on-disk logical slot index, as required by fscrypt
 * and the vendor ICE data-unit numbering. The read helper does not acquire
 * any other page-cache page lock while reading a cluster.
 */
#include <linux/fs.h>
#include <linux/f2fs_fs.h>
#include <linux/lz4.h>
#include <linux/zstd.h>
#include <linux/writeback.h>
#include <linux/backing-dev.h>

#include "f2fs.h"
#include "node.h"
#include "segment.h"

bool f2fs_is_compress_backend_ready(struct inode *inode)
{
	if (!f2fs_compressed_file(inode))
		return true;

	switch (F2FS_I(inode)->i_compress_algorithm) {
	case COMPRESS_LZ4:
		return IS_ENABLED(CONFIG_F2FS_FS_LZ4);
	case COMPRESS_ZSTD:
		return IS_ENABLED(CONFIG_F2FS_FS_ZSTD);
	default:
		return false;
	}
}

/* Includes the marker, and rejects markers misplaced in ordinary clusters. */
static int compressed_cluster_blocks(struct dnode_of_data *dn)
{
	struct inode *inode = dn->inode;
	unsigned int cluster_size = F2FS_I(inode)->i_cluster_size;
	bool compressed = dn->data_blkaddr == COMPRESS_ADDR;
	bool ended = false;
	unsigned int i;
	int blocks = 1;

	if (dn->ofs_in_node % cluster_size ||
			dn->ofs_in_node + cluster_size >
			(IS_INODE(dn->node_page) ? addrs_per_inode(inode) :
			 addrs_per_block(inode)))
		return -EFSCORRUPTED;

	for (i = 1; i < cluster_size; i++) {
		block_t addr = datablock_addr(inode, dn->node_page,
						 dn->ofs_in_node + i);

		if (!compressed) {
			if (addr == COMPRESS_ADDR)
				return -EFSCORRUPTED;
			continue;
		}
		if (addr == NEW_ADDR) {
			ended = true;
			continue;
		}
		if (ended || !__is_valid_data_blkaddr(addr) ||
				!f2fs_is_valid_blkaddr(F2FS_I_SB(inode), addr,
						DATA_GENERIC_ENHANCE_READ))
			return -EFSCORRUPTED;
		blocks++;
	}
	if (!compressed)
		return 0;
	return blocks > 1 ? blocks : -EFSCORRUPTED;
}

/*
 * Return 1 with the requested page unlocked on a successful compressed read,
 * 0 with it locked for an ordinary cluster, or an error with it still locked.
 * The dnode remains locked until its storage reads finish, so relocation or
 * writeback cannot invalidate the block addresses between lookup and I/O.
 */
int f2fs_read_compressed_page(struct inode *inode, struct page *page)
{
	struct f2fs_inode_info *fi = F2FS_I(inode);
	struct f2fs_sb_info *sbi = F2FS_I_SB(inode);
	struct dnode_of_data dn;
	struct page *cpage = NULL;
	struct compress_data *cbuf = NULL;
	void *rbuf = NULL, *workspace = NULL, *addr;
	pgoff_t start = page->index & ~(pgoff_t)(fi->i_cluster_size - 1);
	unsigned int nr_cpages = 0, i, clen, rlen;
	int ret;

	if (!f2fs_is_compress_backend_ready(inode))
		return -EOPNOTSUPP;

	set_new_dnode(&dn, inode, NULL, NULL, 0);
	ret = f2fs_get_dnode_of_data(&dn, start, LOOKUP_NODE);
	if (ret)
		return ret == -ENOENT ? 0 : ret;
	ret = compressed_cluster_blocks(&dn);
	if (ret <= 0)
		goto out;
	nr_cpages = ret - 1;

	rlen = fi->i_cluster_size * PAGE_SIZE;
	cbuf = f2fs_kvmalloc(sbi, nr_cpages * PAGE_SIZE, GFP_NOFS);
	rbuf = f2fs_kvmalloc(sbi, rlen, GFP_NOFS);
	cpage = alloc_page(GFP_NOFS);
	if (!cbuf || !rbuf || !cpage) {
		ret = -ENOMEM;
		goto out;
	}

	cpage->mapping = inode->i_mapping;
	for (i = 0; i < nr_cpages; i++) {
		block_t blkaddr = datablock_addr(inode, dn.node_page,
						dn.ofs_in_node + i + 1);

		cpage->index = start + i + 1;
		ClearPageUptodate(cpage);
		lock_page(cpage);
		ret = f2fs_submit_page_read(inode, cpage, blkaddr);
		if (ret) {
			unlock_page(cpage);
			goto out;
		}
		wait_on_page_locked(cpage);
		if (!PageUptodate(cpage)) {
			ret = -EIO;
			goto out;
		}
		addr = kmap(cpage);
		memcpy((char *)cbuf + i * PAGE_SIZE, addr, PAGE_SIZE);
		kunmap(cpage);
	}

	clen = le32_to_cpu(cbuf->clen);
	if (!clen || clen > nr_cpages * PAGE_SIZE - sizeof(*cbuf)) {
		ret = -EFSCORRUPTED;
		goto out;
	}
	switch (fi->i_compress_algorithm) {
#ifdef CONFIG_F2FS_FS_LZ4
	case COMPRESS_LZ4:
		ret = LZ4_decompress_safe(cbuf->cdata, rbuf, clen, rlen);
		break;
#endif
#ifdef CONFIG_F2FS_FS_ZSTD
	case COMPRESS_ZSTD: {
		ZSTD_DCtx *ctx;
		size_t size = ZSTD_DCtxWorkspaceBound();
		size_t decoded;

		workspace = f2fs_kvmalloc(sbi, size, GFP_NOFS);
		if (!workspace) {
			ret = -ENOMEM;
			goto out;
		}
		ctx = ZSTD_initDCtx(workspace, size);
		if (!ctx) {
			ret = -ENOMEM;
			goto out;
		}
		decoded = ZSTD_decompressDCtx(ctx, rbuf, rlen, cbuf->cdata, clen);
		ret = ZSTD_isError(decoded) || decoded != rlen ?
			-EFSCORRUPTED : rlen;
		break;
	}
#endif
	default:
		ret = -EOPNOTSUPP;
		goto out;
	}
	if (ret != rlen) {
		ret = -EFSCORRUPTED;
		goto out;
	}

	addr = kmap_atomic(page);
	memcpy(addr, (char *)rbuf + (page->index - start) * PAGE_SIZE,
		PAGE_SIZE);
	kunmap_atomic(addr);
	if (page->index == (i_size_read(inode) >> PAGE_SHIFT))
		zero_user_segment(page, offset_in_page(i_size_read(inode)),
				  PAGE_SIZE);
	SetPageUptodate(page);
	ret = 1;
out:
	if (cpage) {
		cpage->mapping = NULL;
		put_page(cpage);
	}
	kvfree(cbuf);
	kvfree(rbuf);
	kvfree(workspace);
	f2fs_put_dnode(&dn);
	if (ret == 1)
		unlock_page(page);
	return ret;
}

bool f2fs_is_compressed_page(struct page *page)
{
	/* IO tracing stores a PID in ordinary F2FS pages' private field. */
	if (!PagePrivate2(page) || !PagePrivate(page) || !page_private(page) ||
			IS_ATOMIC_WRITTEN_PAGE(page) || IS_DUMMY_WRITTEN_PAGE(page))
		return false;
	return ((struct compress_io_ctx *)page_private(page))->magic ==
		F2FS_COMPRESSED_PAGE_MAGIC;
}

struct page *f2fs_compress_control_page(struct page *page)
{
	return ((struct compress_io_ctx *)page_private(page))->rpages[0];
}

static void put_compressed_page(struct page *page)
{
	if (!page)
		return;
	/* Unsubmitted software-encryption bounce pages also own a crypto ctx. */
	if (!page->mapping && PagePrivate(page))
		fscrypt_pullback_bio_page(&page, true);
	ClearPagePrivate2(page);
	set_page_private(page, 0);
	ClearPagePrivate(page);
	page->mapping = NULL;
	unlock_page(page);
	put_page(page);
}

int f2fs_init_compress_ctx(struct compress_ctx *cc)
{
	if (!cc->rpages)
		cc->rpages = kcalloc(cc->cluster_size, sizeof(struct page *),
				    GFP_NOFS);
	return cc->rpages ? 0 : -ENOMEM;
}

void f2fs_destroy_compress_ctx(struct compress_ctx *cc)
{
	kfree(cc->rpages);
	cc->rpages = NULL;
	cc->nr_rpages = 0;
	cc->nr_cpages = 0;
	cc->cluster_idx = NULL_CLUSTER;
}

bool f2fs_cluster_is_empty(struct compress_ctx *cc)
{
	return !cc->nr_rpages;
}

bool f2fs_cluster_can_merge_page(struct compress_ctx *cc, pgoff_t index)
{
	return !cc->nr_rpages ||
		cc->cluster_idx == index >> cc->log_cluster_size;
}

void f2fs_compress_ctx_add_page(struct compress_ctx *cc, struct page *page)
{
	unsigned int ofs = page->index & (cc->cluster_size - 1);

	f2fs_bug_on(F2FS_I_SB(cc->inode), cc->rpages[ofs]);
	cc->rpages[ofs] = page;
	cc->nr_rpages++;
	cc->cluster_idx = page->index >> cc->log_cluster_size;
}

/* Includes the marker; excludes reserved blocks, as in upstream F2FS. */
int f2fs_is_compressed_cluster(struct inode *inode, pgoff_t index)
{
	struct f2fs_inode_info *fi = F2FS_I(inode);
	struct dnode_of_data dn;
	int ret;

	index &= ~(pgoff_t)(fi->i_cluster_size - 1);
	set_new_dnode(&dn, inode, NULL, NULL, 0);
	ret = f2fs_get_dnode_of_data(&dn, index, LOOKUP_NODE);
	if (ret)
		return ret == -ENOENT ? 0 : ret;
	ret = compressed_cluster_blocks(&dn);
	f2fs_put_dnode(&dn);
	return ret;
}

static void put_raw_pages(struct compress_ctx *cc, bool unlock)
{
	unsigned int i;

	for (i = 0; i < cc->cluster_size; i++) {
		if (cc->rpages[i])
			f2fs_put_page(cc->rpages[i], unlock);
	}
}

/* Acquire a complete cluster in increasing index order before modifying it. */
int f2fs_prepare_compress_overwrite(struct inode *inode, struct page **pagep,
				 pgoff_t index, void **fsdata)
{
	struct f2fs_inode_info *fi = F2FS_I(inode);
	struct compress_ctx cc = {
		.inode = inode,
		.cluster_size = fi->i_cluster_size,
		.log_cluster_size = fi->i_log_cluster_size,
	};
	pgoff_t start = index & ~(pgoff_t)(cc.cluster_size - 1);
	unsigned int i;
	int ret;

retry:
	ret = f2fs_is_compressed_cluster(inode, start);
	if (ret <= 0)
		return ret;
	ret = f2fs_init_compress_ctx(&cc);
	if (ret)
		return ret;

	for (i = 0; i < cc.cluster_size; i++) {
		struct page *page = f2fs_pagecache_get_page(inode->i_mapping,
				start + i, FGP_LOCK | FGP_WRITE | FGP_CREAT, GFP_NOFS);

		if (!page) {
			ret = -ENOMEM;
			goto out;
		}
		cc.rpages[i] = page;
		f2fs_wait_on_page_writeback(page, DATA, true, true);
		if (PageUptodate(page))
			continue;
		/* The reader unlocks the requested page on success. */
		ret = f2fs_read_compressed_page(inode, page);
		if (ret == 1) {
			lock_page(page);
			if (page->mapping == inode->i_mapping && PageUptodate(page))
				continue;
			ret = 0;
		}
		goto out;
	}
	/* A competing writeback can turn the cluster into ordinary pages. */
	ret = f2fs_is_compressed_cluster(inode, start);
	if (ret <= 0)
		goto out;
	*pagep = cc.rpages[index - start];
	*fsdata = cc.rpages;
	return cc.cluster_size;
out:
	put_raw_pages(&cc, true);
	f2fs_destroy_compress_ctx(&cc);
	if (!ret)
		goto retry;
	return ret;
}

bool f2fs_compress_write_end(struct inode *inode, void *fsdata,
			   pgoff_t index, unsigned int copied)
{
	struct compress_ctx cc = {
		.inode = inode,
		.cluster_size = F2FS_I(inode)->i_cluster_size,
		.rpages = fsdata,
	};
	bool first = index == cc.rpages[0]->index;
	unsigned int i;

	if (copied) {
		for (i = 0; i < cc.cluster_size; i++)
			set_page_dirty(cc.rpages[i]);
	}
	put_raw_pages(&cc, true);
	f2fs_destroy_compress_ctx(&cc);
	return first;
}

int f2fs_truncate_partial_cluster(struct inode *inode, u64 from)
{
	unsigned int cluster_size = F2FS_I(inode)->i_cluster_size;
	pgoff_t start = (from >> PAGE_SHIFT) & ~(pgoff_t)(cluster_size - 1);
	struct page *page;
	struct page **rpages;
	void *fsdata = NULL;
	unsigned int i;
	int ret;

	ret = f2fs_prepare_compress_overwrite(inode, &page, start, &fsdata);
	if (ret <= 0)
		return ret;
	rpages = fsdata;
	for (i = 0; i < cluster_size; i++) {
		loff_t pos = page_offset(rpages[i]);

		if (from <= pos)
			zero_user_segment(rpages[i], 0, PAGE_SIZE);
		else if (from < pos + PAGE_SIZE)
			zero_user_segment(rpages[i], from - pos, PAGE_SIZE);
	}
	f2fs_compress_write_end(inode, fsdata, start, 1);
	return 1;
}

static int compress_pages(struct compress_ctx *cc)
{
	struct f2fs_sb_info *sbi = F2FS_I_SB(cc->inode);
	unsigned int rlen = cc->cluster_size * PAGE_SIZE;
	unsigned int capacity = rlen - PAGE_SIZE;
	struct compress_data *cbuf;
	void *rbuf, *workspace = NULL;
	unsigned int i;
	int ret = -ENOMEM, len;
	loff_t isize = i_size_read(cc->inode);

	rbuf = f2fs_kvmalloc(sbi, rlen, GFP_NOFS);
	cbuf = f2fs_kvzalloc(sbi, capacity, GFP_NOFS);
	if (!rbuf || !cbuf)
		goto out;
	for (i = 0; i < cc->cluster_size; i++) {
		struct page *page = cc->rpages[i];
		void *addr = kmap_atomic(page);
		unsigned int bytes = clamp_t(loff_t, isize - page_offset(page),
					     0, PAGE_SIZE);

		memcpy((char *)rbuf + i * PAGE_SIZE, addr, bytes);
		memset((char *)rbuf + i * PAGE_SIZE + bytes, 0, PAGE_SIZE - bytes);
		kunmap_atomic(addr);
	}
	switch (F2FS_I(cc->inode)->i_compress_algorithm) {
#ifdef CONFIG_F2FS_FS_LZ4
	case COMPRESS_LZ4:
		workspace = f2fs_kvmalloc(sbi, LZ4_MEM_COMPRESS, GFP_NOFS);
		if (!workspace)
			goto out;
		len = LZ4_compress_default(rbuf, cbuf->cdata, rlen,
					 capacity - sizeof(*cbuf), workspace);
		break;
#endif
#ifdef CONFIG_F2FS_FS_ZSTD
	case COMPRESS_ZSTD: {
		/* Upstream F2FS uses level 1; reuse this tree's bounded API. */
		ZSTD_parameters params = ZSTD_getParams(1, rlen, 0);
		size_t size = ZSTD_CCtxWorkspaceBound(params.cParams);
		size_t encoded;
		ZSTD_CCtx *ctx;

		workspace = f2fs_kvmalloc(sbi, size, GFP_NOFS);
		if (!workspace)
			goto out;
		ctx = ZSTD_initCCtx(workspace, size);
		if (!ctx)
			goto out;
		encoded = ZSTD_compressCCtx(ctx, cbuf->cdata,
			capacity - sizeof(*cbuf), rbuf, rlen, params);
		if (ZSTD_isError(encoded)) {
			ret = ZSTD_getErrorCode(encoded) == ZSTD_error_dstSize_tooSmall ?
				-EAGAIN : -EIO;
			goto out;
		}
		len = encoded;
		break;
	}
#endif
	default:
		ret = -EOPNOTSUPP;
		goto out;
	}
	if (!len) {
		ret = -EAGAIN;
		goto out;
	}
	cbuf->clen = cpu_to_le32(len);
	cc->nr_cpages = DIV_ROUND_UP(len + sizeof(*cbuf), PAGE_SIZE);
	cc->cpages = kcalloc(cc->nr_cpages, sizeof(struct page *), GFP_NOFS);
	if (!cc->cpages)
		goto out;
	for (i = 0; i < cc->nr_cpages; i++) {
		void *addr;

		cc->cpages[i] = alloc_page(GFP_NOFS);
		if (!cc->cpages[i])
			goto out;
		lock_page(cc->cpages[i]);
		addr = kmap_atomic(cc->cpages[i]);
		/* The full output buffer is zeroed, including its disk padding. */
		memcpy(addr, (char *)cbuf + i * PAGE_SIZE, PAGE_SIZE);
		kunmap_atomic(addr);
	}
	ret = 0;
out:
	kvfree(workspace);
	kvfree(cbuf);
	kvfree(rbuf);
	return ret;
}

static void free_compressed_pages(struct compress_ctx *cc)
{
	unsigned int i;

	if (!cc->cpages)
		return;
	for (i = 0; i < cc->nr_cpages; i++)
		put_compressed_page(cc->cpages[i]);
	kfree(cc->cpages);
	cc->cpages = NULL;
	cc->nr_cpages = 0;
}

/* Upstream cluster writeback, adapted to the 4.9 bio completion interface. */
static int write_compressed_pages(struct compress_ctx *cc, int *submitted,
			struct writeback_control *wbc, enum iostat_type io_type)
{
	struct inode *inode = cc->inode;
	struct f2fs_sb_info *sbi = F2FS_I_SB(inode);
	struct f2fs_io_info fio = {
		.sbi = sbi, .ino = inode->i_ino, .type = DATA,
		.op = REQ_OP_WRITE, .op_flags = wbc_to_write_flags(wbc),
		.io_type = io_type, .io_wbc = wbc,
	};
	struct dnode_of_data dn;
	struct node_info ni;
	struct compress_io_ctx *cic;
	bool software_encrypted = f2fs_encrypted_file(inode) &&
				 !fscrypt_using_hardware_encryption(inode);
	unsigned int i;
	int ret = -EAGAIN;

	if (f2fs_cp_error(sbi) || !f2fs_trylock_op(sbi))
		return -EAGAIN;
	set_new_dnode(&dn, inode, NULL, NULL, 0);
	ret = f2fs_get_dnode_of_data(&dn,
			cc->cluster_idx << cc->log_cluster_size, LOOKUP_NODE);
	if (ret)
		goto unlock;
	for (i = 0; i < cc->cluster_size; i++) {
		if (datablock_addr(inode, dn.node_page, dn.ofs_in_node + i) ==
				NULL_ADDR)
			goto put_dnode;
	}
	ret = f2fs_get_node_info(sbi, dn.nid, &ni);
	if (ret)
		goto put_dnode;
	fio.version = ni.version;
	cic = kzalloc(sizeof(*cic), GFP_NOFS);
	if (!cic)
		goto put_dnode;
	cic->rpages = kmemdup(cc->rpages,
			cc->cluster_size * sizeof(struct page *), GFP_NOFS);
	if (!cic->rpages) {
		kfree(cic);
		goto put_dnode;
	}
	cic->magic = F2FS_COMPRESSED_PAGE_MAGIC;
	cic->inode = inode;
	cic->nr_rpages = cc->cluster_size;
	atomic_set(&cic->pending_pages, cc->nr_cpages);
	for (i = 0; i < cc->nr_cpages; i++) {
		struct page *page = cc->cpages[i];

		page->mapping = inode->i_mapping;
		page->index = cc->rpages[i + 1]->index;
		SetPagePrivate(page);
		set_page_private(page, (unsigned long)cic);
		SetPagePrivate2(page);
		fio.page = cc->rpages[i + 1];
		fio.compressed_page = page;
		fio.old_blkaddr = datablock_addr(inode, dn.node_page,
						dn.ofs_in_node + i + 1);
		/* GC copies storage bytes, so wait before replacing that slot. */
		f2fs_wait_on_block_writeback(inode, fio.old_blkaddr);
		ret = f2fs_encrypt_one_page(&fio);
		if (ret)
			goto destroy_crypt;
		if (software_encrypted)
			cc->cpages[i] = fio.encrypted_page;
	}
	fio.encrypted_page = NULL;
	fio.compressed_page = NULL;
	for (i = 0; i < cc->cluster_size; i++)
		set_page_writeback(cc->rpages[i]);

	for (i = 0; i < cc->cluster_size; i++, dn.ofs_in_node++) {
		block_t addr = datablock_addr(inode, dn.node_page, dn.ofs_in_node);

		/* Do not dereference cic: the last I/O may already have freed it. */
		fio.page = cc->rpages[i];
		fio.old_blkaddr = addr;
		if (!i) {
			if (addr == COMPRESS_ADDR)
				fio.compr_blocks++;
			if (__is_valid_data_blkaddr(addr))
				f2fs_invalidate_blocks(sbi, addr);
			f2fs_update_data_blkaddr(&dn, COMPRESS_ADDR);
		} else {
			if (fio.compr_blocks && __is_valid_data_blkaddr(addr))
				fio.compr_blocks++;
			if (i > cc->nr_cpages) {
				if (__is_valid_data_blkaddr(addr))
					f2fs_invalidate_blocks(sbi, addr);
				f2fs_update_data_blkaddr(&dn, NEW_ADDR);
			} else {
				if (software_encrypted)
					fio.encrypted_page = cc->cpages[i - 1];
				else
					fio.compressed_page = cc->cpages[i - 1];
				cc->cpages[i - 1] = NULL;
				f2fs_outplace_write_data(&dn, &fio);
				(*submitted)++;
			}
		}
		inode_dec_dirty_pages(inode);
		unlock_page(fio.page);
	}
	if (fio.compr_blocks)
		f2fs_i_compr_blocks_update(inode, fio.compr_blocks - 1, false);
	f2fs_i_compr_blocks_update(inode, cc->nr_cpages, true);
	set_inode_flag(inode, FI_APPEND_WRITE);
	if (!cc->cluster_idx)
		set_inode_flag(inode, FI_FIRST_BLOCK_WRITTEN);
	f2fs_put_dnode(&dn);
	f2fs_unlock_op(sbi);
	down_write(&F2FS_I(inode)->i_sem);
	F2FS_I(inode)->last_disk_size = max_t(loff_t,
			F2FS_I(inode)->last_disk_size,
			(cc->rpages[cc->cluster_size - 1]->index + 1) << PAGE_SHIFT);
	up_write(&F2FS_I(inode)->i_sem);
	return 0;
destroy_crypt:
	/* Nothing was submitted: release bounce pages before their shared ctx. */
	free_compressed_pages(cc);
	kfree(cic->rpages);
	kfree(cic);
	f2fs_put_dnode(&dn);
	f2fs_unlock_op(sbi);
	return ret;
put_dnode:
	f2fs_put_dnode(&dn);
unlock:
	f2fs_unlock_op(sbi);
	return -EAGAIN;
}

void f2fs_compress_write_end_io(struct bio *bio, struct page *page)
{
	struct compress_io_ctx *cic = (void *)page_private(page);
	unsigned int i;

	if (bio->bi_error)
		mapping_set_error(cic->inode->i_mapping, -EIO);
	put_compressed_page(page);
	dec_page_count(bio->bi_private, F2FS_WB_DATA);
	if (!atomic_dec_and_test(&cic->pending_pages))
		return;
	for (i = 0; i < cic->nr_rpages; i++) {
		clear_cold_data(cic->rpages[i]);
		end_page_writeback(cic->rpages[i]);
	}
	kfree(cic->rpages);
	kfree(cic);
}

static int write_raw_pages(struct compress_ctx *cc, int *submitted,
			struct writeback_control *wbc, enum iostat_type io_type)
{
	int blocks, i, ret = 0, written;

	blocks = f2fs_is_compressed_cluster(cc->inode,
				cc->cluster_idx << cc->log_cluster_size);
	/* Release every lock before a single-page write can enter balancing/GC. */
	for (i = 0; i < cc->cluster_size; i++) {
		if (cc->rpages[i]) {
			redirty_page_for_writepage(wbc, cc->rpages[i]);
			unlock_page(cc->rpages[i]);
		}
	}
	if (blocks < 0)
		return blocks;
	if (blocks && cc->nr_rpages != cc->cluster_size)
		return -EAGAIN;
	for (i = 0; i < cc->cluster_size; i++) {
		struct page *page = cc->rpages[i];

		if (!page)
			continue;
retry:
		lock_page(page);
		if (page->mapping != cc->inode->i_mapping || !PageDirty(page) ||
				!clear_page_dirty_for_io(page)) {
			unlock_page(page);
			continue;
		}
		written = 0;
		ret = f2fs_write_single_data_page(page, &written, NULL, NULL,
						wbc, io_type, blocks);
		*submitted += written;
		if (ret == AOP_WRITEPAGE_ACTIVATE) {
			unlock_page(page);
			ret = 0;
		} else if (ret == -EAGAIN) {
			cond_resched();
			congestion_wait(BLK_RW_ASYNC, HZ / 50);
			goto retry;
		} else if (ret) {
			break;
		}
	}
	return ret;
}

int f2fs_write_multi_pages(struct compress_ctx *cc, int *submitted,
			 struct writeback_control *wbc, enum iostat_type io_type)
{
	int ret = -EAGAIN;
	unsigned int i;
	pgoff_t last = (i_size_read(cc->inode) + PAGE_SIZE - 1) >> PAGE_SHIFT;
	bool full = cc->nr_rpages == cc->cluster_size;

	*submitted = 0;
	if (full) {
		for (i = 0; i < cc->cluster_size; i++) {
			if (cc->rpages[i]->index >= last)
				full = false;
		}
	}
	if (full && !f2fs_cp_error(F2FS_I_SB(cc->inode))) {
		ret = compress_pages(cc);
		if (!ret)
			ret = write_compressed_pages(cc, submitted, wbc, io_type);
		free_compressed_pages(cc);
		if (!ret)
			goto out;
		if (ret != -EAGAIN) {
			for (i = 0; i < cc->cluster_size; i++) {
				redirty_page_for_writepage(wbc, cc->rpages[i]);
				unlock_page(cc->rpages[i]);
			}
			goto out;
		}
	}
	ret = write_raw_pages(cc, submitted, wbc, io_type);
out:
	put_raw_pages(cc, false);
	f2fs_destroy_compress_ctx(cc);
	return ret;
}
