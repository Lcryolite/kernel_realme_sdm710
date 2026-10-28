/* SPDX-License-Identifier: GPL-2.0-or-later OR BSD-2-Clause */
/*
 * Minimal LZ4 definitions for the bounded decompressor.
 *
 * Derived from Linux v4.14 lib/lz4/lz4defs.h.
 * Copyright (C) 2011-2016, Yann Collet.
 * Changed for kernel usage by Sven Schmidt.
 */
#ifndef __LZ4DEFS_SAFE_H__
#define __LZ4DEFS_SAFE_H__

#include <asm/unaligned.h>
#include <linux/string.h>
#include <linux/types.h>

#define LZ4_FORCE_INLINE __always_inline

typedef uint8_t BYTE;
typedef uint32_t U32;
typedef uint64_t U64;

#if defined(CONFIG_64BIT)
#define LZ4_ARCH64 1
#else
#define LZ4_ARCH64 0
#endif

#define MINMATCH 4
#define WILDCOPYLENGTH 8
#define LASTLITERALS 5
#define MFLIMIT (WILDCOPYLENGTH + MINMATCH)
#define KB (1 << 10)
#define ML_BITS 4
#define ML_MASK ((1U << ML_BITS) - 1)
#define RUN_BITS (8 - ML_BITS)
#define RUN_MASK ((1U << RUN_BITS) - 1)

static LZ4_FORCE_INLINE void LZ4_write32(void *mem_ptr, U32 value)
{
	put_unaligned(value, (U32 *)mem_ptr);
}

static LZ4_FORCE_INLINE u16 LZ4_readLE16(const void *mem_ptr)
{
	return get_unaligned_le16(mem_ptr);
}

static LZ4_FORCE_INLINE void LZ4_copy8(void *dst, const void *src)
{
#if LZ4_ARCH64
	U64 value = get_unaligned((const U64 *)src);

	put_unaligned(value, (U64 *)dst);
#else
	U32 first = get_unaligned((const U32 *)src);
	U32 second = get_unaligned((const U32 *)src + 1);

	put_unaligned(first, (U32 *)dst);
	put_unaligned(second, (U32 *)dst + 1);
#endif
}

/* This may overwrite up to seven bytes beyond dst_end. */
static LZ4_FORCE_INLINE void LZ4_wildCopy(void *dst_ptr,
		const void *src_ptr, void *dst_end)
{
	BYTE *dst = dst_ptr;
	const BYTE *src = src_ptr;
	BYTE * const end = dst_end;

	do {
		LZ4_copy8(dst, src);
		dst += 8;
		src += 8;
	} while (dst < end);
}

enum lz4_dict_directive {
	noDict = 0,
	withPrefix64k,
	usingExtDict,
};

enum lz4_end_condition {
	endOnOutputSize = 0,
	endOnInputSize = 1,
};

enum lz4_early_end {
	full = 0,
	partial = 1,
};

#endif
