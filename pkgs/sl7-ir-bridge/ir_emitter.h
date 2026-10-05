/* SPDX-License-Identifier: MIT */
#ifndef IR_EMITTER_H
#define IR_EMITTER_H

#include "ir_camss.h"

/* IR emitter hook points. See ir_emitter.c.
 *
 * ir_emitter_configure() is called once at start with the value of IR_EMITTER
 * ("off" when unset). It returns 1 if the emitter path is active, which in
 * this package version it never is. */
int ir_emitter_configure(const char *setting);
/* Called after the links and formats are set, immediately before STREAMON.
 * Returns 0 on success. A failure is logged and the session runs unlit. */
int ir_emitter_pre_stream(struct ir_camss *c);
/* Called after STREAMOFF, and on every error path after pre_stream ran. */
void ir_emitter_post_stream(struct ir_camss *c);

#endif
