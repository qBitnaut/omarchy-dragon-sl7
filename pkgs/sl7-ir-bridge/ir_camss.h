/* SPDX-License-Identifier: MIT */
#ifndef IR_CAMSS_H
#define IR_CAMSS_H

#include <stddef.h>
#include <stdint.h>

#define IR_NBUF 4
#define IR_MAX_HOPS 8

struct ir_hop {
	uint32_t src_ent, src_pad, sink_ent, sink_pad;
	uint32_t flags;
	int we_enabled; /* we turned this link on, so we turn it off again */
};

/* One IR capture path through the qcom-camss media graph:
 * vd55g sensor -> msm_csiphy -> msm_csid0 -> msm_vfe0_rdi0 -> video node.
 * Nothing outside this path is touched (no media-ctl -r equivalent). */
struct ir_camss {
	int media_fd;
	int video_fd;
	char media_path[128];
	char video_path[128];
	char sensor_node[128]; /* the sensor subdev, for the emitter hook */
	unsigned width, height, stride, sizeimage;
	struct ir_hop hops[IR_MAX_HOPS];
	unsigned nhops;
	void *map[IR_NBUF];
	size_t maplen[IR_NBUF];
	unsigned nbuf;
	int streaming;
};

void ir_camss_init(struct ir_camss *c);
/* Find the CAMSS media device, enable the IR links, set Y8_1X8 w x h on every
 * pad of the path, set GREY on the video node and map the buffers.
 * 0 or -errno (a message is logged). */
int ir_camss_open(struct ir_camss *c, unsigned w, unsigned h);
/* Queue all buffers and VIDIOC_STREAMON. This is what powers the sensor. */
int ir_camss_start(struct ir_camss *c);
/* Dequeue one frame: -EAGAIN when none is ready. The frame stays owned by the
 * caller until ir_camss_queue(). */
int ir_camss_dequeue(struct ir_camss *c, unsigned *index, const uint8_t **data,
		     size_t *bytesused, int *error);
int ir_camss_queue(struct ir_camss *c, unsigned index);
/* VIDIOC_STREAMOFF (the sensor powers down). Safe to call twice. */
void ir_camss_stop(struct ir_camss *c);
/* Unmap, disable the links we enabled, close all descriptors. */
void ir_camss_close(struct ir_camss *c);

#endif
