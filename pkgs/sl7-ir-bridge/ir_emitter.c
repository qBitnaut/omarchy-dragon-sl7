/* SPDX-License-Identifier: MIT */
/*
 * IR emitter hook points (stage D of the emitter plan).
 *
 * THIS PACKAGE VERSION NEVER DRIVES THE EMITTER. By default (and always, in
 * the packaged build) the three functions below are no-ops. The code path
 * that would set the vd55g "LED mode" control is compiled in only with
 * -DSL7_IR_EMITTER_BUILD=1, and even then only when IR_EMITTER=on is set in
 * /etc/sl7-ir-bridge.conf. The packaged build leaves it out, so IR_EMITTER=on
 * logs a warning and changes nothing.
 *
 * Contract for the later stage, from the emitter plan:
 *   - before STREAMON on the CAMSS node: V4L2_CID_FLASH_LED_MODE on the
 *     vd55g subdev, only when the control exists (it latches at stream start);
 *   - after STREAMOFF: set it back to V4L2_FLASH_LED_MODE_NONE;
 *   - the kernel owns the safety limits (session watchdog, rolling budget).
 *     The bridge adds its own 10 s session cap (IR_SESSION_MAX_MS).
 * No other LED class device, no GPIO and no sysfs write is touched here.
 *
 * To run this under the shipped systemd sandbox the unit already allows the
 * video4linux char devices (the subdev node is one of them).
 */
#define _GNU_SOURCE
#include "ir_emitter.h"
#include "ir_common.h"

#include <string.h>

#ifdef SL7_IR_EMITTER_BUILD
#include <errno.h>
#include <fcntl.h>
#include <linux/videodev2.h>
#include <unistd.h>

static int emitter_on;

static int set_led_mode(const char *node, int value)
{
	struct v4l2_queryctrl q;
	struct v4l2_control ctl;
	int fd = open(node, O_RDWR | O_CLOEXEC);
	int rc = 0;

	if (fd < 0)
		return -errno;
	memset(&q, 0, sizeof(q));
	q.id = V4L2_CID_FLASH_LED_MODE;
	if (ir_ioctl(fd, VIDIOC_QUERYCTRL, &q) < 0 || (q.flags & V4L2_CTRL_FLAG_DISABLED)) {
		rc = -ENOENT; /* no such control on this kernel: nothing to do */
	} else {
		memset(&ctl, 0, sizeof(ctl));
		ctl.id = V4L2_CID_FLASH_LED_MODE;
		ctl.value = value;
		if (ir_ioctl(fd, VIDIOC_S_CTRL, &ctl) < 0)
			rc = -errno;
	}
	close(fd);
	return rc;
}
#endif

int ir_emitter_configure(const char *setting)
{
	if (!setting || !*setting || !strcmp(setting, "off"))
		return 0;
	if (strcmp(setting, "on") != 0) {
		ir_log(IR_LOG_WARN, "IR_EMITTER=%s not understood, emitter stays off", setting);
		return 0;
	}
#ifdef SL7_IR_EMITTER_BUILD
	emitter_on = 1;
	ir_log(IR_LOG_WARN, "IR emitter control ENABLED (led_mode on the sensor subdev)");
	return 1;
#else
	ir_log(IR_LOG_WARN, "IR_EMITTER=on ignored: emitter support is not built into this package");
	return 0;
#endif
}

int ir_emitter_pre_stream(struct ir_camss *c)
{
#ifdef SL7_IR_EMITTER_BUILD
	if (emitter_on) {
		int rc = set_led_mode(c->sensor_node, V4L2_FLASH_LED_MODE_FLASH);

		if (rc < 0)
			ir_log(IR_LOG_WARN, "emitter: led_mode=flash on %s failed: %s", c->sensor_node,
			       strerror(-rc));
		return rc;
	}
#endif
	(void)c;
	return 0;
}

void ir_emitter_post_stream(struct ir_camss *c)
{
#ifdef SL7_IR_EMITTER_BUILD
	if (emitter_on) {
		int rc = set_led_mode(c->sensor_node, V4L2_FLASH_LED_MODE_NONE);

		if (rc < 0 && rc != -ENOENT)
			ir_log(IR_LOG_WARN, "emitter: led_mode=none on %s failed: %s", c->sensor_node,
			       strerror(-rc));
	}
#endif
	(void)c;
}
