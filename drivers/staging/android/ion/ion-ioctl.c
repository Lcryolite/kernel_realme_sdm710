/*
 *
 * Copyright (C) 2011 Google, Inc.
 *
 * This software is licensed under the terms of the GNU General Public
 * License version 2, as published by the Free Software Foundation, and
 * may be copied, distributed, and modified under those terms.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 */

#include <linux/kernel.h>
#include <linux/compat.h>
#include <linux/dma-buf.h>
#include <linux/file.h>
#include <linux/fs.h>
#include <linux/idr.h>
#include <linux/mutex.h>
#include <linux/slab.h>
#include <linux/uaccess.h>

#include "ion.h"
#include "ion_system_secure_heap.h"

struct ion_legacy_client {
	/* Serializes the per-file dma-buf handle namespace. */
	struct mutex lock;
	struct idr handles;
};

int ion_legacy_open(struct inode *inode, struct file *filp)
{
	struct ion_legacy_client *client;

	client = kzalloc(sizeof(*client), GFP_KERNEL);
	if (!client)
		return -ENOMEM;

	mutex_init(&client->lock);
	idr_init(&client->handles);
	filp->private_data = client;
	return 0;
}

int ion_legacy_release(struct inode *inode, struct file *filp)
{
	struct ion_legacy_client *client = filp->private_data;
	struct dma_buf *dmabuf;
	int id;

	if (!client)
		return 0;

	idr_for_each_entry(&client->handles, dmabuf, id)
		dma_buf_put(dmabuf);
	idr_destroy(&client->handles);
	kfree(client);
	return 0;
}

static int ion_legacy_add_handle(struct ion_legacy_client *client,
				 struct dma_buf *dmabuf)
{
	int handle;

	mutex_lock(&client->lock);
	handle = idr_alloc(&client->handles, dmabuf, 1, 0, GFP_KERNEL);
	mutex_unlock(&client->lock);
	return handle;
}

static struct dma_buf *ion_legacy_get_handle(struct ion_legacy_client *client,
					     int handle)
{
	struct dma_buf *dmabuf;

	mutex_lock(&client->lock);
	dmabuf = idr_find(&client->handles, handle);
	if (dmabuf)
		get_dma_buf(dmabuf);
	mutex_unlock(&client->lock);
	return dmabuf;
}

static int ion_legacy_alloc(struct ion_legacy_client *client,
			    struct ion_allocation_data *allocation)
{
	struct dma_buf *dmabuf;
	int handle;

	dmabuf = ion_alloc_dmabuf(allocation->len, allocation->heap_id_mask,
				  allocation->flags);
	if (IS_ERR(dmabuf))
		return PTR_ERR(dmabuf);

	handle = ion_legacy_add_handle(client, dmabuf);
	if (handle < 0) {
		dma_buf_put(dmabuf);
		return handle;
	}

	allocation->handle = handle;
	return 0;
}

static int ion_legacy_free(struct ion_legacy_client *client, int handle)
{
	struct dma_buf *dmabuf;

	mutex_lock(&client->lock);
	dmabuf = idr_remove(&client->handles, handle);
	mutex_unlock(&client->lock);
	if (!dmabuf)
		return -EINVAL;

	dma_buf_put(dmabuf);
	return 0;
}

static int ion_legacy_share(struct ion_legacy_client *client,
			    struct ion_fd_data *data)
{
	struct dma_buf *dmabuf;
	int fd;

	dmabuf = ion_legacy_get_handle(client, data->handle);
	if (!dmabuf)
		return -EINVAL;

	fd = dma_buf_fd(dmabuf, O_CLOEXEC);
	if (fd < 0) {
		dma_buf_put(dmabuf);
		return fd;
	}

	data->fd = fd;
	return 0;
}

static int ion_legacy_import(struct ion_legacy_client *client,
			     struct ion_fd_data *data)
{
	struct dma_buf *dmabuf;
	int handle;

	dmabuf = dma_buf_get(data->fd);
	if (IS_ERR(dmabuf))
		return PTR_ERR(dmabuf);

	handle = ion_legacy_add_handle(client, dmabuf);
	if (handle < 0) {
		dma_buf_put(dmabuf);
		return handle;
	}

	data->handle = handle;
	return 0;
}

static struct dma_buf *ion_legacy_get_buffer(struct ion_legacy_client *client,
					     int handle, int fd)
{
	struct dma_buf *dmabuf;

	if (handle > 0) {
		dmabuf = ion_legacy_get_handle(client, handle);
		if (dmabuf)
			return dmabuf;
	}

	if (fd < 0)
		return ERR_PTR(-EINVAL);
	return dma_buf_get(fd);
}

static int ion_legacy_sync(struct ion_legacy_client *client,
			   struct ion_fd_data *data)
{
	struct dma_buf *dmabuf;
	int ret;

	dmabuf = ion_legacy_get_buffer(client, data->handle, data->fd);
	if (IS_ERR(dmabuf))
		return PTR_ERR(dmabuf);

	ret = dma_buf_begin_cpu_access(dmabuf, DMA_BIDIRECTIONAL);
	if (!ret)
		ret = dma_buf_end_cpu_access(dmabuf, DMA_BIDIRECTIONAL);
	dma_buf_put(dmabuf);
	return ret;
}

#ifdef CONFIG_COMPAT
struct compat_ion_flush_data {
	compat_int_t handle;
	compat_int_t fd;
	compat_uptr_t vaddr;
	compat_uint_t offset;
	compat_uint_t length;
};
#endif

static int ion_legacy_cache(struct ion_legacy_client *client,
			    struct ion_custom_data *custom, bool compat)
{
	struct ion_flush_data flush;
	struct dma_buf *dmabuf;
	unsigned int offset, length;
	int ret = 0;

	memset(&flush, 0, sizeof(flush));
#ifdef CONFIG_COMPAT
	if (compat) {
		struct compat_ion_flush_data flush32;

		if (copy_from_user(&flush32, compat_ptr(custom->arg),
				   sizeof(flush32)))
			return -EFAULT;
		flush.handle = flush32.handle;
		flush.fd = flush32.fd;
		flush.offset = flush32.offset;
		flush.length = flush32.length;
	} else {
		if (copy_from_user(&flush, (void __user *)custom->arg,
				   sizeof(flush)))
			return -EFAULT;
	}
#else
	if (copy_from_user(&flush, (void __user *)custom->arg, sizeof(flush)))
		return -EFAULT;
#endif

	if (_IOC_TYPE(custom->cmd) != ION_IOC_MSM_MAGIC ||
	    _IOC_NR(custom->cmd) > 2)
		return -ENOTTY;

	dmabuf = ion_legacy_get_buffer(client, flush.handle, flush.fd);
	if (IS_ERR(dmabuf))
		return PTR_ERR(dmabuf);

	offset = flush.offset;
	length = flush.length;
	if (offset > dmabuf->size || length > dmabuf->size - offset) {
		ret = -EINVAL;
		goto out;
	}

	if (_IOC_NR(custom->cmd) == 0 || _IOC_NR(custom->cmd) == 2) {
		ret = length ?
			dma_buf_end_cpu_access_partial(dmabuf, DMA_BIDIRECTIONAL,
						       offset, length) :
			dma_buf_end_cpu_access(dmabuf, DMA_BIDIRECTIONAL);
	}
	if (!ret && (_IOC_NR(custom->cmd) == 1 ||
		     _IOC_NR(custom->cmd) == 2)) {
		ret = length ?
			dma_buf_begin_cpu_access_partial(dmabuf, DMA_BIDIRECTIONAL,
							 offset, length) :
			dma_buf_begin_cpu_access(dmabuf, DMA_BIDIRECTIONAL);
	}
out:
	dma_buf_put(dmabuf);
	return ret;
}

static int ion_legacy_resize(struct ion_prefetch_data *data, bool shrink)
{
	int ret;

	ret = ion_walk_heaps(data->heap_id,
			     (enum ion_heap_type)ION_HEAP_TYPE_SECURE_DMA,
			     (void *)data->len,
			     shrink ? ion_secure_cma_drain_pool :
			     ion_secure_cma_prefetch);
	if (ret)
		return ret;

	return ion_walk_heaps(data->heap_id,
			      (enum ion_heap_type)ION_HEAP_TYPE_SYSTEM_SECURE,
			      data,
			      shrink ? ion_system_secure_heap_drain_legacy :
			      ion_system_secure_heap_prefetch_legacy);
}

#ifdef CONFIG_COMPAT
static int ion_legacy_resize_compat(struct ion_prefetch_data_compat *data,
				    bool shrink)
{
	int ret;

	ret = ion_walk_heaps(data->heap_id,
			     (enum ion_heap_type)ION_HEAP_TYPE_SECURE_DMA,
			     (void *)(unsigned long)data->len,
			     shrink ? ion_secure_cma_drain_pool :
			     ion_secure_cma_prefetch);
	if (ret)
		return ret;

	return ion_walk_heaps(data->heap_id,
			      (enum ion_heap_type)ION_HEAP_TYPE_SYSTEM_SECURE,
			      data,
			      shrink ? ion_system_secure_heap_drain_compat :
			      ion_system_secure_heap_prefetch_compat);
}
#endif

static int ion_legacy_custom(struct ion_legacy_client *client,
			     struct ion_custom_data *custom, bool compat)
{
	if (_IOC_TYPE(custom->cmd) != ION_IOC_MSM_MAGIC)
		return -ENOTTY;

	switch (_IOC_NR(custom->cmd)) {
	case 0:
	case 1:
	case 2:
#ifdef CONFIG_COMPAT
		if (_IOC_SIZE(custom->cmd) !=
		    (compat ? sizeof(struct compat_ion_flush_data) :
		     sizeof(struct ion_flush_data)))
			return -ENOTTY;
#else
		if (_IOC_SIZE(custom->cmd) != sizeof(struct ion_flush_data))
			return -ENOTTY;
#endif
		return ion_legacy_cache(client, custom, compat);
	case 3:
	case 4:
#ifdef CONFIG_COMPAT
		if (compat) {
			struct ion_prefetch_data_compat data32;

			if (_IOC_SIZE(custom->cmd) != sizeof(data32))
				return -ENOTTY;
			if (copy_from_user(&data32,
					   (void __user *)custom->arg,
					   sizeof(data32)))
				return -EFAULT;
			return ion_legacy_resize_compat(&data32,
					_IOC_NR(custom->cmd) == 4);
		}
#endif
		{
			struct ion_prefetch_data data;

			if (_IOC_SIZE(custom->cmd) != sizeof(data))
				return -ENOTTY;
			if (copy_from_user(&data, (void __user *)custom->arg,
					   sizeof(data)))
				return -EFAULT;
			return ion_legacy_resize(&data, _IOC_NR(custom->cmd) == 4);
		}
	default:
		return -ENOTTY;
	}
}

union ion_ioctl_arg {
	struct ion_allocation_data allocation;
	struct ion_allocation_data_v2 allocation_v2;
	struct ion_fd_data fd;
	struct ion_handle_data handle;
	struct ion_custom_data custom;
	struct ion_heap_query query;
	struct ion_prefetch_data prefetch_data;
	struct ion_prefetch_data_v2 prefetch_data_v2;
};

static int validate_ioctl_arg(unsigned int cmd, union ion_ioctl_arg *arg)
{
	int ret = 0;

	switch (cmd) {
	case ION_IOC_HEAP_QUERY:
		ret = arg->query.reserved0 != 0;
		ret |= arg->query.reserved1 != 0;
		ret |= arg->query.reserved2 != 0;
		break;
	default:
		break;
	}

	return ret ? -EINVAL : 0;
}

/* fix up the cases where the ioctl direction bits are incorrect */
static unsigned int ion_ioctl_dir(unsigned int cmd)
{
	switch (cmd) {
	default:
		return _IOC_DIR(cmd);
	}
}

long ion_ioctl(struct file *filp, unsigned int cmd, unsigned long arg)
{
	struct ion_legacy_client *client = filp->private_data;
	int ret = 0;
	unsigned int dir;
	union ion_ioctl_arg data;

	dir = ion_ioctl_dir(cmd);

	if (_IOC_SIZE(cmd) > sizeof(data))
		return -EINVAL;

	/*
	 * The copy_from_user is unconditional here for both read and write
	 * to do the validate. If there is no write for the ioctl, the
	 * buffer is cleared
	 */
	if (copy_from_user(&data, (void __user *)arg, _IOC_SIZE(cmd)))
		return -EFAULT;

	ret = validate_ioctl_arg(cmd, &data);
	if (ret) {
		pr_warn_once("%s: ioctl validate failed\n", __func__);
		return ret;
	}

	if (!(dir & _IOC_WRITE))
		memset(&data, 0, sizeof(data));

	switch (cmd) {
	case ION_IOC_ALLOC:
		ret = ion_legacy_alloc(client, &data.allocation);
		break;
	case ION_IOC_FREE:
		ret = ion_legacy_free(client, data.handle.handle);
		break;
	case ION_IOC_MAP:
	case ION_IOC_SHARE:
		ret = ion_legacy_share(client, &data.fd);
		break;
	case ION_IOC_IMPORT:
		ret = ion_legacy_import(client, &data.fd);
		break;
	case ION_IOC_SYNC:
		ret = ion_legacy_sync(client, &data.fd);
		break;
	case ION_IOC_CUSTOM:
		ret = ion_legacy_custom(client, &data.custom, false);
		break;
	case ION_IOC_ALLOC_V2:
	{
		int fd;

		fd = ion_alloc_fd(data.allocation_v2.len,
				  data.allocation_v2.heap_id_mask,
				  data.allocation_v2.flags);
		if (fd < 0)
			return fd;

		data.allocation_v2.fd = fd;

		break;
	}
	case ION_IOC_HEAP_QUERY:
		ret = ion_query_heaps(&data.query);
		break;
	case ION_IOC_PREFETCH:
		ret = ion_legacy_resize(&data.prefetch_data, false);
		break;
	case ION_IOC_DRAIN:
		ret = ion_legacy_resize(&data.prefetch_data, true);
		break;
	case ION_IOC_PREFETCH_V2:
	{
		int ret;

		ret = ion_walk_heaps(data.prefetch_data_v2.heap_id,
				     (enum ion_heap_type)
				     ION_HEAP_TYPE_SYSTEM_SECURE,
				     (void *)&data.prefetch_data_v2,
				     ion_system_secure_heap_prefetch);
		if (ret)
			return ret;
		break;
	}
	case ION_IOC_DRAIN_V2:
	{
		int ret;

		ret = ion_walk_heaps(data.prefetch_data_v2.heap_id,
				     (enum ion_heap_type)
				     ION_HEAP_TYPE_SYSTEM_SECURE,
				     (void *)&data.prefetch_data_v2,
				     ion_system_secure_heap_drain);

		if (ret)
			return ret;
		break;
	}
	default:
		return -ENOTTY;
	}

	if (dir & _IOC_READ) {
		if (copy_to_user((void __user *)arg, &data, _IOC_SIZE(cmd)))
			return -EFAULT;
	}
	return ret;
}

#ifdef CONFIG_COMPAT
struct compat_ion_allocation_data {
	compat_size_t len;
	compat_size_t align;
	compat_uint_t heap_id_mask;
	compat_uint_t flags;
	compat_int_t handle;
};

struct compat_ion_custom_data {
	compat_uint_t cmd;
	compat_ulong_t arg;
};

#define COMPAT_ION_IOC_ALLOC _IOWR(ION_IOC_MAGIC, 0, \
				    struct compat_ion_allocation_data)
#define COMPAT_ION_IOC_CUSTOM _IOWR(ION_IOC_MAGIC, 6, \
				     struct compat_ion_custom_data)
#define COMPAT_ION_IOC_PREFETCH _IOWR(ION_IOC_MSM_MAGIC, 3, \
				       struct ion_prefetch_data_compat)
#define COMPAT_ION_IOC_DRAIN _IOWR(ION_IOC_MSM_MAGIC, 4, \
				    struct ion_prefetch_data_compat)

long ion_compat_ioctl(struct file *filp, unsigned int cmd, unsigned long arg)
{
	struct ion_legacy_client *client = filp->private_data;
	void __user *argp = compat_ptr(arg);

	switch (cmd) {
	case COMPAT_ION_IOC_ALLOC:
	{
		struct compat_ion_allocation_data allocation32;
		struct ion_allocation_data allocation;
		int ret;

		if (copy_from_user(&allocation32, argp, sizeof(allocation32)))
			return -EFAULT;
		memset(&allocation, 0, sizeof(allocation));
		allocation.len = allocation32.len;
		allocation.align = allocation32.align;
		allocation.heap_id_mask = allocation32.heap_id_mask;
		allocation.flags = allocation32.flags;
		ret = ion_legacy_alloc(client, &allocation);
		if (ret)
			return ret;
		allocation32.handle = allocation.handle;
		if (copy_to_user(argp, &allocation32, sizeof(allocation32))) {
			ion_legacy_free(client, allocation.handle);
			return -EFAULT;
		}
		return 0;
	}
	case COMPAT_ION_IOC_CUSTOM:
	{
		struct compat_ion_custom_data custom32;
		struct ion_custom_data custom;

		if (copy_from_user(&custom32, argp, sizeof(custom32)))
			return -EFAULT;
		custom.cmd = custom32.cmd;
		custom.arg = (unsigned long)compat_ptr(custom32.arg);
		return ion_legacy_custom(client, &custom, true);
	}
	case COMPAT_ION_IOC_PREFETCH:
	case COMPAT_ION_IOC_DRAIN:
	{
		struct ion_prefetch_data_compat data32;

		if (copy_from_user(&data32, argp, sizeof(data32)))
			return -EFAULT;
		return ion_legacy_resize_compat(&data32,
				cmd == COMPAT_ION_IOC_DRAIN);
	}
	default:
		return ion_ioctl(filp, cmd, (unsigned long)argp);
	}
}
#endif
