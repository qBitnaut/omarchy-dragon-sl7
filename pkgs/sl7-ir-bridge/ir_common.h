/* SPDX-License-Identifier: MIT */
#ifndef IR_COMMON_H
#define IR_COMMON_H

#include <stddef.h>
#include <stdint.h>

/* The VD55G0 IR sensor mode used for face unlock: Y8 (GREY) 644x604, ~35 fps. */
#define IR_WIDTH 644
#define IR_HEIGHT 604
#define IR_FPS 35
#define IR_FRAME_SIZE ((size_t)IR_WIDTH * IR_HEIGHT)

/* v4l2loopback card label (module option card_label); the loopback node is
 * always looked up by this name, never by number. */
#define IR_LOOPBACK_CARD "SL7 IR Camera"

/* The timing Windows Hello programs on this sensor (EMITTER-PLAN E7, decoded
 * from the Windows sensor module file): manual exposure 100 lines and frame
 * length 1750 lines (line length 1200 px, 75.6 MHz: 1.59 ms strobe per
 * 27.8 ms frame, 36 fps, duty 5.7 %). The IR emitter is lit by the sensor's
 * strobe for the whole exposure, so these two numbers are the safety control.
 * The vd55g driver enforces them whatever user space asks; the bridge asks for
 * exactly these values and never for anything longer or faster. */
#define IR_WIN_EXPOSURE_LINES 100
#define IR_WIN_FRAME_LENGTH 1750

/* Hard ceiling for one CAMSS streaming session, in ms. The emitter plan makes
 * this a safety budget: a session never streams longer than this, whatever the
 * configuration says, and the consumer must start again for a new one. */
#define IR_SESSION_MAX_MS 10000

enum { IR_LOG_ERR = 3, IR_LOG_WARN = 4, IR_LOG_INFO = 6, IR_LOG_DEBUG = 7 };

void ir_log(int prio, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
int64_t ir_now_ms(void);
/* ioctl() that retries on EINTR */
int ir_ioctl(int fd, unsigned long req, void *arg);
/* Path (/dev/videoN) of the video4linux device whose name is <card>. 0 or -1. */
int ir_find_loopback(const char *card, char *path, size_t len);

#endif
