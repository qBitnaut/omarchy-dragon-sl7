/* SPDX-License-Identifier: MIT */
#ifndef IR_REPACK_H
#define IR_REPACK_H

#include <stddef.h>
#include <stdint.h>

/* Copy a GREY frame whose rows are <stride> bytes apart into a tight
 * w x h buffer (dst holds w*h bytes). Stride padding is dropped. */
void ir_repack_grey(uint8_t *dst, const uint8_t *src, unsigned w, unsigned h,
		    unsigned stride);

/* Mean pixel value of the w x h visible area (padding excluded). */
double ir_mean_grey(const uint8_t *src, unsigned w, unsigned h, unsigned stride);

/* 1 if <bytesused> covers every visible pixel of a w x h frame, else 0. */
int ir_frame_complete(size_t bytesused, unsigned w, unsigned h, unsigned stride);

#endif
