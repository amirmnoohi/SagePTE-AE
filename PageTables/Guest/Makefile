obj-m += dump_pagetables.o

KDIR ?= /lib/modules/$(shell uname -r)/build

# Compile with the same gcc the running kernel was built with, when that
# compiler is installed. The artifact registers gcc-7 as the default
# alternative because DynamoRIO needs it, so a plain `make` here would
# otherwise build this module with a different compiler than the kernel it
# loads into. An explicit `make CC=...` wins: a command-line variable reaches
# kbuild's sub-make by itself, so this only fills in the default.
#
# The parentheses in the sed script below are balanced on purpose. make scans
# $(shell ...) by counting them, so an unbalanced ")" -- which "[^)]" would
# introduce -- truncates the command and silently yields nonsense.
ifeq ($(origin CC),default)
KERNEL_GCC_MAJOR := $(shell sed -n 's/.*gcc (\([^,]*\)) \([0-9][0-9]*\).*/\2/p' /proc/version | head -1)
KERNEL_GCC       := $(firstword $(wildcard /usr/bin/gcc-$(KERNEL_GCC_MAJOR)))
CC_ARG           := $(if $(KERNEL_GCC),CC=$(KERNEL_GCC))
endif

# CURDIR, not PWD: make inherits PWD from the environment and never updates it,
# so `make -C PageTables/Guest` would point kbuild's M= at the caller's
# directory instead of this one. CURDIR is make's own, and is always this
# directory. (Host/Makefile solves the same problem with PWD := $(shell pwd).)
all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) $(CC_ARG) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
