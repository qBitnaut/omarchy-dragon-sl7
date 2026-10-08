/* SPDX-License-Identifier: MIT */
#ifndef IR_EMITTER_H
#define IR_EMITTER_H

#include "ir_camss.h"

/* IR emitter control. See ir_emitter.c.
 *
 * ir_emitter_configure() is called once at start with the value of IR_EMITTER
 * ("on" when unset). It returns 1 if the emitter is used, 0 if it stays off. */
int ir_emitter_configure(const char *setting);
/* Called after the links and formats are set, immediately before STREAMON.
 * With the emitter on it sets Windows' sensor settings and led_mode=flash;
 * with it off it makes sure led_mode is none. Returns 0 on success (including
 * "no led_mode control on this kernel"); a failure is logged and the session
 * runs unlit. */
int ir_emitter_pre_stream(struct ir_camss *c);
/* Called BEFORE STREAMOFF (the emitter goes dark first), and on every error
 * path after pre_stream ran. Sets led_mode back to none. */
void ir_emitter_post_stream(struct ir_camss *c);

#endif
