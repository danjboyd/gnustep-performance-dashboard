# Runtime/GNUmakefile - builds the C runtime libraries.
#
#   libgsperf-agent.so  recording agent, injected with LD_PRELOAD
#   libgsperf.so        signpost / os_log API linked by applications
#
# Both are plain C and depend only on libc (libunwind is loaded with dlopen
# when present).  They deliberately do not use gnustep-make: the agent is
# injected into arbitrary processes and must not link GNUstep or libobjc.

CC ?= cc
OBJDIR = obj
PREFIX ?= $(shell gnustep-config --variable=GNUSTEP_LOCAL_LIBRARIES 2>/dev/null || echo /usr/local/lib)
HEADER_PREFIX ?= $(shell gnustep-config --variable=GNUSTEP_LOCAL_HEADERS 2>/dev/null || echo /usr/local/include)

CFLAGS ?= -O2 -g
ALL_CFLAGS = $(CFLAGS) -std=gnu11 -fPIC -fvisibility=hidden \
  -fno-omit-frame-pointer -Wall -Wextra -Wno-unused-parameter \
  -D_GNU_SOURCE -Iinclude

AGENT_SRCS = gsp_runtime.c gsp_unwind.c gsp_sampler.c gsp_alloc.c \
  gsp_objc.c gsp_leaks.c gsp_signpost_agent.c gsp_io.c
AGENT_OBJS = $(AGENT_SRCS:%.c=$(OBJDIR)/%.o)
API_OBJS = $(OBJDIR)/gsp_signpost_api.o

all: $(OBJDIR)/libgsperf-agent.so $(OBJDIR)/libgsperf.so

$(OBJDIR):
	mkdir -p $(OBJDIR)

$(OBJDIR)/%.o: %.c gsp_internal.h include/GSPerformance/gsp_format.h \
               include/GSPerformance/gsp_signpost.h | $(OBJDIR)
	$(CC) $(ALL_CFLAGS) -c $< -o $@

$(OBJDIR)/libgsperf-agent.so: $(AGENT_OBJS)
	$(CC) -shared -o $@ $(AGENT_OBJS) -Wl,-soname,libgsperf-agent.so \
	  -Wl,-z,nodelete -ldl -lpthread -lrt

$(OBJDIR)/libgsperf.so.0: $(API_OBJS)
	$(CC) -shared -o $@ $(API_OBJS) -Wl,-soname,libgsperf.so.0 -ldl -lpthread

$(OBJDIR)/libgsperf.so: $(OBJDIR)/libgsperf.so.0
	ln -sf libgsperf.so.0 $@

install: all
	install -d $(DESTDIR)$(PREFIX) $(DESTDIR)$(HEADER_PREFIX)/GSPerformance \
	  $(DESTDIR)$(HEADER_PREFIX)/os
	install -m 755 $(OBJDIR)/libgsperf-agent.so $(DESTDIR)$(PREFIX)/
	install -m 755 $(OBJDIR)/libgsperf.so.0 $(DESTDIR)$(PREFIX)/
	ln -sf libgsperf.so.0 $(DESTDIR)$(PREFIX)/libgsperf.so
	install -m 644 include/GSPerformance/*.h \
	  $(DESTDIR)$(HEADER_PREFIX)/GSPerformance/
	install -m 644 include/os/*.h $(DESTDIR)$(HEADER_PREFIX)/os/

clean:
	rm -rf $(OBJDIR)

.PHONY: all install clean
