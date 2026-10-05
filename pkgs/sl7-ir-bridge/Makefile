# SPDX-License-Identifier: MIT
CC ?= cc
CFLAGS ?= -O2 -g
CFLAGS += -std=gnu11 -Wall -Wextra -Wshadow -Wformat=2
PREFIX ?= /usr

OBJS = sl7-ir-bridge.o ir_common.o ir_camss.o ir_emitter.o ir_selftest.o ir_repack.o

all: sl7-ir-bridge

sl7-ir-bridge: $(OBJS)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(OBJS)

%.o: %.c
	$(CC) $(CFLAGS) $(CPPFLAGS) -c -o $@ $<

test_repack: test_repack.c ir_repack.c ir_repack.h
	$(CC) $(CFLAGS) $(CPPFLAGS) $(LDFLAGS) -o $@ test_repack.c ir_repack.c

check: test_repack
	./test_repack

install: sl7-ir-bridge
	install -Dm755 sl7-ir-bridge $(DESTDIR)$(PREFIX)/bin/sl7-ir-bridge

clean:
	rm -f sl7-ir-bridge test_repack *.o

.PHONY: all check install clean
