obj-m += dump_pagetables.o

KDIR ?= /lib/modules/$(shell uname -r)/build

# CURDIR, not PWD: make inherits PWD from the environment and never updates it,
# so `make -C PageTables/Guest` would point kbuild's M= at the caller's
# directory instead of this one. CURDIR is make's own, and is always this
# directory. (Host/Makefile solves the same problem with PWD := $(shell pwd).)
all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
