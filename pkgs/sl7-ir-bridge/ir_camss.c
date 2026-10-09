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
/* Default IR route. libcamera's simple pipeline takes the first route for the
 * RGB camera (msm_csiphy4 -> msm_csid0 -> msm_vfe0_rdi0) and keeps it enabled
 * while the session runs, so the IR path uses the other FULL block pair,
 * msm_csid1 -> msm_vfe1_rdi0 (verified on the SL7: 18.6 fps). CSID/VFE 2 and
 * up are LITE blocks that set up fine but deliver no frames for this sensor,
 * so they are the last resort. IR_CSID and IR_VFE_RDI in
 * /etc/sl7-ir-bridge.conf override the default. */
#define DEFAULT_IR_CSID "msm_csid1"
#define DEFAULT_IR_RDI "msm_vfe1_rdi0"
#define NAME_LEN 32
#define MAX_ROUTES 32
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

/* One candidate IR route: the CSID and the VFE RDI entity the path may use. */
struct route {
	char csid[NAME_LEN];
	char rdi[NAME_LEN];
};

static struct route pref = { DEFAULT_IR_CSID, DEFAULT_IR_RDI };

/* Accepts "msm_csid2", "csid2" or "2" (the bare number) for the CSID, and
 * "msm_vfe2_rdi0", "vfe2_rdi0" or "2" (rdi0 of that VFE) for the RDI. */
static int normalize_name(const char *in, const char *pre, const char *bare_fmt, char *out)
{
	char tmp[NAME_LEN];
	size_t i, n;

	if (!in || !*in)
		return 0;
	n = strlen(in);
	if (n >= sizeof(tmp) - 8)
		return -1;
	for (i = 0; i < n; i++)
		if (!((in[i] >= '0' && in[i] <= '9') || (in[i] >= 'a' && in[i] <= 'z') ||
		      in[i] == '_'))
			return -1;
	if (in[0] >= '0' && in[0] <= '9') {
		for (i = 0; i < n; i++)
			if (in[i] < '0' || in[i] > '9')
				return -1;
		snprintf(tmp, sizeof(tmp), bare_fmt, in);
	} else if (!strncmp(in, "msm_", 4)) {
		snprintf(tmp, sizeof(tmp), "%s", in);
	} else {
		snprintf(tmp, sizeof(tmp), "msm_%s", in);
	}
	if (strncmp(tmp, pre, strlen(pre)) != 0)
		return -1;
	snprintf(out, NAME_LEN, "%s", tmp);
	return 1;
}

void ir_camss_configure(const char *csid, const char *rdi)
{
	char tmp[NAME_LEN];
	int r;

	r = normalize_name(csid, "msm_csid", "msm_csid%s", tmp);
	if (r > 0)
		snprintf(pref.csid, sizeof(pref.csid), "%s", tmp);
	else if (r < 0)
		ir_log(IR_LOG_WARN, "IR_CSID=%s is not a CSID entity name, using %s", csid, pref.csid);
	r = normalize_name(rdi, "msm_vfe", "msm_vfe%s_rdi0", tmp);
	if (r > 0)
		snprintf(pref.rdi, sizeof(pref.rdi), "%s", tmp);
	else if (r < 0)
		ir_log(IR_LOG_WARN, "IR_VFE_RDI=%s is not a VFE RDI entity name, using %s", rdi,
		       pref.rdi);
}

/* The CSID and VFE entities other than the route's are off limits. */
static int entity_usable(const struct media_v2_entity *e, const struct route *r)
{
	if (is_video_entity(e))
		return 1;
	if (!strncmp(e->name, "msm_csid", 8))
		return !strcmp(e->name, r->csid);
	if (!strncmp(e->name, "msm_vfe", 7))
		return !strcmp(e->name, r->rdi);
	return 1;
}

static const struct media_v2_entity *ent_by_name(const struct topo *t, const char *name)
{
	unsigned i;

	for (i = 0; i < t->nents; i++)
		if (!strcmp(t->ents[i].name, name))
			return &t->ents[i];
	return NULL;
}

/* The sensor entity and the CSIPHY its data link leads to. 0 or -ENOENT. */
static int find_sensor(const struct topo *t, uint32_t *sensor_id, uint32_t *phy_id)
{
	unsigned i, k;

	for (i = 0; i < t->nents; i++) {
		if (strncmp(t->ents[i].name, SENSOR_PREFIX, strlen(SENSOR_PREFIX)) != 0)
			continue;
		for (k = 0; k < t->nlinks; k++) {
			const struct media_v2_link *l = &t->links[k];
			const struct media_v2_pad *sp, *dp;

			if (!is_data_link(l))
				continue;
			sp = pad_by_id(t, l->source_id);
			dp = pad_by_id(t, l->sink_id);
			if (!sp || !dp || sp->entity_id != t->ents[i].id)
				continue;
			*sensor_id = t->ents[i].id;
			*phy_id = dp->entity_id;
			return 0;
		}
	}
	return -ENOENT;
}

/* Is the route free of anybody else's enabled links? Looks at the CSID's sink
 * and source links and at the RDI's sink. Links from the sensor's own CSIPHY
 * are ours. Never true for a CSID libcamera has wired to the RGB camera. */
static int route_free(const struct topo *t, uint32_t phy_id, const struct route *r)
{
	const struct media_v2_entity *csid = ent_by_name(t, r->csid);
	const struct media_v2_entity *rdi = ent_by_name(t, r->rdi);
	uint32_t sink_src = 0;
	unsigned k;

	if (!csid || !rdi)
		return 0;
	for (k = 0; k < t->nlinks; k++) {
		const struct media_v2_link *l = &t->links[k];
		const struct media_v2_pad *sp, *dp;

		if (!is_data_link(l) || !(l->flags & MEDIA_LNK_FL_ENABLED))
			continue;
		sp = pad_by_id(t, l->source_id);
		dp = pad_by_id(t, l->sink_id);
		if (sp && dp && dp->entity_id == csid->id)
			sink_src = sp->entity_id;
	}
	if (sink_src && sink_src != phy_id)
		return 0;
	for (k = 0; k < t->nlinks; k++) {
		const struct media_v2_link *l = &t->links[k];
		const struct media_v2_pad *sp, *dp;

		if (!is_data_link(l) || !(l->flags & MEDIA_LNK_FL_ENABLED))
			continue;
		sp = pad_by_id(t, l->source_id);
		dp = pad_by_id(t, l->sink_id);
		if (!sp || !dp)
			continue;
		/* the CSID feeding some other VFE, with a source we do not own */
		if (sp->entity_id == csid->id && dp->entity_id != rdi->id && !sink_src)
			return 0;
		/* another CSID already feeding this RDI */
		if (dp->entity_id == rdi->id && sp->entity_id != csid->id)
			return 0;
	}
	return 1;
}

static unsigned name_index(const char *name, const char *fmt)
{
	unsigned n = 0;

	return sscanf(name, fmt, &n) == 1 ? n : 0;
}

/* Routes that set up but delivered no frames, bad for the life of the daemon. */
static struct route bad_routes[MAX_ROUTES];
static unsigned n_bad;

static int route_is_bad(const struct route *r)
{
	unsigned i;

	for (i = 0; i < n_bad; i++)
		if (!strcmp(bad_routes[i].csid, r->csid) && !strcmp(bad_routes[i].rdi, r->rdi))
			return 1;
	return 0;
}

void ir_camss_mark_bad(const struct ir_camss *c)
{
	struct route r;

	if (!c->csid_name[0] || !c->rdi_name[0])
		return;
	snprintf(r.csid, NAME_LEN, "%s", c->csid_name);
	snprintf(r.rdi, NAME_LEN, "%s", c->rdi_name);
	if (route_is_bad(&r) || n_bad >= MAX_ROUTES)
		return;
	bad_routes[n_bad++] = r;
	ir_log(IR_LOG_WARN, "IR route %s / %s delivered no frames, marked bad until the daemon "
	       "restarts; the next session uses the next candidate", r.csid, r.rdi);
}

/* Preference of a CSID or VFE index: 1 is the IR camera's FULL block, 0 the
 * other FULL block (libcamera's RGB camera, usable only if free), everything
 * else is a LITE block, a last resort that has not delivered frames. */
static unsigned block_rank(unsigned idx)
{
	return idx == 1 ? 0 : idx == 0 ? 1 : 2;
}

static unsigned route_rank(const struct route *r)
{
	return block_rank(name_index(r->csid, "msm_csid%u")) +
	       block_rank(name_index(r->rdi, "msm_vfe%u"));
}

/* Candidate routes: the configured one first, then every other CSID x VFE
 * combination, best rank first (csid1/vfe1, then the full csid0/vfe0, then the
 * lite blocks last), higher numbers first within a rank. Routes marked bad are
 * left out, unless that would leave none: then the configured route and the
 * rest are tried again. The RDI suffix of the configured name (e.g. "_rdi0")
 * is kept. */
static unsigned build_routes(const struct topo *t, struct route *out, unsigned max)
{
	unsigned csids[16], vfes[16], nc = 0, nv = 0, i, j, n = 0, k;
	struct route all[MAX_ROUTES];
	unsigned na = 0, nonbad = 0;
	char suffix[NAME_LEN] = "";
	unsigned pv = 0;
	int have_suffix = sscanf(pref.rdi, "msm_vfe%u_%15s", &pv, suffix) == 2;

	snprintf(all[na].csid, NAME_LEN, "%s", pref.csid);
	snprintf(all[na].rdi, NAME_LEN, "%s", pref.rdi);
	na++;
	if (have_suffix) {
		for (i = 0; i < t->nents && (nc < 16 || nv < 16); i++) {
			const char *nm = t->ents[i].name;
			char suf[NAME_LEN];
			unsigned v;

			if (!strncmp(nm, "msm_csid", 8) && nc < 16) {
				csids[nc++] = name_index(nm, "msm_csid%u");
			} else if (sscanf(nm, "msm_vfe%u_%15s", &v, suf) == 2 &&
				   !strcmp(suf, suffix) && nv < 16) {
				vfes[nv++] = v;
			}
		}
		for (i = 0; i < nv; i++) {
			for (j = 0; j < nc && na < MAX_ROUTES; j++) {
				struct route r;

				snprintf(r.csid, NAME_LEN, "msm_csid%u", csids[j]);
				snprintf(r.rdi, NAME_LEN, "msm_vfe%u_%s", vfes[i], suffix);
				if (!strcmp(r.csid, pref.csid) && !strcmp(r.rdi, pref.rdi))
					continue;
				all[na++] = r;
			}
		}
	}
	/* stable insertion sort of everything after the configured route: rank
	 * ascending, then higher VFE, then higher CSID */
	for (i = 2; i < na; i++) {
		struct route x = all[i];
		unsigned rx = route_rank(&x);

		for (j = i; j > 1; j--) {
			unsigned rj = route_rank(&all[j - 1]);
			int swap = rx < rj;

			if (rx == rj) {
				unsigned vx = name_index(x.rdi, "msm_vfe%u");
				unsigned vj = name_index(all[j - 1].rdi, "msm_vfe%u");

				swap = vx > vj || (vx == vj && name_index(x.csid, "msm_csid%u") >
						   name_index(all[j - 1].csid, "msm_csid%u"));
			}
			if (!swap)
				break;
			all[j] = all[j - 1];
		}
		all[j] = x;
	}
	for (k = 0; k < na; k++)
		if (!route_is_bad(&all[k]))
			nonbad++;
	for (k = 0; k < na && n < max; k++)
		if (!nonbad || !route_is_bad(&all[k]))
			out[n++] = all[k];
	return n;
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
static int plan_path(const struct topo *t, struct ir_camss *c, const struct route *rt,
		     uint32_t *video_ent, uint32_t *sensor_ent)
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
			if (!de || !entity_usable(de, rt))
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
		       rt->csid, rt->rdi);
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

/* Drop everything a failed route attempt set up (buffers, video node, links
 * this session enabled), keeping the media device open for the next route. */
static void route_reset(struct ir_camss *c)
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
			if (c->hops[i].we_enabled && setup_link(c->media_fd, &c->hops[i], 0) < 0)
				ir_log(IR_LOG_DEBUG, "could not disable link %u", i);
		}
	}
	memset(c->map, 0, sizeof(c->map));
	memset(c->maplen, 0, sizeof(c->maplen));
	memset(c->hops, 0, sizeof(c->hops));
	c->nbuf = 0;
	c->nhops = 0;
	c->video_fd = -1;
	c->streaming = 0;
}

/* Plan, enable and configure one route. On failure the route is undone. */
static int route_open(struct ir_camss *c, const struct topo *t, const struct route *rt,
		      unsigned w, unsigned h)
{
	uint32_t video_ent = 0, sensor_ent = 0;
	unsigned i;
	int rc, tries;

	rc = plan_path(t, c, rt, &video_ent, &sensor_ent);
	if (rc < 0)
		return rc;
	if (entity_devnode(t, video_ent, c->video_path, sizeof(c->video_path)) < 0 ||
	    entity_devnode(t, sensor_ent, c->sensor_node, sizeof(c->sensor_node)) < 0) {
		ir_log(IR_LOG_ERR, "cannot resolve the video or sensor device node");
		return -ENODEV;
	}
	snprintf(c->csid_name, sizeof(c->csid_name), "%s", rt->csid);
	snprintf(c->rdi_name, sizeof(c->rdi_name), "%s", rt->rdi);

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
			ir_log(IR_LOG_ERR, "enable link %u:%u -> %u:%u (%s via %s): %s", hp->src_ent,
			       hp->src_pad, hp->sink_ent, hp->sink_pad, rt->csid, rt->rdi,
			       strerror(-rc));
			if (rc == -EBUSY)
				ir_log(IR_LOG_ERR,
				       "the IR path is still streaming for another user (a test tool, or a "
				       "consumer that has not finished stopping); links enabled so far are "
				       "released and the session start is retried later");
			goto fail;
		}
		hp->we_enabled = 1;
	}
	/* formats, sensor side first */
	for (i = 0; i < c->nhops; i++) {
		rc = set_pad_format(t, c->hops[i].src_ent, c->hops[i].src_pad, w, h);
		if (rc < 0)
			goto fail;
		rc = set_pad_format(t, c->hops[i].sink_ent, c->hops[i].sink_pad, w, h);
		if (rc < 0)
			goto fail;
	}
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
fail:
	route_reset(c);
	return rc;
}

int ir_camss_open(struct ir_camss *c, unsigned w, unsigned h)
{
	struct topo t;
	struct route routes[MAX_ROUTES];
	uint32_t sensor_id = 0, phy_id = 0;
	unsigned nr, i, skipped = 0;
	int rc = -EBUSY;

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
	if (find_sensor(&t, &sensor_id, &phy_id) < 0) {
		ir_log(IR_LOG_ERR, "no %s* sensor entity in the CAMSS graph", SENSOR_PREFIX);
		rc = -ENOENT;
		goto fail_topo;
	}
	nr = build_routes(&t, routes, MAX_ROUTES);
	rc = -EBUSY;
	for (i = 0; i < nr; i++) {
		if (!route_free(&t, phy_id, &routes[i])) {
			ir_log(IR_LOG_DEBUG, "route %s / %s is not free or not present, skipping",
			       routes[i].csid, routes[i].rdi);
			skipped++;
			continue;
		}
		if (i > 0 || skipped)
			ir_log(IR_LOG_INFO, "IR route: %s via %s (the configured %s / %s is taken)",
			       routes[i].csid, routes[i].rdi, pref.csid, pref.rdi);
		rc = route_open(c, &t, &routes[i], w, h);
		if (rc == 0 || rc == -EBUSY || rc == -ENOMEM)
			break;
		ir_log(IR_LOG_WARN, "route %s / %s failed (%s), trying the next one", routes[i].csid,
		       routes[i].rdi, strerror(-rc));
	}
	if (rc == -EBUSY && skipped == nr)
		ir_log(IR_LOG_ERR, "no free CSID/VFE route for the IR camera: every candidate is "
		       "already wired to another camera (EBUSY)");
	topo_free(&t);
	if (rc < 0)
		goto fail;
	return 0;
fail_topo:
	topo_free(&t);
fail:
	ir_camss_close(c);
	return rc;
}

/* At daemon start: disable links an earlier run left enabled. Only links on
 * the bridge's own path qualify: a link whose source is the IR sensor's
 * CSIPHY, and a CSID -> VFE link of a CSID that CSIPHY feeds. Everything else,
 * the RGB camera's links above all, is left alone. */
int ir_camss_release_stale(void)
{
	struct ir_camss c;
	struct topo t;
	uint32_t sensor_id = 0, phy_id = 0, own_csid[16];
	unsigned i, k, n_own = 0;
	int rc, released = 0, pass;

	ir_camss_init(&c);
	rc = find_camss_media(c.media_path, sizeof(c.media_path));
	if (rc < 0)
		return rc;
	c.media_fd = rc;
	rc = topo_load(c.media_fd, &t);
	if (rc < 0)
		goto out;
	rc = find_sensor(&t, &sensor_id, &phy_id);
	if (rc < 0)
		goto out_topo;
	for (k = 0; k < t.nlinks && n_own < 16; k++) {
		const struct media_v2_link *l = &t.links[k];
		const struct media_v2_pad *sp = pad_by_id(&t, l->source_id);
		const struct media_v2_pad *dp = pad_by_id(&t, l->sink_id);

		if (is_data_link(l) && (l->flags & MEDIA_LNK_FL_ENABLED) && sp && dp &&
		    sp->entity_id == phy_id)
			own_csid[n_own++] = dp->entity_id;
	}
	for (pass = 0; pass < 2; pass++) { /* downstream CSID -> VFE links first */
		for (k = 0; k < t.nlinks; k++) {
			const struct media_v2_link *l = &t.links[k];
			const struct media_v2_pad *sp = pad_by_id(&t, l->source_id);
			const struct media_v2_pad *dp = pad_by_id(&t, l->sink_id);
			struct ir_hop h;
			int ours = 0;

			if (!is_data_link(l) || !sp || !dp || !(l->flags & MEDIA_LNK_FL_ENABLED) ||
			    (l->flags & MEDIA_LNK_FL_IMMUTABLE))
				continue;
			if (pass == 0) {
				for (i = 0; i < n_own; i++)
					if (sp->entity_id == own_csid[i])
						ours = 1;
			} else {
				ours = sp->entity_id == phy_id;
			}
			if (!ours)
				continue;
			memset(&h, 0, sizeof(h));
			h.src_ent = sp->entity_id;
			h.src_pad = sp->index;
			h.sink_ent = dp->entity_id;
			h.sink_pad = dp->index;
			if (setup_link(c.media_fd, &h, 0) == 0)
				released++;
			else
				ir_log(IR_LOG_DEBUG, "stale link %u:%u -> %u:%u not released (in use)",
				       h.src_ent, h.src_pad, h.sink_ent, h.sink_pad);
		}
	}
	if (released)
		ir_log(IR_LOG_INFO, "released %d IR path link(s) left enabled by an earlier run", released);
	rc = released;
out_topo:
	topo_free(&t);
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
	uint32_t video_ent = 0, sensor_ent = 0, phy_id = 0, sensor_id = 0;
	struct route routes[MAX_ROUTES], *rt;
	unsigned nn = 0, i, nr, found = 0, denied = 0;
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
	rc = find_sensor(&t, &sensor_id, &phy_id);
	if (rc == 0) {
		/* the route the bridge would use: the first free one, else the configured */
		nr = build_routes(&t, routes, MAX_ROUTES);
		rt = &routes[0];
		for (i = 0; i < nr; i++)
			if (route_free(&t, phy_id, &routes[i])) {
				rt = &routes[i];
				break;
			}
		rc = plan_path(&t, &c, rt, &video_ent, &sensor_ent);
	}
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

static const char *fd_access(long pid, const char *fdname)
{
	char p[96], line[128];
	FILE *f;
	const char *r = "?";

	snprintf(p, sizeof(p), "/proc/%ld/fdinfo/%.20s", pid, fdname);
	f = fopen(p, "re");
	if (!f)
		return r;
	while (fgets(line, sizeof(line), f)) {
		unsigned long fl;

		if (sscanf(line, "flags: %lo", &fl) == 1) {
			switch (fl & O_ACCMODE) {
			case O_RDONLY: r = "read"; break;
			case O_WRONLY: r = "write"; break;
			default: r = "read/write"; break;
			}
			break;
		}
	}
	fclose(f);
	return r;
}

int ir_find_node_holders(const char *node, char *out, size_t len)
{
	DIR *proc;
	struct dirent *pe;
	size_t used = 0;
	unsigned found = 0, denied = 0;

	if (!node || !out || !len)
		return -EINVAL;
	out[0] = 0;
	proc = opendir("/proc");
	if (!proc)
		return -errno;
	while ((pe = readdir(proc)) != NULL) {
		char *end, p[64], lp[96], tgt[160], comm[32] = "?";
		long pid = strtol(pe->d_name, &end, 10);
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
			struct stat st;
			FILE *f;
			long uid = -1;

			if (fe->d_name[0] == '.')
				continue;
			snprintf(lp, sizeof(lp), "/proc/%ld/fd/%.20s", pid, fe->d_name);
			n = readlink(lp, tgt, sizeof(tgt) - 1);
			if (n <= 0)
				continue;
			tgt[n] = 0;
			if (strcmp(tgt, node) != 0)
				continue;
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
			if (used < len)
				used += (size_t)snprintf(out + used, len - used,
							 "pid %ld (%s) uid %ld holds %s (%s)\n", pid, comm,
							 uid, node, fd_access(pid, fe->d_name));
			found++;
			break; /* one line per process */
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
	route_reset(c);
	if (c->media_fd >= 0)
		close(c->media_fd);
	ir_camss_init(c);
}
