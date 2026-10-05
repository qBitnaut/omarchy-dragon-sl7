/* SPDX-License-Identifier: MIT */
#ifndef IR_SELFTEST_H
#define IR_SELFTEST_H

/* Stream <nframes> frames from the loopback node (<dev> or, when NULL, found
 * by its card name) and print fps and mean brightness. No images are saved.
 * Exit status: 0 ok, 1 failure, 3 frames received but all black. */
int ir_selftest(const char *dev, unsigned nframes);

#endif
