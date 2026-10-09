/* SPDX-License-Identifier: MIT */
/*
 * sl7-ir-bridge: on-demand bridge from the Surface Laptop 7 IR camera (CAMSS
 * raw node, Y8 644x604 with a 656 byte stride) to a v4l2loopback device with
 * tight GREY frames, for howdy-next and other V4L2/OpenCV consumers.
 *
 * The daemon is idle at boot. The sensor stays off until a consumer starts
 * streaming on the loopback node: v4l2loopback queues V4L2_EVENT_PRI_CLIENT_USAGE
 * (count 1 = a capture client holds the stream, 0 = none) on capture STREAMON,
 * STREAMOFF and close. Then it sets up the IR media links and formats (IR path
 * only), streams the CAMSS node and writes frames; when the consumer stops it
 * stops the CAMSS stream after a short grace period and the sensor powers down.
 *
 * Usage:
 *   sl7-ir-bridge                    run the daemon (systemd Type=simple)
 *   sl7-ir-bridge --selftest [-n N] [-d DEV]
 *                                    stream N frames (default 30) from the
 *                                    loopback, report fps and mean brightness
 *   sl7-ir-bridge --version | --help
 *
 * Environment (the unit reads /etc/sl7-ir-bridge.conf):
 *   IR_EMITTER=on|off       light the IR emitter for each session (default on):
 *                           Windows' exposure and frame length, led_mode=flash;
 *                           "off" keeps led_mode at none (see ir_emitter.c)
 *   IR_GAIN_ANALOG, IR_GAIN_DIGITAL
 *                           optional gain control values (default: the driver's)
 *   IR_STOP_GRACE_MS=500    keep streaming this long after the consumer stops
 *   IR_SESSION_MAX_MS=10000 per-session streaming cap, never above 10000
 *   SL7_IR_DEBUG=1          debug logging
 */
#define _GNU_SOURCE
#include "ir_camss.h"
#include "ir_common.h"
#include "ir_emitter.h"
#include "ir_repack.h"
#include "ir_selftest.h"

#include <errno.h>
#include <fcntl.h>
#include <linux/videodev2.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/signalfd.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define VERSION "0.1.0"

/* v4l2loopback private event: V4L2_EVENT_PRIVATE_START + 0x08E00000 + 1.
 * The payload is a __u32 count in the event union. */
#define V4L2LOOPBACK_EVENT_CLIENT_USAGE (V4L2_EVENT_PRIVATE_START + 0x08E00000 + 1)

#define LOOPBACK_WAIT_MS 60000
/* A route that set up but delivers nothing in this long is marked bad. */
#define FIRST_FRAME_TIMEOUT_MS 2000
#define FRAME_GAP_TIMEOUT_MS 1500
#define RETRY_MS 5000
#define NO_FRAME_BAD_MS 1500
#define RETRY_MAX_SHIFT 2	/* retry delay 5 s, 10 s, 20 s, then stays at 20 s */
#define CAPPED_RESYNC_MS 1000
#define MAX_LB_ERRORS 100
/* Session starts failing with EBUSY for this long: say who holds the IR path
 * (once) and leave a flag file for sl7-doctor and omarchy-sl7-faceunlock. The
 * unit's RuntimeDirectory removes the file when the bridge stops. */
#define BUSY_REPORT_MS 30000
#define BUSY_STATE_FILE "/run/sl7-ir-bridge/ebusy"
/* Another process holds the loopback we must write to (EBUSY on open or on
 * VIDIOC_S_FMT): it may be feeding the consumers its own frames. Written with
 * the holders; read by sl7-doctor and omarchy-sl7-faceunlock. */
#define FOREIGN_STATE_FILE "/run/sl7-ir-bridge/foreign-writer"

struct bridge {
	int lb_fd;
	char lb_path[64];
	struct ir_camss cam;
	bool want;	/* a consumer is streaming on the loopback */
	bool running;	/* CAMSS is streaming */
	bool capped;	/* session cap hit: wait for a fresh consumer start */
	bool seen_frame;
	int64_t t_start, t_last_frame, t_first_frame, stop_at, retry_at, resync_at;
	unsigned start_failures;	/* consecutive failed session starts */
	int64_t busy_since;	/* first of the consecutive EBUSY starts, 0 = none */
	bool busy_reported;	/* holders logged and the flag file written */
	uint64_t frames, dropped;
	unsigned lb_errors;
	int64_t grace_ms, session_max_ms;
	uint8_t *tight;
	uint8_t *black;
};

static long env_ms(const char *name, long def, long lo, long hi)
{
	const char *v = getenv(name);
	char *end;
	long x;

	if (!v || !*v)
		return def;
	x = strtol(v, &end, 10);
	if (*end || x < lo || x > hi) {
		ir_log(IR_LOG_WARN, "%s=%s out of range [%ld,%ld], using %ld", name, v, lo, hi, def);
		return def;
	}
	return x;
}

static int lb_write(struct bridge *b, const uint8_t *frame)
{
	ssize_t n;

	do {
		n = write(b->lb_fd, frame, IR_FRAME_SIZE);
	} while (n < 0 && errno == EINTR);
	if (n != (ssize_t)IR_FRAME_SIZE) {
		if (b->lb_errors++ == 0)
			ir_log(IR_LOG_WARN, "write to %s failed: %s", b->lb_path,
			       n < 0 ? strerror(errno) : "short write");
		return -1;
	}
	b->lb_errors = 0;
	return 0;
}

/* The loopback open or format set failed with EBUSY: log who holds the node
 * and leave the flag file. */
static void foreign_writer_note(struct bridge *b)
{
	char holders[2048];
	char *line, *save = NULL;
	int n;
	FILE *f;

	ir_log(IR_LOG_ERR, "foreign writer on the IR camera: %s is busy (EBUSY), another "
	       "process holds the loopback the bridge must write to", b->lb_path);
	n = ir_find_node_holders(b->lb_path, holders, sizeof(holders));
	if (n < 0) {
		ir_log(IR_LOG_ERR, "cannot look for the holder: %s", strerror(-n));
		holders[0] = 0;
	} else if (n == 0) {
		ir_log(IR_LOG_ERR, "no process holds %s open", b->lb_path);
	}
	f = fopen(FOREIGN_STATE_FILE, "we");
	if (f) {
		fchmod(fileno(f), 0644);
		fprintf(f, "since=%lld\nholders=%d\n", (long long)time(NULL), n < 0 ? 0 : n);
		fputs(holders, f);
		fclose(f);
	} else {
		ir_log(IR_LOG_WARN, "cannot write %s: %s", FOREIGN_STATE_FILE, strerror(errno));
	}
	for (line = strtok_r(holders, "\n", &save); line; line = strtok_r(NULL, "\n", &save))
		ir_log(IR_LOG_ERR, "loopback holder: %s", line);
}

static int open_loopback(struct bridge *b)
{
	struct v4l2_capability cap;
	struct v4l2_format f;
	struct v4l2_streamparm sp;
	struct v4l2_event_subscription sub;

	b->lb_fd = open(b->lb_path, O_RDWR | O_NONBLOCK | O_CLOEXEC);
	if (b->lb_fd < 0) {
		ir_log(IR_LOG_ERR, "open %s: %s", b->lb_path, strerror(errno));
		if (errno == EBUSY)
			foreign_writer_note(b);
		return -1;
	}
	memset(&cap, 0, sizeof(cap));
	if (ir_ioctl(b->lb_fd, VIDIOC_QUERYCAP, &cap) < 0 || strcmp((char *)cap.driver, "v4l2 loopback")) {
		ir_log(IR_LOG_ERR, "%s is not a v4l2loopback device", b->lb_path);
		return -1;
	}
	memset(&f, 0, sizeof(f));
	f.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
	f.fmt.pix.width = IR_WIDTH;
	f.fmt.pix.height = IR_HEIGHT;
	f.fmt.pix.pixelformat = V4L2_PIX_FMT_GREY;
	f.fmt.pix.field = V4L2_FIELD_NONE;
	f.fmt.pix.bytesperline = IR_WIDTH;
	f.fmt.pix.sizeimage = IR_FRAME_SIZE;
	f.fmt.pix.colorspace = V4L2_COLORSPACE_RAW;
	if (ir_ioctl(b->lb_fd, VIDIOC_S_FMT, &f) < 0) {
		ir_log(IR_LOG_ERR, "%s: set GREY %dx%d: %s", b->lb_path, IR_WIDTH, IR_HEIGHT, strerror(errno));
		if (errno == EBUSY)
			foreign_writer_note(b);
		return -1;
	}
	if (f.fmt.pix.pixelformat != V4L2_PIX_FMT_GREY || f.fmt.pix.width != IR_WIDTH ||
	    f.fmt.pix.height != IR_HEIGHT || f.fmt.pix.sizeimage != IR_FRAME_SIZE) {
		ir_log(IR_LOG_ERR, "%s: loopback changed the format to %ux%u size %u", b->lb_path,
		       f.fmt.pix.width, f.fmt.pix.height, f.fmt.pix.sizeimage);
		return -1;
	}
	memset(&sp, 0, sizeof(sp));
	sp.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
	sp.parm.output.timeperframe.numerator = 1;
	sp.parm.output.timeperframe.denominator = IR_FPS;
	if (ir_ioctl(b->lb_fd, VIDIOC_S_PARM, &sp) < 0)
		ir_log(IR_LOG_DEBUG, "S_PARM on the loopback failed (ignored): %s", strerror(errno));

	/* SEND_INITIAL reports a consumer that is already streaming */
	memset(&sub, 0, sizeof(sub));
	sub.type = V4L2LOOPBACK_EVENT_CLIENT_USAGE;
	sub.flags = V4L2_EVENT_SUB_FL_SEND_INITIAL;
	if (ir_ioctl(b->lb_fd, VIDIOC_SUBSCRIBE_EVENT, &sub) < 0) {
		ir_log(IR_LOG_ERR, "%s: subscribe to the client-usage event: %s "
		       "(v4l2loopback without client-usage events?)", b->lb_path, strerror(errno));
		return -1;
	}
	/* The first write makes this fd the long-lived writer: the format now
	 * lives as long as the daemon, and consumers see a capture device. */
	if (lb_write(b, b->black) < 0)
		return -1;
	return 0;
}

/* Returns 0, or -1 if the loopback is gone. */
static int drain_events(struct bridge *b)
{
	for (;;) {
		struct v4l2_event ev;

		memset(&ev, 0, sizeof(ev));
		if (ir_ioctl(b->lb_fd, VIDIOC_DQEVENT, &ev) < 0) {
			if (errno == ENOENT || errno == EAGAIN)
				return 0;
			ir_log(IR_LOG_ERR, "DQEVENT: %s", strerror(errno));
			return -1;
		}
		if (ev.type == V4L2LOOPBACK_EVENT_CLIENT_USAGE) {
			uint32_t count;

			memcpy(&count, ev.u.data, sizeof(count));
			if (count != 0 && !b->want) {
				/* a fresh consumer start: no waiting for an old failure */
				b->retry_at = 0;
				b->start_failures = 0;
			}
			b->want = count != 0;
			if (!b->want)
				b->capped = false; /* the next start is a fresh session */
			ir_log(IR_LOG_DEBUG, "client usage event: count %u", count);
		}
	}
}

/* Ask v4l2loopback for the current client count again (a new subscription
 * with SEND_INITIAL queues it). The event queue has one slot, so a consumer
 * that goes away abruptly can leave the 0 unseen; used while capped. */
static int resync_usage(struct bridge *b)
{
	struct v4l2_event_subscription sub;

	memset(&sub, 0, sizeof(sub));
	sub.type = V4L2LOOPBACK_EVENT_CLIENT_USAGE;
	ir_ioctl(b->lb_fd, VIDIOC_UNSUBSCRIBE_EVENT, &sub);
	sub.flags = V4L2_EVENT_SUB_FL_SEND_INITIAL;
	if (ir_ioctl(b->lb_fd, VIDIOC_SUBSCRIBE_EVENT, &sub) < 0) {
		ir_log(IR_LOG_ERR, "%s: re-subscribe to the client-usage event: %s", b->lb_path,
		       strerror(errno));
		return -1;
	}
	return drain_events(b);
}

static void session_stop(struct bridge *b, const char *reason)
{
	int64_t now = ir_now_ms();
	double secs = (double)(now - b->t_start) / 1000.0;

	/* No frame in the whole session, and long enough that the route (not a
	 * quick consumer exit) is at fault: use the next candidate next time. */
	if (b->frames == 0 && !b->seen_frame && now - b->t_start >= NO_FRAME_BAD_MS)
		ir_camss_mark_bad(&b->cam);
	/* The emitter goes dark first, then the stream and the sensor stop. */
	ir_emitter_post_stream(&b->cam);
	ir_camss_stop(&b->cam);
	ir_camss_close(&b->cam);
	b->running = false;
	b->stop_at = -1;
	/* A new reader first gets the newest frame in the loopback: make that a
	 * black one, never a stale face. */
	lb_write(b, b->black);
	ir_log(IR_LOG_INFO, "session end (%s): %llu frames in %.1f s (%.1f fps), %llu dropped",
	       reason, (unsigned long long)b->frames, secs, secs > 0 ? b->frames / secs : 0.0,
	       (unsigned long long)b->dropped);
}

static int session_start(struct bridge *b)
{
	int rc;

	ir_camss_init(&b->cam);
	rc = ir_camss_open(&b->cam, IR_WIDTH, IR_HEIGHT);
	if (rc < 0)
		return rc;
	/* Emitter: Windows' sensor settings and led_mode=flash after the links and
	 * formats, before STREAMON (it latches when the stream starts). A failure
	 * is logged and the session runs unlit. */
	ir_emitter_pre_stream(&b->cam);
	rc = ir_camss_start(&b->cam);
	if (rc < 0) {
		ir_emitter_post_stream(&b->cam);
		ir_camss_close(&b->cam);
		return rc;
	}
	b->running = true;
	b->seen_frame = false;
	b->frames = b->dropped = 0;
	b->t_start = b->t_last_frame = ir_now_ms();
	b->stop_at = -1;
	ir_log(IR_LOG_INFO, "session start: consumer on %s, CAMSS %s %s/%s -> %s GREY %ux%u stride %u",
	       b->lb_path, b->cam.media_path, b->cam.csid_name, b->cam.rdi_name, b->cam.video_path, b->cam.width, b->cam.height,
	       b->cam.stride);
	return 0;
}

static void busy_clear(struct bridge *b)
{
	if (b->busy_reported) {
		unlink(BUSY_STATE_FILE);
		ir_log(IR_LOG_INFO, "the IR path is no longer busy");
	}
	b->busy_since = 0;
	b->busy_reported = false;
}

/* A session start failed with EBUSY. After BUSY_REPORT_MS of it, log the
 * likely holder once and write the flag file. */
static void busy_note(struct bridge *b, int64_t now)
{
	char holders[2048];
	char *line, *save = NULL;
	int n;
	FILE *f;

	if (!b->busy_since) {
		b->busy_since = now;
		return;
	}
	if (b->busy_reported || now - b->busy_since < BUSY_REPORT_MS)
		return;
	b->busy_reported = true;
	ir_log(IR_LOG_ERR, "the IR path has been busy for %lld s (EBUSY enabling its links): "
	       "something else holds it open or streams it",
	       (long long)((now - b->busy_since) / 1000));
	n = ir_camss_find_holders(holders, sizeof(holders));
	if (n < 0) {
		ir_log(IR_LOG_ERR, "cannot look for the holder: %s", strerror(-n));
		holders[0] = 0;
	} else if (n == 0) {
		ir_log(IR_LOG_ERR, "no process holds the IR video node, its subdevs or the CAMSS "
		       "media device open (the holder may be inside the kernel: a stream whose "
		       "owner is gone)");
	}
	f = fopen(BUSY_STATE_FILE, "we");
	if (f) {
		fchmod(fileno(f), 0644);
		fprintf(f, "since=%lld\nholders=%d\n",
			(long long)time(NULL) - (long long)((now - b->busy_since) / 1000), n < 0 ? 0 : n);
		fputs(holders, f);
		fclose(f);
	} else {
		ir_log(IR_LOG_WARN, "cannot write %s: %s", BUSY_STATE_FILE, strerror(errno));
	}
	for (line = strtok_r(holders, "\n", &save); line; line = strtok_r(NULL, "\n", &save))
		ir_log(IR_LOG_ERR, "busy holder: %s", line);
	ir_log(IR_LOG_ERR, "to release it: systemctl --user restart pipewire wireplumber, then "
	       "sudo systemctl restart sl7-ir-bridge");
}

static void tick(struct bridge *b, int64_t now)
{
	if (b->want) {
		b->stop_at = -1;
		if (!b->running && !b->capped && now >= b->retry_at) {
			int rc = session_start(b);

			if (rc < 0) {
				unsigned shift = b->start_failures < RETRY_MAX_SHIFT ? b->start_failures :
										  RETRY_MAX_SHIFT;
				int64_t delay = (int64_t)RETRY_MS << shift;

				/* session_start() already tore down whatever it had set up
				 * (links, buffers, led_mode), so the retry starts clean.
				 * Say it once, then only at debug level. */
				ir_log(b->start_failures ? IR_LOG_DEBUG : IR_LOG_ERR,
				       "session start failed (%s), retrying in %lld s", strerror(-rc),
				       (long long)(delay / 1000));
				b->start_failures++;
				b->retry_at = now + delay;
				if (rc == -EBUSY)
					busy_note(b, now);
				else
					busy_clear(b);
			} else {
				b->start_failures = 0;
				busy_clear(b);
			}
		} else if (b->capped && now >= b->resync_at) {
			/* the consumer may be gone without us having seen its 0 */
			b->resync_at = now + CAPPED_RESYNC_MS;
			if (resync_usage(b) < 0)
				b->capped = false;
		}
	} else if (b->running) {
		if (b->stop_at < 0)
			b->stop_at = now + b->grace_ms;
		if (now >= b->stop_at)
			session_stop(b, "consumer stopped");
	}
	if (b->running) {
		int64_t limit = b->seen_frame ? FRAME_GAP_TIMEOUT_MS : FIRST_FRAME_TIMEOUT_MS;

		if (now - b->t_start >= b->session_max_ms) {
			session_stop(b, "session cap reached, a new consumer start is required");
			b->capped = b->want;
			b->resync_at = now + CAPPED_RESYNC_MS;
		} else if (now - b->t_last_frame > limit) {
			session_stop(b, "no frames from CAMSS");
			b->retry_at = now + RETRY_MS;
		}
	}
}

static int next_timeout(const struct bridge *b, int64_t now)
{
	int64_t t = -1;

	#define MIN_AT(x) do { int64_t d = (x) - now; if (d < 0) d = 0; if (t < 0 || d < t) t = d; } while (0)
	if (b->running) {
		MIN_AT(b->t_start + b->session_max_ms);
		MIN_AT(b->t_last_frame + (b->seen_frame ? FRAME_GAP_TIMEOUT_MS : FIRST_FRAME_TIMEOUT_MS) + 1);
		if (b->stop_at >= 0)
			MIN_AT(b->stop_at);
	} else if (b->want && !b->capped) {
		MIN_AT(b->retry_at);
	} else if (b->capped) {
		MIN_AT(b->resync_at);
	}
	#undef MIN_AT
	return t < 0 ? -1 : (int)(t > 60000 ? 60000 : t);
}

/* Returns 0, or -1 when the CAMSS stream failed. */
static int pump_frames(struct bridge *b)
{
	int n;

	for (n = 0; n < 8; n++) {
		unsigned idx;
		const uint8_t *data;
		size_t used;
		int err, rc;

		rc = ir_camss_dequeue(&b->cam, &idx, &data, &used, &err);
		if (rc == -EAGAIN)
			return 0;
		if (rc < 0) {
			ir_log(IR_LOG_ERR, "DQBUF %s: %s", b->cam.video_path, strerror(-rc));
			return -1;
		}
		if (err || !ir_frame_complete(used, b->cam.width, b->cam.height, b->cam.stride)) {
			b->dropped++;
		} else {
			ir_repack_grey(b->tight, data, b->cam.width, b->cam.height, b->cam.stride);
			if (lb_write(b, b->tight) == 0) {
				b->frames++;
			} else if (b->lb_errors > MAX_LB_ERRORS) {
				ir_log(IR_LOG_ERR, "loopback writes keep failing");
				return -2;
			}
			if (!b->seen_frame) {
				b->seen_frame = true;
				ir_log(IR_LOG_INFO, "first frame after %lld ms",
				       (long long)(ir_now_ms() - b->t_start));
			}
			b->t_last_frame = ir_now_ms();
		}
		if (ir_camss_queue(&b->cam, idx) < 0)
			return -1;
	}
	return 0;
}

static int wait_for_loopback(struct bridge *b, int sfd)
{
	int64_t deadline = ir_now_ms() + LOOPBACK_WAIT_MS;
	int warned = 0;

	for (;;) {
		struct pollfd p = { .fd = sfd, .events = POLLIN };

		if (ir_find_loopback(IR_LOOPBACK_CARD, b->lb_path, sizeof(b->lb_path)) == 0)
			return 0;
		if (!warned) {
			ir_log(IR_LOG_WARN, "waiting for the \"%s\" loopback device (modprobe v4l2loopback)",
			       IR_LOOPBACK_CARD);
			warned = 1;
		}
		if (ir_now_ms() > deadline)
			return -1;
		if (poll(&p, 1, 1000) > 0)
			return -2; /* signal */
	}
}

static int run_daemon(void)
{
	struct bridge b;
	sigset_t mask;
	int sfd, rc = 1;
	char *conf;

	memset(&b, 0, sizeof(b));
	b.lb_fd = -1;
	b.stop_at = -1;
	b.grace_ms = env_ms("IR_STOP_GRACE_MS", 500, 0, 5000);
	b.session_max_ms = env_ms("IR_SESSION_MAX_MS", IR_SESSION_MAX_MS, 1000, IR_SESSION_MAX_MS);
	conf = getenv("IR_EMITTER");
	ir_emitter_configure(conf);
	ir_camss_configure(getenv("IR_CSID"), getenv("IR_VFE_RDI"));
	b.tight = malloc(IR_FRAME_SIZE);
	b.black = calloc(1, IR_FRAME_SIZE);
	if (!b.tight || !b.black)
		return 1;

	sigemptyset(&mask);
	sigaddset(&mask, SIGTERM);
	sigaddset(&mask, SIGINT);
	sigprocmask(SIG_BLOCK, &mask, NULL);
	sfd = signalfd(-1, &mask, SFD_CLOEXEC);
	if (sfd < 0)
		return 1;

	switch (wait_for_loopback(&b, sfd)) {
	case 0:
		break;
	case -2:
		return 0;
	default:
		ir_log(IR_LOG_ERR, "no \"%s\" loopback device after %d s", IR_LOOPBACK_CARD,
		       LOOPBACK_WAIT_MS / 1000);
		return 1;
	}
	if (open_loopback(&b) < 0)
		return 1;
	unlink(BUSY_STATE_FILE);
	unlink(FOREIGN_STATE_FILE);
	ir_camss_release_stale();
	ir_log(IR_LOG_INFO, "sl7-ir-bridge %s idle on %s (stop grace %lld ms, session cap %lld ms)",
	       VERSION, b.lb_path, (long long)b.grace_ms, (long long)b.session_max_ms);

	for (;;) {
		struct pollfd pf[3];
		int np = 2, pr;

		tick(&b, ir_now_ms());
		pf[0] = (struct pollfd){ .fd = sfd, .events = POLLIN };
		pf[1] = (struct pollfd){ .fd = b.lb_fd, .events = POLLPRI };
		if (b.running)
			pf[np++] = (struct pollfd){ .fd = b.cam.video_fd, .events = POLLIN };
		pr = poll(pf, np, next_timeout(&b, ir_now_ms()));
		if (pr < 0) {
			if (errno == EINTR)
				continue;
			break;
		}
		if (pf[0].revents) {
			ir_log(IR_LOG_INFO, "signal received, shutting down");
			rc = 0;
			break;
		}
		if (pf[1].revents & (POLLERR | POLLHUP | POLLNVAL)) {
			ir_log(IR_LOG_ERR, "loopback device went away");
			break;
		}
		if ((pf[1].revents & POLLPRI) && drain_events(&b) < 0)
			break;
		if (b.running && np == 3 && pf[2].revents) {
			int pr2 = pump_frames(&b);

			if (pr2 == -2)
				break;
			if (pr2 < 0 || (pf[2].revents & (POLLERR | POLLHUP | POLLNVAL))) {
				session_stop(&b, "CAMSS stream error");
				b.retry_at = ir_now_ms() + RETRY_MS;
			}
		}
	}
	if (b.running)
		session_stop(&b, "shutdown");
	close(b.lb_fd);
	free(b.tight);
	free(b.black);
	return rc;
}

static void usage(FILE *f)
{
	fputs("usage: sl7-ir-bridge                      run the bridge daemon\n"
	      "       sl7-ir-bridge --selftest [-n N] [-d DEV]\n"
	      "                                         stream N frames (default 30) from the\n"
	      "                                         loopback; report fps and mean brightness\n"
	      "       sl7-ir-bridge --version\n", f);
}

int main(int argc, char **argv)
{
	int i, selftest = 0;
	unsigned n = 30;
	const char *dev = NULL;

	for (i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--selftest")) {
			selftest = 1;
		} else if (!strcmp(argv[i], "-n") && i + 1 < argc) {
			char *end;
			long v = strtol(argv[++i], &end, 10);

			if (*end || v < 2 || v > 100000) {
				usage(stderr);
				return 2;
			}
			n = (unsigned)v;
		} else if (!strcmp(argv[i], "-d") && i + 1 < argc) {
			dev = argv[++i];
		} else if (!strcmp(argv[i], "--version")) {
			puts("sl7-ir-bridge " VERSION);
			return 0;
		} else if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) {
			usage(stdout);
			return 0;
		} else {
			usage(stderr);
			return 2;
		}
	}
	if (selftest)
		return ir_selftest(dev, n);
	if (dev || n != 30) {
		usage(stderr);
		return 2;
	}
	return run_daemon();
}
