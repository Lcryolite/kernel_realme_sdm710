/* SPDX-License-Identifier: GPL-2.0-or-later OR BSD-2-Clause */
/*
 * Bounded LZ4 decompression for Linux.
 *
 * Derived from Linux v4.14 lib/lz4/lz4_decompress.c.
 * Copyright (C) 2011-2016, Yann Collet.
 * Changed for kernel usage by Sven Schmidt.
 */
#include <linux/export.h>
#include <linux/kernel.h>
#include <linux/lz4.h>
#include <linux/module.h>

#include "lz4defs_safe.h"

static LZ4_FORCE_INLINE int lz4_decompress_generic(
		const char * const source, char * const dest, int input_size,
		int output_size, int end_on_input, int partial_decoding,
		int target_output_size, int dict, const BYTE * const low_prefix,
		const BYTE * const dict_start, const size_t dict_size)
{
	const BYTE *src = (const BYTE *)source;
	const BYTE * const input_end = src + input_size;
	BYTE *dst = (BYTE *)dest;
	BYTE * const output_end = dst + output_size;
	BYTE *copy;
	BYTE *output_exit = dst + target_output_size;
	const BYTE * const low_limit = low_prefix - dict_size;
	const BYTE * const dict_end = dict_start + dict_size;
	static const unsigned int dec32table[] = { 0, 1, 2, 1, 4, 4, 4, 4 };
	static const int dec64table[] = { 0, 0, 0, -1, 0, 1, 2, 3 };
	const int safe_decode = end_on_input == endOnInputSize;
	const int check_offset = safe_decode && dict_size < 64 * KB;

	if (partial_decoding && output_exit > output_end - MFLIMIT)
		output_exit = output_end - MFLIMIT;

	if (end_on_input && unlikely(output_size == 0))
		return input_size == 1 && *src == 0 ? 0 : -1;

	if (!end_on_input && unlikely(output_size == 0))
		return *src == 0 ? 1 : -1;

	while (1) {
		size_t length;
		const BYTE *match;
		size_t offset;
		unsigned int token = *src++;

		length = token >> ML_BITS;
		if (length == RUN_MASK) {
			unsigned int value;

			do {
				value = *src++;
				length += value;
			} while (likely(end_on_input ?
				 src < input_end - RUN_MASK : 1) && value == 255);

			if (safe_decode &&
			    unlikely((size_t)(dst + length) < (size_t)dst))
				goto output_error;
			if (safe_decode &&
			    unlikely((size_t)(src + length) < (size_t)src))
				goto output_error;
		}

		copy = dst + length;
		if ((end_on_input &&
		     (copy > (partial_decoding ? output_exit :
				       output_end - MFLIMIT) ||
		      src + length > input_end - (2 + 1 + LASTLITERALS))) ||
		    (!end_on_input && copy > output_end - WILDCOPYLENGTH)) {
			if (partial_decoding) {
				if (copy > output_end)
					goto output_error;
				if (end_on_input && src + length > input_end)
					goto output_error;
			} else {
				if (!end_on_input && copy != output_end)
					goto output_error;
				if (end_on_input &&
				    (src + length != input_end || copy > output_end))
					goto output_error;
			}

			memcpy(dst, src, length);
			src += length;
			dst += length;
			break;
		}

		LZ4_wildCopy(dst, src, copy);
		src += length;
		dst = copy;

		offset = LZ4_readLE16(src);
		src += 2;
		match = dst - offset;
		if (check_offset && unlikely(match < low_limit))
			goto output_error;

		LZ4_write32(dst, (U32)offset);

		length = token & ML_MASK;
		if (length == ML_MASK) {
			unsigned int value;

			do {
				value = *src++;
				if (end_on_input && src > input_end - LASTLITERALS)
					goto output_error;
				length += value;
			} while (value == 255);

			if (safe_decode &&
			    unlikely((size_t)(dst + length) < (size_t)dst))
				goto output_error;
		}

		length += MINMATCH;
		if (dict == usingExtDict && match < low_prefix) {
			if (unlikely(dst + length > output_end - LASTLITERALS))
				goto output_error;

			if (length <= (size_t)(low_prefix - match)) {
				memmove(dst, dict_end - (low_prefix - match), length);
				dst += length;
			} else {
				size_t copy_size = low_prefix - match;
				size_t rest_size = length - copy_size;

				memcpy(dst, dict_end - copy_size, copy_size);
				dst += copy_size;
				if (rest_size > (size_t)(dst - low_prefix)) {
					BYTE * const end = dst + rest_size;
					const BYTE *copy_from = low_prefix;

					while (dst < end)
						*dst++ = *copy_from++;
				} else {
					memcpy(dst, low_prefix, rest_size);
					dst += rest_size;
				}
			}
			continue;
		}

		copy = dst + length;
		if (unlikely(offset < 8)) {
			int dec64 = dec64table[offset];

			dst[0] = match[0];
			dst[1] = match[1];
			dst[2] = match[2];
			dst[3] = match[3];
			match += dec32table[offset];
			memcpy(dst + 4, match, 4);
			match -= dec64;
		} else {
			LZ4_copy8(dst, match);
			match += 8;
		}

		dst += 8;
		if (unlikely(copy > output_end - 12)) {
			BYTE * const copy_limit =
				output_end - (WILDCOPYLENGTH - 1);

			if (copy > output_end - LASTLITERALS)
				goto output_error;

			if (dst < copy_limit) {
				LZ4_wildCopy(dst, match, copy_limit);
				match += copy_limit - dst;
				dst = copy_limit;
			}

			while (dst < copy)
				*dst++ = *match++;
		} else {
			LZ4_copy8(dst, match);
			if (length > 16)
				LZ4_wildCopy(dst + 8, match + 8, copy);
		}

		dst = copy;
	}

	if (end_on_input)
		return (int)((char *)dst - dest);
	return (int)((const char *)src - source);

output_error:
	return -1;
}

int LZ4_decompress_safe(const char *source, char *dest, int compressed_size,
		int max_decompressed_size)
{
	return lz4_decompress_generic(source, dest, compressed_size,
		max_decompressed_size, endOnInputSize, full, 0, noDict,
		(BYTE *)dest, NULL, 0);
}
EXPORT_SYMBOL(LZ4_decompress_safe);

int LZ4_decompress_safe_partial(const char *source, char *dest,
		int compressed_size, int target_output_size,
		int max_decompressed_size)
{
	return lz4_decompress_generic(source, dest, compressed_size,
		max_decompressed_size, endOnInputSize, partial,
		target_output_size, noDict, (BYTE *)dest, NULL, 0);
}
EXPORT_SYMBOL(LZ4_decompress_safe_partial);

MODULE_LICENSE("Dual BSD/GPL");
MODULE_DESCRIPTION("Bounded LZ4 decompressor");
