/* SPDX-License-Identifier: MIT */
#define _GNU_SOURCE
#include "ir_selftest.h"
#include "ir_common.h"
#include "ir_repack.h"

#include <errno.h>
#include <fcntl.h>
#include <linux/videodev2.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define NBUF 4
#define FIRST_TIMEOUT_MS 15000 /* sensor power-up, firmware patch, links */
#define FRAME_TIMEOUT_MS 2000

int ir_selftest(const char *dev, unsigned nframes)
{
	char path[64];
	struct v4l2_capability cap;
	struct v4l2_format f;
	struct v4l2_requestbuffers rb;
	void *map[NBUF] = { 0 };
	size_t maplen[NBUF] = { 0 };
	unsigned nbuf = 0, i, w, h, stride, got = 0, black = 0;
	int type = V4L2_BUF_TYPE_VIDEO_CAPTURE, fd, rc = 1, discarded = 0;
	int64_t t_on, t_first = 0, t_last = 0;
	double sum = 0, mn = 1e9, mx = -1;

	if (dev) {
		snprintf(path, sizeof(path), "%s", dev);
	} else if (ir_find_loopback(IR_LOOPBACK_CARD, path, sizeof(path)) < 0) {
		fprintf(stderr, "selftest: no \"%s\" device (is v4l2loopback loaded?)\n",
			IR_LOOPBACK_CARD);
		return 1;
	}
	fd = open(path, O_RDWR | O_NONBLOCK | O_CLOEXEC);
	if (fd < 0) {
		fprintf(stderr, "selftest: open %s: %s\n", path, strerror(errno));
		return 1;
	}
	memset(&cap, 0, sizeof(cap));
	if (ir_ioctl(fd, VIDIOC_QUERYCAP, &cap) < 0 ||
	    !((cap.device_caps ? cap.device_caps : cap.capabilities) & V4L2_CAP_VIDEO_CAPTURE)) {
		fprintf(stderr, "selftest: %s is not a capture device yet (the bridge has not set it up)\n",
			path);
		goto out;
	}
	memset(&f, 0, sizeof(f));
	f.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	if (ir_ioctl(fd, VIDIOC_G_FMT, &f) < 0) {
		fprintf(stderr, "selftest: G_FMT: %s\n", strerror(errno));
		goto out;
	}
	if (f.fmt.pix.pixelformat != V4L2_PIX_FMT_GREY) {
		fprintf(stderr, "selftest: pixel format is not GREY\n");
		goto out;
	}
	w = f.fmt.pix.width;
	h = f.fmt.pix.height;
	stride = f.fmt.pix.bytesperline ? f.fmt.pix.bytesperline : w;
	printf("selftest: %s (%s) GREY %ux%u stride %u\n", path, (char *)cap.card, w, h, stride);

	memset(&rb, 0, sizeof(rb));
	rb.count = NBUF;
	rb.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	rb.memory = V4L2_MEMORY_MMAP;
	if (ir_ioctl(fd, VIDIOC_REQBUFS, &rb) < 0) {
		fprintf(stderr, "selftest: REQBUFS: %s (another consumer streaming?)\n", strerror(errno));
		goto out;
	}
	for (i = 0; i < rb.count && i < NBUF; i++) {
		struct v4l2_buffer b;

		memset(&b, 0, sizeof(b));
		b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
		b.memory = V4L2_MEMORY_MMAP;
		b.index = i;
		if (ir_ioctl(fd, VIDIOC_QUERYBUF, &b) < 0)
			goto out;
		map[i] = mmap(NULL, b.length, PROT_READ, MAP_SHARED, fd, b.m.offset);
		if (map[i] == MAP_FAILED) {
			map[i] = NULL;
			goto out;
		}
		maplen[i] = b.length;
		nbuf = i + 1;
		if (ir_ioctl(fd, VIDIOC_QBUF, &b) < 0)
			goto out;
	}
	t_on = ir_now_ms();
	if (ir_ioctl(fd, VIDIOC_STREAMON, &type) < 0) {
		fprintf(stderr, "selftest: STREAMON: %s\n", strerror(errno));
		goto out;
	}
	printf("selftest: streaming, waiting for %u frames (the sensor powers up now)\n", nframes);

	while (got < nframes) {
		struct pollfd p = { .fd = fd, .events = POLLIN };
		struct v4l2_buffer b;
		int pr = poll(&p, 1, got || discarded ? FRAME_TIMEOUT_MS : FIRST_TIMEOUT_MS);

		if (pr == 0) {
			fprintf(stderr, "selftest: timeout waiting for a frame after %u good frame(s); "
				"is the bridge running (systemctl status sl7-ir-bridge)?\n", got);
			goto done;
		}
		if (pr < 0) {
			if (errno == EINTR)
				continue;
			goto done;
		}
		memset(&b, 0, sizeof(b));
		b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
		b.memory = V4L2_MEMORY_MMAP;
		if (ir_ioctl(fd, VIDIOC_DQBUF, &b) < 0) {
			if (errno == EAGAIN)
				continue;
			fprintf(stderr, "selftest: DQBUF: %s\n", strerror(errno));
			goto done;
		}
		if (b.index < nbuf && ir_frame_complete(b.bytesused, w, h, stride)) {
			if (!discarded) {
				/* A new reader first sees the newest frame in the loopback,
				 * which is the bridge's idle black frame. Not counted. */
				discarded = 1;
			} else {
				double m = ir_mean_grey(map[b.index], w, h, stride);
				int64_t now = ir_now_ms();

				if (!got)
					t_first = now;
				t_last = now;
				got++;
				sum += m;
				if (m < mn)
					mn = m;
				if (m > mx)
					mx = m;
				if (m < 1.0)
					black++;
			}
		}
		ir_ioctl(fd, VIDIOC_QBUF, &b);
	}
done:
	ir_ioctl(fd, VIDIOC_STREAMOFF, &type);
	if (got) {
		double secs = (double)(t_last - t_first) / 1000.0;

		printf("frames: %u\n", got);
		printf("first frame after: %lld ms\n", (long long)(t_first - t_on));
		if (got > 1 && secs > 0)
			printf("fps: %.1f (%u intervals in %.0f ms)\n", (got - 1) / secs, got - 1,
			       secs * 1000.0);
		printf("brightness: mean %.1f (min %.1f, max %.1f), %u black frame(s)\n", sum / got, mn,
		       mx, black);
		if (got == nframes)
			rc = black == got ? 3 : 0;
		if (rc == 3)
			printf("note: every frame is black (dark scene and no emitter yet, or covered sensor)\n");
	}
	printf("selftest: %s\n", rc == 0 ? "PASS" : rc == 3 ? "PASS (black frames)" : "FAIL");
out:
	for (i = 0; i < nbuf; i++)
		if (map[i])
			munmap(map[i], maplen[i]);
	close(fd);
	return rc;
}
