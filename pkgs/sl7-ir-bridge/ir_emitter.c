/* SPDX-License-Identifier: MIT */
/*
 * IR emitter control for a streaming session.
 *
 * The IR emitter is lit by the VD55G0's GPIO 1 strobe alone: it is high for the
 * whole exposure of every frame while the vd55g "LED mode" control is not off
 * (stage C of the emitter plan; the PMIC flash is not in the path). The only
 * safety control is therefore the strobe duration, i.e. the exposure, and the
 * frame length. The kernel (linux-sl7 7.2.8-22, patch 0098) holds both to the
 * values Windows Hello uses whenever the strobe is on, whatever is asked.
 * This file asks for exactly those values, so that the log shows what runs:
 *
 *   before STREAMON:  vblank = 1750 - height   (frame length 1750 lines)
 *                     exposure auto -> manual, exposure = 100 lines
 *                     analogue and digital gain = the driver defaults
 *                     (Windows' init writes no gain register)
 *                     led_mode = flash
 *   before STREAMOFF: led_mode = none
 *
 * IR_EMITTER=off in /etc/sl7-ir-bridge.conf keeps the emitter dark: led_mode
 * is then set to none before every session, so a state left behind by another
 * tool cannot light it. The optional IR_GAIN_ANALOG / IR_GAIN_DIGITAL
 * settings change the gains only; exposure and frame length are not settable.
 *
 * The sensor subdev node is opened for each call (no descriptor is kept); the
 * unit already allows the video4linux char devices.
 */
#define _GNU_SOURCE
#include "ir_emitter.h"
#include "ir_common.h"

#include <errno.h>
#include <fcntl.h>
#include <linux/videodev2.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

/* While this file is younger than HANDS_OFF_MAX_AGE_S the bridge leaves led_mode
 * and the sensor timing alone: a test tool (sl7-ir-emitter-test --stage c0b)
 * that sets them itself is not overridden. The kernel still holds the strobe
 * to Windows' timing. A stale file (a crashed tool) stops counting after two
 * minutes and /run is cleared at boot. */
#define HANDS_OFF_FILE "/run/sl7-ir-bridge.hands-off"
#define HANDS_OFF_MAX_AGE_S 120

static int emitter_on = 1;
static int session_hands_off;
static long gain_analog = -1, gain_digital = -1; /* -1: the driver default */

static int hands_off(void)
{
	struct stat st;

	if (stat(HANDS_OFF_FILE, &st) < 0)
		return 0;
	return difftime(time(NULL), st.st_mtime) < HANDS_OFF_MAX_AGE_S;
}

static long env_long(const char *name)
{
	const char *v = getenv(name);
	char *end;
	long x;

	if (!v || !*v)
		return -1;
	x = strtol(v, &end, 10);
	if (*end || x < 0 || x > 65535) {
		ir_log(IR_LOG_WARN, "%s=%s not understood, using the driver default", name, v);
		return -1;
	}
	return x;
}

/* Set a control and read it back. -ENOENT when the control does not exist. */
static int ctrl_set(int fd, uint32_t id, int32_t value, int use_default, const char *name,
		    int32_t *applied)
{
	struct v4l2_queryctrl q;
	struct v4l2_control ctl;

	memset(&q, 0, sizeof(q));
	q.id = id;
	if (ir_ioctl(fd, VIDIOC_QUERYCTRL, &q) < 0 || (q.flags & V4L2_CTRL_FLAG_DISABLED))
		return -ENOENT;
	if (use_default)
		value = q.default_value;
	memset(&ctl, 0, sizeof(ctl));
	ctl.id = id;
	ctl.value = value;
	if (ir_ioctl(fd, VIDIOC_S_CTRL, &ctl) < 0) {
		int e = errno;

		ir_log(IR_LOG_WARN, "emitter: set %s=%d: %s", name, value, strerror(e));
		return -e;
	}
	memset(&ctl, 0, sizeof(ctl));
	ctl.id = id;
	if (ir_ioctl(fd, VIDIOC_G_CTRL, &ctl) < 0) {
		*applied = value;
		return 0;
	}
	*applied = ctl.value;
	return 0;
}

static int led_mode_set(int fd, int value, int32_t *applied)
{
	return ctrl_set(fd, V4L2_CID_FLASH_LED_MODE, value, 0, "led_mode", applied);
}

int ir_emitter_configure(const char *setting)
{
	emitter_on = 1;
	if (setting && *setting) {
		if (!strcmp(setting, "off")) {
			emitter_on = 0;
		} else if (strcmp(setting, "on") != 0) {
			ir_log(IR_LOG_WARN, "IR_EMITTER=%s not understood, using \"on\"", setting);
		}
	}
	gain_analog = env_long("IR_GAIN_ANALOG");
	gain_digital = env_long("IR_GAIN_DIGITAL");
	ir_log(IR_LOG_INFO, "IR emitter %s (Windows timing: exposure %d lines, frame length %d lines)",
	       emitter_on ? "ON for each session" : "OFF (led_mode forced to none)",
	       IR_WIN_EXPOSURE_LINES, IR_WIN_FRAME_LENGTH);
	return emitter_on;
}

int ir_emitter_pre_stream(struct ir_camss *c)
{
	int32_t mode = -1, vblank = -1, expo = -1, again = -1, dgain = -1, aeauto = -1;
	int fd, rc;

	session_hands_off = hands_off();
	if (session_hands_off) {
		ir_log(IR_LOG_INFO, "emitter: %s is fresh, a test tool owns led_mode; the bridge leaves it alone",
		       HANDS_OFF_FILE);
		return 0;
	}
	fd = open(c->sensor_node, O_RDWR | O_CLOEXEC);
	if (fd < 0) {
		rc = -errno;
		ir_log(IR_LOG_WARN, "emitter: open %s: %s", c->sensor_node, strerror(errno));
		return rc;
	}
	if (!emitter_on) {
		rc = led_mode_set(fd, V4L2_FLASH_LED_MODE_NONE, &mode);
		close(fd);
		return rc == -ENOENT ? 0 : rc;
	}

	/* The kernel raises or lowers whatever does not fit Windows' limits; the
	 * values below are the ones Windows uses. Frame length first: the
	 * exposure ceiling follows from it. */
	rc = ctrl_set(fd, V4L2_CID_VBLANK, IR_WIN_FRAME_LENGTH - (int)c->height, 0, "vblank", &vblank);
	if (rc == -ENOENT) {
		ir_log(IR_LOG_WARN, "emitter: no vblank control on %s, running unlit", c->sensor_node);
		close(fd);
		return 0;
	}
	if (rc < 0)
		goto unlit;
	rc = ctrl_set(fd, V4L2_CID_EXPOSURE_AUTO, V4L2_EXPOSURE_MANUAL, 0, "exposure_auto", &aeauto);
	if (rc < 0)
		goto unlit;
	rc = ctrl_set(fd, V4L2_CID_EXPOSURE, IR_WIN_EXPOSURE_LINES, 0, "exposure", &expo);
	if (rc < 0)
		goto unlit;
	rc = ctrl_set(fd, V4L2_CID_ANALOGUE_GAIN, (int32_t)gain_analog, gain_analog < 0,
		      "analogue_gain", &again);
	if (rc < 0 && rc != -ENOENT)
		goto unlit;
	rc = ctrl_set(fd, V4L2_CID_DIGITAL_GAIN, (int32_t)gain_digital, gain_digital < 0,
		      "digital_gain", &dgain);
	if (rc < 0 && rc != -ENOENT)
		goto unlit;
	/* Never light the emitter unless the sensor reads back Windows' timing or
	 * a gentler one. */
	if (expo < 1 || expo > IR_WIN_EXPOSURE_LINES || vblank + (int)c->height < IR_WIN_FRAME_LENGTH ||
	    aeauto != V4L2_EXPOSURE_MANUAL) {
		ir_log(IR_LOG_WARN,
		       "emitter: sensor reads back exposure %d, frame length %d, auto exposure %d; not Windows' timing, running unlit",
		       expo, vblank + (int)c->height, aeauto);
		rc = -EIO;
		goto unlit;
	}
	rc = led_mode_set(fd, V4L2_FLASH_LED_MODE_FLASH, &mode);
	if (rc == -ENOENT) {
		ir_log(IR_LOG_WARN,
		       "emitter: %s has no led_mode control (linux-sl7 older than 7.2.8-22 or vd55g.illuminator=0), running unlit",
		       c->sensor_node);
		close(fd);
		return 0;
	}
	if (rc < 0)
		goto unlit;
	if (mode != V4L2_FLASH_LED_MODE_FLASH) {
		ir_log(IR_LOG_WARN, "emitter: led_mode reads back %d, running unlit", mode);
		led_mode_set(fd, V4L2_FLASH_LED_MODE_NONE, &mode);
		close(fd);
		return -EIO;
	}
	close(fd);
	ir_log(IR_LOG_INFO,
	       "emitter ON: led_mode=flash exposure=%d lines (asked %d, Windows %d) vblank=%d (frame length %d, Windows %d) gain a=%d d=%d, auto exposure %d",
	       expo, IR_WIN_EXPOSURE_LINES, IR_WIN_EXPOSURE_LINES, vblank, vblank + (int)c->height,
	       IR_WIN_FRAME_LENGTH, again, dgain, aeauto);
	return 0;
unlit:
	/* Could not set the Windows values: do not light the emitter on a guess. */
	led_mode_set(fd, V4L2_FLASH_LED_MODE_NONE, &mode);
	close(fd);
	ir_log(IR_LOG_WARN, "emitter: could not apply Windows' sensor settings, session runs unlit");
	return rc;
}

void ir_emitter_post_stream(struct ir_camss *c)
{
	int32_t mode = -1;
	int fd, rc;

	if (c->sensor_node[0] == '\0' || session_hands_off)
		return;
	fd = open(c->sensor_node, O_RDWR | O_CLOEXEC);
	if (fd < 0) {
		ir_log(IR_LOG_WARN, "emitter: open %s to switch led_mode off: %s", c->sensor_node,
		       strerror(errno));
		return;
	}
	rc = led_mode_set(fd, V4L2_FLASH_LED_MODE_NONE, &mode);
	close(fd);
	if (rc < 0 && rc != -ENOENT)
		ir_log(IR_LOG_WARN, "emitter: led_mode=none on %s failed: %s", c->sensor_node,
		       strerror(-rc));
	else if (rc == 0 && mode != V4L2_FLASH_LED_MODE_NONE)
		ir_log(IR_LOG_WARN, "emitter: led_mode reads back %d after switching off", mode);
}
