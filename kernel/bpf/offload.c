// SPDX-License-Identifier: GPL-2.0
/*
 * RMX1901 has no net_device BPF offload ABI. Keep software BPF available and
 * reject only requests that explicitly target a hardware offload device.
 */
#include <linux/bpf.h>
#include <linux/bpf_verifier.h>
#include <linux/err.h>

const struct bpf_prog_ops bpf_offload_prog_ops = {
};

int bpf_prog_offload_init(struct bpf_prog *prog, union bpf_attr *attr)
{
	return -EOPNOTSUPP;
}

int bpf_prog_offload_verifier_prep(struct bpf_prog *prog)
{
	return -ENODEV;
}

int bpf_prog_offload_verify_insn(struct bpf_verifier_env *env, int insn_idx,
				 int prev_insn_idx)
{
	return -ENODEV;
}

int bpf_prog_offload_finalize(struct bpf_verifier_env *env)
{
	return -ENODEV;
}

void bpf_prog_offload_replace_insn(struct bpf_verifier_env *env, u32 off,
				   struct bpf_insn *insn)
{
}

void bpf_prog_offload_remove_insns(struct bpf_verifier_env *env, u32 off,
				   u32 cnt)
{
}

void bpf_prog_offload_destroy(struct bpf_prog *prog)
{
}

int bpf_prog_offload_compile(struct bpf_prog *prog)
{
	return -EOPNOTSUPP;
}

int bpf_prog_offload_info_fill(struct bpf_prog_info *info,
			       struct bpf_prog *prog)
{
	return 0;
}

int bpf_map_offload_info_fill(struct bpf_map_info *info, struct bpf_map *map)
{
	return 0;
}

struct bpf_map *bpf_map_offload_map_alloc(union bpf_attr *attr)
{
	return ERR_PTR(-EOPNOTSUPP);
}

void bpf_map_offload_map_free(struct bpf_map *map)
{
}

int bpf_map_offload_lookup_elem(struct bpf_map *map, void *key, void *value)
{
	return -EOPNOTSUPP;
}

int bpf_map_offload_update_elem(struct bpf_map *map, void *key, void *value,
				u64 flags)
{
	return -EOPNOTSUPP;
}

int bpf_map_offload_delete_elem(struct bpf_map *map, void *key)
{
	return -EOPNOTSUPP;
}

int bpf_map_offload_get_next_key(struct bpf_map *map, void *key,
				 void *next_key)
{
	return -EOPNOTSUPP;
}

bool bpf_offload_prog_map_match(struct bpf_prog *prog, struct bpf_map *map)
{
	return false;
}

struct bpf_offload_dev *
bpf_offload_dev_create(const struct bpf_prog_offload_ops *ops, void *priv)
{
	return ERR_PTR(-EOPNOTSUPP);
}

void bpf_offload_dev_destroy(struct bpf_offload_dev *offdev)
{
}

void *bpf_offload_dev_priv(struct bpf_offload_dev *offdev)
{
	return NULL;
}

int bpf_offload_dev_netdev_register(struct bpf_offload_dev *offdev,
				    struct net_device *netdev)
{
	return -EOPNOTSUPP;
}

void bpf_offload_dev_netdev_unregister(struct bpf_offload_dev *offdev,
				       struct net_device *netdev)
{
}

bool bpf_offload_dev_match(struct bpf_prog *prog, struct net_device *netdev)
{
	return false;
}
