# SPDX-License-Identifier: GPL-2.0
ARCH ?= arm64
CROSS_COMPILE ?= aarch64-linux-gnu-
CC := $(CROSS_COMPILE)gcc
CFLAGS := -O2 -Wall -Wextra -Werror
LDFLAGS := -static

.PHONY: all clean
all: scx_simple

scx_simple: scx_simple.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

clean:
	rm -f scx_simple
