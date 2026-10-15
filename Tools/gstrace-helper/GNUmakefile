# gstrace-helper: small, dependency-free C program run as root via pkexec.

CC ?= cc
CFLAGS ?= -O2 -g
ALL_CFLAGS = $(CFLAGS) -std=gnu11 -Wall -Wextra -Wno-unused-parameter \
  -D_FORTIFY_SOURCE=2 -fstack-protector-strong -fPIE -I../../Runtime/include
PREFIX ?= /usr/local

all: gstrace-helper

gstrace-helper: gstrace-helper.c ../../Runtime/include/GSPerformance/gsp_format.h
	$(CC) $(ALL_CFLAGS) -pie -Wl,-z,relro,-z,now -o $@ gstrace-helper.c

# Installs a copy for `gstrace install-helper` to stage from; the root-owned
# copy in /usr/local/libexec is installed by `gstrace install-helper`.
install: all
	install -d $(DESTDIR)$(PREFIX)/libexec/gnustep-instruments \
	  $(DESTDIR)$(PREFIX)/share/polkit-1/actions
	install -m 755 gstrace-helper $(DESTDIR)$(PREFIX)/libexec/gnustep-instruments/
	install -m 644 org.gnustep.instruments.policy \
	  $(DESTDIR)$(PREFIX)/libexec/gnustep-instruments/

clean:
	rm -f gstrace-helper

.PHONY: all install clean
