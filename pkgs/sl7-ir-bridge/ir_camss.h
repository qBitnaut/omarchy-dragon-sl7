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
 * vd55g sensor -> msm_csiphy0 -> msm_csidN -> msm_vfeM_rdi0 -> video node,
 * by default csid1 / vfe1 (libcamera's RGB route is csid0 / vfe0; csid2+ and
 * vfe2+ are lite blocks that deliver no frames). Nothing
 * outside this path is touched (no media-ctl -r equivalent). */
struct ir_camss {
	int media_fd;
	int video_fd;
	char media_path[128];
	char video_path[128];
	char sensor_node[128]; /* the sensor subdev, for the emitter hook */
	char csid_name[32];    /* the route in use, for the log */
	char rdi_name[32];
	unsigned width, height, stride, sizeimage;
	struct ir_hop hops[IR_MAX_HOPS];
	unsigned nhops;
	void *map[IR_NBUF];
	size_t maplen[IR_NBUF];
	unsigned nbuf;
	int streaming;
};

void ir_camss_init(struct ir_camss *c);
/* Set the preferred CSID and VFE RDI entity (IR_CSID, IR_VFE_RDI): a full
 * entity name, or just the number. NULL or empty keeps the default
 * (msm_csid1, msm_vfe1_rdi0). If the route is taken by another camera, the
 * next free CSID/VFE combination is used. */
void ir_camss_configure(const char *csid, const char *rdi);
/* The route of c (still open or just closed) set up but delivered no frames:
 * never pick it again until the daemon restarts, and log a WARN naming it. */
void ir_camss_mark_bad(const struct ir_camss *c);
/* Find the CAMSS media device, enable the IR links, set Y8_1X8 w x h on every
 * pad of the path, set GREY on the video node and map the buffers.
 * 0 or -errno (a message is logged). */
int ir_camss_open(struct ir_camss *c, unsigned w, unsigned h);
/* At daemon start: disable the IR path links an earlier run left enabled (a
 * killed bridge never undid them): links whose source is the IR sensor's
 * CSIPHY, and the CSID -> VFE links of a CSID that CSIPHY feeds. Links that
 * are in use stay; the RGB camera's links are never touched. Returns the
 * number released, or -errno. */
int ir_camss_release_stale(void);
/* After a link enable kept failing with EBUSY: list the processes that hold
 * the IR path's device nodes open (the video node, the sensor and the CSID/VFE
 * subdevs) or the CAMSS media device, found by scanning /proc/<pid>/fd. One
 * line per holder is appended to out (NUL terminated, truncated to len). Needs
 * CAP_SYS_PTRACE and CAP_DAC_READ_SEARCH to see other users' processes; the
 * ones it could not inspect are counted in the last line. Returns the number
 * of holders, or -errno when the IR path could not be resolved. */
int ir_camss_find_holders(char *out, size_t len);
/* List the other processes that hold the device node `node` open (found by
 * scanning /proc/<pid>/fd; this process is skipped). One line per holder is
 * appended to out (NUL terminated, truncated to len): pid, comm, uid and the
 * access mode of the descriptor. Needs CAP_SYS_PTRACE and CAP_DAC_READ_SEARCH
 * to see other users' processes. Returns the number of holders, or -errno. */
int ir_find_node_holders(const char *node, char *out, size_t len);
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
