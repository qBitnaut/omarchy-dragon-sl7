/* SPDX-License-Identifier: MIT */
#define _GNU_SOURCE
#include "ir_camss.h"
#include "ir_common.h"
#include "ir_repack.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/media-bus-format.h>
#include <linux/media.h>
#include <linux/v4l2-subdev.h>
#include <linux/videodev2.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define SENSOR_PREFIX "vd55g"
/* The only CSID and VFE entities the IR path may use (the RGB camera uses
 * msm_csid1 / msm_vfe1_*). */
#define IR_CSID "msm_csid0"
#define IR_RDI "msm_vfe0_rdi0"
/* Enabling a link fails with EBUSY while a stream still runs through one of its
 * entities: the pipeline of a consumer that was just killed is torn down by the
 * kernel when its descriptors close, which can lag a little. Wait for it. */
#define LINK_BUSY_TRIES 10
#define LINK_BUSY_WAIT_MS 200

struct topo {
	struct media_v2_entity *ents;
	struct media_v2_interface *intfs;
	struct media_v2_pad *pads;
	struct media_v2_link *links;
	unsigned nents, nintfs, npads, nlinks;
};

static void topo_free(struct topo *t)
{
	free(t->ents);
	free(t->intfs);
	free(t->pads);
	free(t->links);
	memset(t, 0, sizeof(*t));
}

static int topo_load(int fd, struct topo *t)
{
	int tries;

	for (tries = 0; tries < 4; tries++) {
		struct media_v2_topology top;

		memset(&top, 0, sizeof(top));
		memset(t, 0, sizeof(*t));
		if (ir_ioctl(fd, MEDIA_IOC_G_TOPOLOGY, &top) < 0)
			return -errno;
		t->nents = top.num_entities;
		t->nintfs = top.num_interfaces;
		t->npads = top.num_pads;
		t->nlinks = top.num_links;
		t->ents = calloc(t->nents + 1, sizeof(*t->ents));
		t->intfs = calloc(t->nintfs + 1, sizeof(*t->intfs));
		t->pads = calloc(t->npads + 1, sizeof(*t->pads));
		t->links = calloc(t->nlinks + 1, sizeof(*t->links));
		if (!t->ents || !t->intfs || !t->pads || !t->links) {
			topo_free(t);
			return -ENOMEM;
		}
		top.ptr_entities = (uintptr_t)t->ents;
		top.ptr_interfaces = (uintptr_t)t->intfs;
		top.ptr_pads = (uintptr_t)t->pads;
		top.ptr_links = (uintptr_t)t->links;
		if (ir_ioctl(fd, MEDIA_IOC_G_TOPOLOGY, &top) < 0) {
			int e = errno;

			topo_free(t);
			return -e;
		}
		if (top.num_entities <= t->nents && top.num_interfaces <= t->nintfs &&
		    top.num_pads <= t->npads && top.num_links <= t->nlinks) {
			t->nents = top.num_entities;
			t->nintfs = top.num_interfaces;
			t->npads = top.num_pads;
			t->nlinks = top.num_links;
			return 0;
		}
		topo_free(t); /* topology changed between the calls: retry */
	}
	return -EAGAIN;
}

static const struct media_v2_entity *ent_by_id(const struct topo *t, uint32_t id)
{
	unsigned i;

	for (i = 0; i < t->nents; i++)
		if (t->ents[i].id == id)
			return &t->ents[i];
	return NULL;
}

static const struct media_v2_pad *pad_by_id(const struct topo *t, uint32_t id)
{
	unsigned i;

	for (i = 0; i < t->npads; i++)
		if (t->pads[i].id == id)
			return &t->pads[i];
	return NULL;
}

static int is_data_link(const struct media_v2_link *l)
{
	return (l->flags & MEDIA_LNK_FL_LINK_TYPE) == MEDIA_LNK_FL_DATA_LINK;
}

static int is_video_entity(const struct media_v2_entity *e)
{
	return e->function == MEDIA_ENT_F_IO_V4L;
}

/* The CSID and VFE entities other than the IR ones are off limits. */
static int entity_usable(const struct media_v2_entity *e)
{
	if (is_video_entity(e))
		return 1;
	if (!strncmp(e->name, "msm_csid", 8))
		return !strcmp(e->name, IR_CSID);
	if (!strncmp(e->name, "msm_vfe", 7))
		return !strcmp(e->name, IR_RDI);
	return 1;
}

/* /dev node of an entity, through its interface link and sysfs. */
static int entity_devnode(const struct topo *t, uint32_t ent_id, char *out, size_t len)
{
	unsigned i, k;

	for (i = 0; i < t->nlinks; i++) {
		const struct media_v2_link *l = &t->links[i];

		if ((l->flags & MEDIA_LNK_FL_LINK_TYPE) != MEDIA_LNK_FL_INTERFACE_LINK ||
		    l->sink_id != ent_id)
			continue;
		for (k = 0; k < t->nintfs; k++) {
			const struct media_v2_interface *in = &t->intfs[k];
			char p[96], line[128];
			FILE *f;
			int ok = -ENODEV;

			if (in->id != l->source_id)
				continue;
			snprintf(p, sizeof(p), "/sys/dev/char/%u:%u/uevent",
				 in->devnode.major, in->devnode.minor);
			f = fopen(p, "re");
			if (!f)
				return -errno;
			while (fgets(line, sizeof(line), f)) {
				if (!strncmp(line, "DEVNAME=", 8)) {
					line[strcspn(line, "\n")] = 0;
					snprintf(out, len, "/dev/%s", line + 8);
					ok = 0;
					break;
				}
			}
			fclose(f);
			return ok;
		}
	}
	return -ENODEV;
}

static int find_camss_media(char *path, size_t len)
{
	DIR *d = opendir("/dev");
	struct dirent *e;
	int fd = -1;

	if (!d)
		return -errno;
	while (fd < 0 && (e = readdir(d)) != NULL) {
		struct media_device_info info;
		char p[128];
		int f;

		if (strncmp(e->d_name, "media", 5) != 0)
			continue;
		snprintf(p, sizeof(p), "/dev/%.100s", e->d_name);
		f = open(p, O_RDWR | O_CLOEXEC);
		if (f < 0)
			continue;
		memset(&info, 0, sizeof(info));
		if (ir_ioctl(f, MEDIA_IOC_DEVICE_INFO, &info) == 0 &&
		    !strcmp(info.driver, "qcom-camss")) {
			fd = f;
			snprintf(path, len, "%s", p);
		} else {
			close(f);
		}
	}
	closedir(d);
	return fd >= 0 ? fd : -ENODEV;
}

/* Breadth-first walk from the sensor over data links to a video node. */
static int plan_path(const struct topo *t, struct ir_camss *c, uint32_t *video_ent,
		     uint32_t *sensor_ent)
{
	int *parent_link = malloc(sizeof(int) * (t->nents + 1));
	int *queue = malloc(sizeof(int) * (t->nents + 1));
	unsigned head = 0, tail = 0, i, k;
	int src = -1, found = -1, rc = -ENOENT;
	struct { int link; int ent; } chain[IR_MAX_HOPS];
	unsigned n = 0;

	if (!parent_link || !queue) {
		free(parent_link);
		free(queue);
		return -ENOMEM;
	}
	for (i = 0; i < t->nents; i++) {
		parent_link[i] = -2; /* unvisited */
		if (src < 0 && !strncmp(t->ents[i].name, SENSOR_PREFIX, strlen(SENSOR_PREFIX)))
			src = (int)i;
	}
	if (src < 0) {
		ir_log(IR_LOG_ERR, "no %s* sensor entity in the CAMSS graph", SENSOR_PREFIX);
		goto out;
	}
	parent_link[src] = -1;
	queue[tail++] = src;
	while (head < tail && found < 0) {
		int cur = queue[head++];

		if (is_video_entity(&t->ents[cur])) {
			found = cur;
			break;
		}
		for (k = 0; k < t->nlinks; k++) {
			const struct media_v2_link *l = &t->links[k];
			const struct media_v2_pad *sp, *dp;
			const struct media_v2_entity *de;
			int di = -1;

			if (!is_data_link(l))
				continue;
			sp = pad_by_id(t, l->source_id);
			dp = pad_by_id(t, l->sink_id);
			if (!sp || !dp || sp->entity_id != t->ents[cur].id)
				continue;
			de = ent_by_id(t, dp->entity_id);
			if (!de || !entity_usable(de))
				continue;
			for (i = 0; i < t->nents; i++)
				if (&t->ents[i] == de)
					di = (int)i;
			if (di < 0 || parent_link[di] != -2)
				continue;
			parent_link[di] = (int)k;
			queue[tail++] = di;
		}
	}
	if (found < 0) {
		ir_log(IR_LOG_ERR, "no path from the IR sensor to a video node (allowed: %s, %s)",
		       IR_CSID, IR_RDI);
		goto out;
	}
	/* walk back from the video node */
	for (i = (unsigned)found; parent_link[i] >= 0;) {
		const struct media_v2_link *l = &t->links[parent_link[i]];
		const struct media_v2_pad *sp = pad_by_id(t, l->source_id);
		unsigned j, prev = 0;

		if (n >= IR_MAX_HOPS) {
			rc = -E2BIG;
			goto out;
		}
		chain[n].link = parent_link[i];
		chain[n].ent = (int)i;
		n++;
		for (j = 0; j < t->nents; j++)
			if (t->ents[j].id == sp->entity_id)
				prev = j;
		i = prev;
	}
	c->nhops = n;
	for (i = 0; i < n; i++) { /* chain is video-first: reverse into hops[] */
		const struct media_v2_link *l = &t->links[chain[n - 1 - i].link];
		const struct media_v2_pad *sp = pad_by_id(t, l->source_id);
		const struct media_v2_pad *dp = pad_by_id(t, l->sink_id);

		c->hops[i].src_ent = sp->entity_id;
		c->hops[i].src_pad = sp->index;
		c->hops[i].sink_ent = dp->entity_id;
		c->hops[i].sink_pad = dp->index;
		c->hops[i].flags = l->flags;
		c->hops[i].we_enabled = 0;
	}
	*video_ent = t->ents[found].id;
	*sensor_ent = t->ents[src].id;
	rc = 0;
out:
	free(parent_link);
	free(queue);
	return rc;
}

static int setup_link(int media_fd, const struct ir_hop *h, int enable)
{
	struct media_link_desc d;

	memset(&d, 0, sizeof(d));
	d.source.entity = h->src_ent;
	d.source.index = h->src_pad;
	d.sink.entity = h->sink_ent;
	d.sink.index = h->sink_pad;
	d.flags = enable ? MEDIA_LNK_FL_ENABLED : 0;
	return ir_ioctl(media_fd, MEDIA_IOC_SETUP_LINK, &d) < 0 ? -errno : 0;
}

static int set_pad_format(const struct topo *t, uint32_t ent_id, uint32_t pad,
			  unsigned w, unsigned h)
{
	const struct media_v2_entity *e = ent_by_id(t, ent_id);
	struct v4l2_subdev_format fmt;
	char node[128];
	int fd, rc;

	if (!e || is_video_entity(e))
		return 0;
	rc = entity_devnode(t, ent_id, node, sizeof(node));
	if (rc < 0) {
		ir_log(IR_LOG_ERR, "%s: no subdev node (%s)", e->name, strerror(-rc));
		return rc;
	}
	fd = open(node, O_RDWR | O_CLOEXEC);
	if (fd < 0) {
		rc = -errno;
		ir_log(IR_LOG_ERR, "open %s: %s", node, strerror(errno));
		return rc;
	}
	memset(&fmt, 0, sizeof(fmt));
	fmt.which = V4L2_SUBDEV_FORMAT_ACTIVE;
	fmt.pad = pad;
	if (ir_ioctl(fd, VIDIOC_SUBDEV_G_FMT, &fmt) < 0) {
		rc = -errno;
		ir_log(IR_LOG_ERR, "%s:%u get format: %s", e->name, pad, strerror(errno));
		close(fd);
		return rc;
	}
	fmt.format.code = MEDIA_BUS_FMT_Y8_1X8;
	fmt.format.width = w;
	fmt.format.height = h;
	if (ir_ioctl(fd, VIDIOC_SUBDEV_S_FMT, &fmt) < 0) {
		rc = -errno;
		ir_log(IR_LOG_ERR, "%s:%u set Y8_1X8/%ux%u: %s", e->name, pad, w, h,
		       strerror(errno));
		close(fd);
		return rc;
	}
	close(fd);
	if (fmt.format.code != MEDIA_BUS_FMT_Y8_1X8 || fmt.format.width != w ||
	    fmt.format.height != h) {
		ir_log(IR_LOG_ERR, "%s:%u took 0x%x/%ux%u instead of Y8_1X8/%ux%u", e->name, pad,
		       fmt.format.code, fmt.format.width, fmt.format.height, w, h);
		return -EINVAL;
	}
	return 0;
}

void ir_camss_init(struct ir_camss *c)
{
	memset(c, 0, sizeof(*c));
	c->media_fd = -1;
	c->video_fd = -1;
}

static int video_setup(struct ir_camss *c, unsigned w, unsigned h)
{
	struct v4l2_capability cap;
	struct v4l2_format f;
	struct v4l2_requestbuffers rb;
	unsigned i;

	memset(&cap, 0, sizeof(cap));
	if (ir_ioctl(c->video_fd, VIDIOC_QUERYCAP, &cap) < 0)
		return -errno;
	if (!((cap.device_caps ? cap.device_caps : cap.capabilities) &
	      V4L2_CAP_VIDEO_CAPTURE_MPLANE)) {
		ir_log(IR_LOG_ERR, "%s is not a multi-planar capture node", c->video_path);
		return -ENODEV;
	}
	memset(&f, 0, sizeof(f));
	f.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
	f.fmt.pix_mp.width = w;
	f.fmt.pix_mp.height = h;
	f.fmt.pix_mp.pixelformat = V4L2_PIX_FMT_GREY;
	f.fmt.pix_mp.field = V4L2_FIELD_NONE;
	f.fmt.pix_mp.num_planes = 1;
	if (ir_ioctl(c->video_fd, VIDIOC_S_FMT, &f) < 0) {
		ir_log(IR_LOG_ERR, "%s: set GREY %ux%u: %s", c->video_path, w, h, strerror(errno));
		return -errno;
	}
	if (f.fmt.pix_mp.pixelformat != V4L2_PIX_FMT_GREY || f.fmt.pix_mp.width != w ||
	    f.fmt.pix_mp.height != h || f.fmt.pix_mp.num_planes != 1) {
		ir_log(IR_LOG_ERR, "%s: driver gave %ux%u, %u plane(s), not GREY %ux%u", c->video_path,
		       f.fmt.pix_mp.width, f.fmt.pix_mp.height, f.fmt.pix_mp.num_planes, w, h);
		return -EINVAL;
	}
	c->width = w;
	c->height = h;
	c->stride = f.fmt.pix_mp.plane_fmt[0].bytesperline;
	c->sizeimage = f.fmt.pix_mp.plane_fmt[0].sizeimage;
	if (c->stride < w || !ir_frame_complete(c->sizeimage, w, h, c->stride)) {
		ir_log(IR_LOG_ERR, "%s: implausible stride %u / sizeimage %u", c->video_path, c->stride,
		       c->sizeimage);
		return -EINVAL;
	}

	memset(&rb, 0, sizeof(rb));
	rb.count = IR_NBUF;
	rb.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
	rb.memory = V4L2_MEMORY_MMAP;
	if (ir_ioctl(c->video_fd, VIDIOC_REQBUFS, &rb) < 0)
		return -errno;
	if (rb.count < 2 || rb.count > IR_NBUF) {
		ir_log(IR_LOG_ERR, "%s: driver granted %u buffers", c->video_path, rb.count);
		return -ENOMEM;
	}
	for (i = 0; i < rb.count; i++) {
		struct v4l2_buffer b;
		struct v4l2_plane pl;
		void *m;

		memset(&b, 0, sizeof(b));
		memset(&pl, 0, sizeof(pl));
		b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
		b.memory = V4L2_MEMORY_MMAP;
		b.index = i;
		b.m.planes = &pl;
		b.length = 1;
		if (ir_ioctl(c->video_fd, VIDIOC_QUERYBUF, &b) < 0)
			return -errno;
		m = mmap(NULL, pl.length, PROT_READ, MAP_SHARED, c->video_fd, pl.m.mem_offset);
		if (m == MAP_FAILED)
			return -errno;
		c->map[i] = m;
		c->maplen[i] = pl.length;
		c->nbuf = i + 1;
	}
	return 0;
}

int ir_camss_open(struct ir_camss *c, unsigned w, unsigned h)
{
	struct topo t;
	uint32_t video_ent = 0, sensor_ent = 0;
	unsigned i;
	int rc, tries;

	rc = find_camss_media(c->media_path, sizeof(c->media_path));
	if (rc < 0) {
		ir_log(IR_LOG_ERR, "no qcom-camss media device (CAMSS not probed?)");
		return rc;
	}
	c->media_fd = rc;
	rc = topo_load(c->media_fd, &t);
	if (rc < 0) {
		ir_log(IR_LOG_ERR, "%s: read topology: %s", c->media_path, strerror(-rc));
		goto fail;
	}
	rc = plan_path(&t, c, &video_ent, &sensor_ent);
	if (rc < 0)
		goto fail_topo;
	if (entity_devnode(&t, video_ent, c->video_path, sizeof(c->video_path)) < 0 ||
	    entity_devnode(&t, sensor_ent, c->sensor_node, sizeof(c->sensor_node)) < 0) {
		ir_log(IR_LOG_ERR, "cannot resolve the video or sensor device node");
		rc = -ENODEV;
		goto fail_topo;
	}

	/* links: only those on the IR path that are not already on */
	for (i = 0; i < c->nhops; i++) {
		struct ir_hop *hp = &c->hops[i];

		if (hp->flags & (MEDIA_LNK_FL_IMMUTABLE | MEDIA_LNK_FL_ENABLED))
			continue;
		rc = setup_link(c->media_fd, hp, 1);
		for (tries = 0; rc == -EBUSY && tries < LINK_BUSY_TRIES; tries++) {
			ir_log(IR_LOG_DEBUG, "link %u:%u -> %u:%u busy, waiting (%d)", hp->src_ent,
			       hp->src_pad, hp->sink_ent, hp->sink_pad, tries + 1);
			usleep(LINK_BUSY_WAIT_MS * 1000);
			rc = setup_link(c->media_fd, hp, 1);
		}
		if (rc < 0) {
			ir_log(IR_LOG_ERR, "enable link %u:%u -> %u:%u: %s", hp->src_ent, hp->src_pad,
			       hp->sink_ent, hp->sink_pad, strerror(-rc));
			if (rc == -EBUSY)
				ir_log(IR_LOG_ERR,
				       "the IR path is still streaming for another user (a test tool, or a "
				       "consumer that has not finished stopping); links enabled so far are "
				       "released and the session start is retried later");
			goto fail_topo;
		}
		hp->we_enabled = 1;
	}
	/* formats, sensor side first */
	for (i = 0; i < c->nhops; i++) {
		rc = set_pad_format(&t, c->hops[i].src_ent, c->hops[i].src_pad, w, h);
		if (rc < 0)
			goto fail_topo;
		rc = set_pad_format(&t, c->hops[i].sink_ent, c->hops[i].sink_pad, w, h);
		if (rc < 0)
			goto fail_topo;
	}
	topo_free(&t);

	c->video_fd = open(c->video_path, O_RDWR | O_NONBLOCK | O_CLOEXEC);
	if (c->video_fd < 0) {
		rc = -errno;
		ir_log(IR_LOG_ERR, "open %s: %s", c->video_path, strerror(errno));
		goto fail;
	}
	rc = video_setup(c, w, h);
	if (rc < 0) {
		ir_log(IR_LOG_ERR, "video node setup failed: %s", strerror(-rc));
		goto fail;
	}
	return 0;
fail_topo:
	topo_free(&t);
fail:
	ir_camss_close(c);
	return rc;
}

int ir_camss_release_stale(void)
{
	struct ir_camss c;
	struct topo t;
	uint32_t video_ent = 0, sensor_ent = 0;
	unsigned i;
	int rc, released = 0;

	ir_camss_init(&c);
	rc = find_camss_media(c.media_path, sizeof(c.media_path));
	if (rc < 0)
		return rc;
	c.media_fd = rc;
	rc = topo_load(c.media_fd, &t);
	if (rc < 0)
		goto out;
	rc = plan_path(&t, &c, &video_ent, &sensor_ent);
	topo_free(&t);
	if (rc < 0)
		goto out;
	for (i = c.nhops; i-- > 0;) {
		const struct ir_hop *hp = &c.hops[i];

		if ((hp->flags & MEDIA_LNK_FL_IMMUTABLE) || !(hp->flags & MEDIA_LNK_FL_ENABLED))
			continue;
		if (setup_link(c.media_fd, hp, 0) == 0)
			released++;
		else
			ir_log(IR_LOG_DEBUG, "stale link %u not released (in use)", i);
	}
	if (released)
		ir_log(IR_LOG_INFO, "released %d IR path link(s) left enabled by an earlier run", released);
	rc = released;
out:
	close(c.media_fd);
	return rc;
}

#define HOLDER_NODES (IR_MAX_HOPS * 2 + 4)

struct holder_node {
	char path[128];
	const char *what;
};

static void holder_add(struct holder_node *n, unsigned *cnt, const char *path, const char *what)
{
	unsigned i;

	for (i = 0; i < *cnt; i++)
		if (!strcmp(n[i].path, path))
			return;
	if (*cnt >= HOLDER_NODES)
		return;
	snprintf(n[*cnt].path, sizeof(n[*cnt].path), "%s", path);
	n[*cnt].what = what;
	(*cnt)++;
}

int ir_camss_find_holders(char *out, size_t len)
{
	struct holder_node nodes[HOLDER_NODES];
	struct ir_camss c;
	struct topo t;
	uint32_t video_ent = 0, sensor_ent = 0;
	unsigned nn = 0, i, found = 0, denied = 0;
	char node[128];
	DIR *proc;
	struct dirent *pe;
	size_t used = 0;
	int rc;

	if (!out || !len)
		return -EINVAL;
	out[0] = 0;
	ir_camss_init(&c);
	rc = find_camss_media(c.media_path, sizeof(c.media_path));
	if (rc < 0)
		return rc;
	c.media_fd = rc;
	rc = topo_load(c.media_fd, &t);
	if (rc < 0) {
		close(c.media_fd);
		return rc;
	}
	rc = plan_path(&t, &c, &video_ent, &sensor_ent);
	if (rc == 0) {
		holder_add(nodes, &nn, c.media_path, "CAMSS media device, shared with the RGB camera");
		if (entity_devnode(&t, video_ent, node, sizeof(node)) == 0)
			holder_add(nodes, &nn, node, "IR video node");
		if (entity_devnode(&t, sensor_ent, node, sizeof(node)) == 0)
			holder_add(nodes, &nn, node, "IR sensor subdev");
		for (i = 0; i < c.nhops; i++) {
			if (entity_devnode(&t, c.hops[i].src_ent, node, sizeof(node)) == 0)
				holder_add(nodes, &nn, node, "IR path subdev");
			if (entity_devnode(&t, c.hops[i].sink_ent, node, sizeof(node)) == 0)
				holder_add(nodes, &nn, node, "IR path subdev");
		}
	}
	topo_free(&t);
	close(c.media_fd);
	if (rc < 0)
		return rc;

	proc = opendir("/proc");
	if (!proc)
		return -errno;
	while ((pe = readdir(proc)) != NULL) {
		char *end, p[64], lp[96], tgt[160], comm[32] = "?";
		long pid = strtol(pe->d_name, &end, 10);
		unsigned mask = 0;
		int have_info = 0;
		long uid = -1;
		DIR *fdd;
		struct dirent *fe;

		if (*end || pid <= 0 || pid == (long)getpid())
			continue;
		snprintf(p, sizeof(p), "/proc/%ld/fd", pid);
		fdd = opendir(p);
		if (!fdd) {
			if (errno == EACCES || errno == EPERM)
				denied++;
			continue;
		}
		while ((fe = readdir(fdd)) != NULL) {
			ssize_t n;

			if (fe->d_name[0] == '.')
				continue;
			snprintf(lp, sizeof(lp), "/proc/%ld/fd/%.20s", pid, fe->d_name);
			n = readlink(lp, tgt, sizeof(tgt) - 1);
			if (n <= 0)
				continue;
			tgt[n] = 0;
			for (i = 0; i < nn; i++) {
				if (strcmp(tgt, nodes[i].path) != 0 || (mask & (1u << i)))
					continue;
				mask |= 1u << i;
				if (!have_info) {
					struct stat st;
					FILE *f;

					have_info = 1;
					snprintf(p, sizeof(p), "/proc/%ld/comm", pid);
					f = fopen(p, "re");
					if (f) {
						if (fgets(comm, sizeof(comm), f))
							comm[strcspn(comm, "\n")] = 0;
						fclose(f);
					}
					snprintf(p, sizeof(p), "/proc/%ld", pid);
					if (stat(p, &st) == 0)
						uid = (long)st.st_uid;
				}
				if (used < len)
					used += (size_t)snprintf(out + used, len - used,
								 "pid %ld (%s) uid %ld holds %s (%s)\n", pid, comm,
								 uid, nodes[i].path, nodes[i].what);
				found++;
			}
		}
		closedir(fdd);
	}
	closedir(proc);
	if (denied && used < len)
		snprintf(out + used, len - used, "%u process(es) could not be inspected\n", denied);
	return (int)found;
}

int ir_camss_queue(struct ir_camss *c, unsigned index)
{
	struct v4l2_buffer b;
	struct v4l2_plane pl;

	memset(&b, 0, sizeof(b));
	memset(&pl, 0, sizeof(pl));
	b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
	b.memory = V4L2_MEMORY_MMAP;
	b.index = index;
	b.m.planes = &pl;
	b.length = 1;
	return ir_ioctl(c->video_fd, VIDIOC_QBUF, &b) < 0 ? -errno : 0;
}

int ir_camss_start(struct ir_camss *c)
{
	int type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
	unsigned i;
	int rc;

	for (i = 0; i < c->nbuf; i++) {
		rc = ir_camss_queue(c, i);
		if (rc < 0)
			return rc;
	}
	if (ir_ioctl(c->video_fd, VIDIOC_STREAMON, &type) < 0) {
		rc = -errno;
		ir_log(IR_LOG_ERR, "STREAMON %s: %s", c->video_path, strerror(errno));
		return rc;
	}
	c->streaming = 1;
	return 0;
}

int ir_camss_dequeue(struct ir_camss *c, unsigned *index, const uint8_t **data,
		     size_t *bytesused, int *error)
{
	struct v4l2_buffer b;
	struct v4l2_plane pl;

	memset(&b, 0, sizeof(b));
	memset(&pl, 0, sizeof(pl));
	b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
	b.memory = V4L2_MEMORY_MMAP;
	b.m.planes = &pl;
	b.length = 1;
	if (ir_ioctl(c->video_fd, VIDIOC_DQBUF, &b) < 0)
		return -errno;
	if (b.index >= c->nbuf)
		return -EIO;
	*index = b.index;
	*data = c->map[b.index];
	*bytesused = pl.bytesused;
	*error = !!(b.flags & V4L2_BUF_FLAG_ERROR);
	return 0;
}

void ir_camss_stop(struct ir_camss *c)
{
	int type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;

	if (c->streaming && c->video_fd >= 0) {
		if (ir_ioctl(c->video_fd, VIDIOC_STREAMOFF, &type) < 0)
			ir_log(IR_LOG_WARN, "STREAMOFF %s: %s", c->video_path, strerror(errno));
	}
	c->streaming = 0;
}

void ir_camss_close(struct ir_camss *c)
{
	unsigned i;

	ir_camss_stop(c);
	for (i = 0; i < c->nbuf; i++)
		if (c->map[i])
			munmap(c->map[i], c->maplen[i]);
	if (c->video_fd >= 0) {
		struct v4l2_requestbuffers rb;

		memset(&rb, 0, sizeof(rb));
		rb.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
		rb.memory = V4L2_MEMORY_MMAP;
		ir_ioctl(c->video_fd, VIDIOC_REQBUFS, &rb);
		close(c->video_fd);
	}
	/* undo only what this session switched on, last link first */
	if (c->media_fd >= 0) {
		for (i = c->nhops; i-- > 0;) {
			if (c->hops[i].we_enabled &&
			    setup_link(c->media_fd, &c->hops[i], 0) < 0)
				ir_log(IR_LOG_DEBUG, "could not disable link %u", i);
		}
		close(c->media_fd);
	}
	ir_camss_init(c);
}
