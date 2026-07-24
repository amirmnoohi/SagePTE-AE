# =============================================================================
#  SagePTE Artifact — Host page-table tooling
# =============================================================================
#
#  Two components live here, and the pipeline needs both:
#
#    host_gpa_translator.ko   kernel module — walks QEMU's page tables to
#                             resolve guest-physical -> host-physical
#    host_pt_augmentor        userspace — turns the module's raw output into
#                             the form the simulator can load (fills NAN
#                             fields, writes the record-count header)
#
#  `make` builds both. run.sh builds them on demand, so this is normally
#  invoked indirectly.
#
#  The kernel module requires Linux >= 6.1: it uses the maple-tree VMA
#  iterators (VMA_ITERATOR / for_each_vma) introduced in that release, and the
#  matching kernel headers must be installed.
# =============================================================================

obj-m += host_gpa_translator.o

KDIR := /lib/modules/$(shell uname -r)/build
PWD  := $(shell pwd)

# Compile the module with the same gcc the running kernel was built with, when
# that compiler is installed: the artifact registers gcc-7 as the default
# alternative for DynamoRIO's sake, which would otherwise build this module
# with a different compiler than the kernel it loads into. An explicit
# `make CC=...` wins, reaching kbuild's sub-make on its own.
#
# The parentheses in the sed script are balanced on purpose: make scans
# $(shell ...) by counting them, so an unbalanced ")" truncates the command.
ifeq ($(origin CC),default)
KERNEL_GCC_MAJOR := $(shell sed -n 's/.*gcc (\([^,]*\)) \([0-9][0-9]*\).*/\2/p' /proc/version | head -1)
KERNEL_GCC       := $(firstword $(wildcard /usr/bin/gcc-$(KERNEL_GCC_MAJOR)))
CC_ARG           := $(if $(KERNEL_GCC),CC=$(KERNEL_GCC))
endif

AUGMENTOR     := host_pt_augmentor
AUGMENTOR_SRC := host_pt_augmentor.c
# Deliberately not named CC/CFLAGS: kbuild manages its own toolchain settings,
# and exporting those names from a module Makefile interferes with it.
AUG_CC        ?= gcc
AUG_CFLAGS    ?= -Wall -Wextra -O2 -std=c11

.PHONY: all module augmentor clean install uninstall reload

all: module augmentor

module:
	$(MAKE) -C $(KDIR) M=$(PWD) $(CC_ARG) modules

augmentor: $(AUGMENTOR)

$(AUGMENTOR): $(AUGMENTOR_SRC)
	$(AUG_CC) $(AUG_CFLAGS) -o $@ $<

clean:
	-$(MAKE) -C $(KDIR) M=$(PWD) clean
	rm -f $(AUGMENTOR)

install:
	sudo insmod host_gpa_translator.ko

uninstall:
	sudo rmmod host_gpa_translator

reload: uninstall install
