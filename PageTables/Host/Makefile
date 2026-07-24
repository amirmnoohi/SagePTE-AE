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

AUGMENTOR     := host_pt_augmentor
AUGMENTOR_SRC := host_pt_augmentor.c
# Deliberately not named CC/CFLAGS: kbuild manages its own toolchain settings,
# and exporting those names from a module Makefile interferes with it.
AUG_CC        ?= gcc
AUG_CFLAGS    ?= -Wall -Wextra -O2 -std=c11

.PHONY: all module augmentor clean install uninstall reload

all: module augmentor

module:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

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
