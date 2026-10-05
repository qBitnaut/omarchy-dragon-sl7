/* SPDX-License-Identifier: MIT */
#define _GNU_SOURCE
#include "ir_common.h"

#include <dirent.h>
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

void ir_log(int prio, const char *fmt, ...)
{
	static int init, prefix, debug;
	va_list ap;

	if (!init) {
		init = 1;
		prefix = !isatty(STDERR_FILENO); /* journald priority prefix */
		debug = getenv("SL7_IR_DEBUG") != NULL;
	}
	if (prio >= IR_LOG_DEBUG && !debug)
		return;
	if (prefix)
		fprintf(stderr, "<%d>", prio);
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fputc('\n', stderr);
	fflush(stderr);
}

int64_t ir_now_ms(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

int ir_ioctl(int fd, unsigned long req, void *arg)
{
	int r;

	do {
		r = ioctl(fd, req, arg);
	} while (r < 0 && errno == EINTR);
	return r;
}

int ir_find_loopback(const char *card, char *path, size_t len)
{
	DIR *d = opendir("/sys/class/video4linux");
	struct dirent *e;
	int found = -1;

	if (!d)
		return -1;
	while (found < 0 && (e = readdir(d)) != NULL) {
		char p[320], name[64];
		FILE *f;

		if (strncmp(e->d_name, "video", 5) != 0)
			continue;
		snprintf(p, sizeof(p), "/sys/class/video4linux/%s/name", e->d_name);
		f = fopen(p, "re");
		if (!f)
			continue;
		if (fgets(name, sizeof(name), f)) {
			name[strcspn(name, "\n")] = 0;
			if (strcmp(name, card) == 0) {
				snprintf(path, len, "/dev/%s", e->d_name);
				found = 0;
			}
		}
		fclose(f);
	}
	closedir(d);
	return found;
}
