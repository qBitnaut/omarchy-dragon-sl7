/* SPDX-License-Identifier: MIT */
/* Unit tests for the frame repacking logic. Run with: make check */
#include "ir_repack.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int fails;

#define CHECK(c)                                                         \
	do {                                                             \
		if (!(c)) {                                              \
			fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__,    \
				__LINE__, #c);                           \
			fails++;                                         \
		}                                                        \
	} while (0)

/* pixel value that depends on position, never equal to the padding byte */
static uint8_t px(unsigned x, unsigned y)
{
	uint8_t v = (uint8_t)(x * 7 + y * 13 + 1);

	return v == 0xEE ? 0xEF : v;
}

static void test_stride(unsigned w, unsigned h, unsigned stride)
{
	uint8_t *src = malloc((size_t)stride * h);
	uint8_t *dst = malloc((size_t)w * h);
	unsigned x, y;
	int ok = 1;

	memset(src, 0xEE, (size_t)stride * h);
	for (y = 0; y < h; y++)
		for (x = 0; x < w; x++)
			src[(size_t)y * stride + x] = px(x, y);
	memset(dst, 0xAA, (size_t)w * h);
	ir_repack_grey(dst, src, w, h, stride);
	for (y = 0; y < h && ok; y++)
		for (x = 0; x < w; x++)
			if (dst[(size_t)y * w + x] != px(x, y)) {
				ok = 0;
				break;
			}
	CHECK(ok);
	CHECK(memchr(dst, 0xEE, (size_t)w * h) == NULL); /* no padding leaked */
	free(src);
	free(dst);
}

static void test_mean(void)
{
	uint8_t f[8 * 3];
	unsigned i;

	memset(f, 0xEE, sizeof(f)); /* padding must not count */
	for (i = 0; i < 3; i++)
		memset(f + i * 8, 10 * (i + 1), 5);
	CHECK(ir_mean_grey(f, 5, 3, 8) == 20.0);
	memset(f, 0, sizeof(f));
	CHECK(ir_mean_grey(f, 8, 3, 8) == 0.0);
	CHECK(ir_mean_grey(f, 0, 3, 8) == 0.0);
}

static void test_complete(void)
{
	/* 644x604 with stride 656: the last row needs only 644 bytes */
	size_t need = (size_t)656 * 603 + 644;

	CHECK(ir_frame_complete(need, 644, 604, 656));
	CHECK(ir_frame_complete(656 * 604, 644, 604, 656));
	CHECK(!ir_frame_complete(need - 1, 644, 604, 656));
	CHECK(!ir_frame_complete(0, 644, 604, 656));
	CHECK(!ir_frame_complete(1000000, 644, 604, 600)); /* stride < width */
	CHECK(!ir_frame_complete(1000000, 0, 604, 656));
}

int main(void)
{
	test_stride(644, 604, 656); /* the CAMSS RDI case */
	test_stride(644, 604, 644); /* already tight */
	test_stride(1, 1, 1);
	test_stride(3, 5, 64);
	test_mean();
	test_complete();
	if (fails) {
		fprintf(stderr, "%d check(s) failed\n", fails);
		return 1;
	}
	puts("test_repack: all checks passed");
	return 0;
}
