/* SPDX-License-Identifier: MIT */
#include "ir_repack.h"

#include <string.h>

void ir_repack_grey(uint8_t *dst, const uint8_t *src, unsigned w, unsigned h,
		    unsigned stride)
{
	unsigned y;

	if (stride == w) {
		memcpy(dst, src, (size_t)w * h);
		return;
	}
	for (y = 0; y < h; y++)
		memcpy(dst + (size_t)y * w, src + (size_t)y * stride, w);
}

double ir_mean_grey(const uint8_t *src, unsigned w, unsigned h, unsigned stride)
{
	uint64_t sum = 0;
	unsigned x, y;

	if (!w || !h)
		return 0.0;
	for (y = 0; y < h; y++) {
		const uint8_t *row = src + (size_t)y * stride;

		for (x = 0; x < w; x++)
			sum += row[x];
	}
	return (double)sum / ((double)w * h);
}

int ir_frame_complete(size_t bytesused, unsigned w, unsigned h, unsigned stride)
{
	if (!w || !h || stride < w)
		return 0;
	return bytesused >= (size_t)stride * (h - 1) + w;
}
