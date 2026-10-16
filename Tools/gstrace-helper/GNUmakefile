# gstrace-helper: small, dependency-free C program run as root via pkexec.

CC ?= cc
CFLAGS ?= -O2 -g
ALL_CFLAGS = $(CFLAGS) -std=gnu11 -Wall -Wextra -Wno-unused-parameter \
  -D_FORTIFY_SOURCE=2 -fstack-protector-strong -fPIE -I../../Runtime/include
# Staged next to the GNUstep libraries, where Performance Dashboard and
# `gstrace install-helper` look for it.  The root-owned copy in
# /usr/local/libexec is made by `gstrace install-helper`.
GNUSTEP_LIBS_DIR ?= $(shell gnustep-config --variable=GNUSTEP_LOCAL_LIBRARIES 2>/dev/null || echo /usr/local/lib)
HELPER_DIR ?= $(GNUSTEP_LIBS_DIR)/../libexec/performance-dashboard

all: gstrace-helper

gstrace-helper: gstrace-helper.c ../../Runtime/include/GSPerformance/gsp_format.h
	$(CC) $(ALL_CFLAGS) -pie -Wl,-z,relro,-z,now -o $@ gstrace-helper.c

install: all
	install -d $(DESTDIR)$(HELPER_DIR)
	install -m 755 gstrace-helper $(DESTDIR)$(HELPER_DIR)/
	install -m 644 org.gnustep.performancedashboard.policy $(DESTDIR)$(HELPER_DIR)/

clean:
	rm -f gstrace-helper

.PHONY: all install clean
