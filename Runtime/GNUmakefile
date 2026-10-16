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

UNAME := $(shell uname -s 2>/dev/null)
WINDOWS := $(findstring MINGW,$(UNAME))$(findstring MSYS,$(UNAME))

$(OBJDIR):
	mkdir -p $(OBJDIR)

ifneq (,$(WINDOWS))
ifeq ($(origin CC),default)
CC = clang
endif
# Windows: gsperf-agent.dll (injected by the recorder) and gsperf.dll with
# its import library for applications that emit signposts.
all: $(OBJDIR)/gsperf-agent.dll $(OBJDIR)/gsperf.dll

$(OBJDIR)/gsperf-agent.dll: win/gsp_agent_win.c include/GSPerformance/gsp_format.h | $(OBJDIR)
	$(CC) $(CFLAGS) -std=gnu11 -Wall -Wno-unused-parameter -Iinclude -shared \
	  -o $@ win/gsp_agent_win.c -lwinmm

$(OBJDIR)/gsperf.dll: gsp_signpost_api.c include/GSPerformance/gsp_signpost.h | $(OBJDIR)
	$(CC) $(CFLAGS) -std=gnu11 -Wall -Iinclude -DGSP_BUILDING_API -shared \
	  -o $@ gsp_signpost_api.c -Wl,--out-implib,$(OBJDIR)/libgsperf.dll.a -lpthread

install: all
	install -d $(DESTDIR)$(PREFIX) $(DESTDIR)$(HEADER_PREFIX)/GSPerformance \
	  $(DESTDIR)$(HEADER_PREFIX)/os
	install -m 755 $(OBJDIR)/gsperf-agent.dll $(OBJDIR)/gsperf.dll $(DESTDIR)$(PREFIX)/
	install -m 644 $(OBJDIR)/libgsperf.dll.a $(DESTDIR)$(PREFIX)/
	install -m 644 include/GSPerformance/*.h $(DESTDIR)$(HEADER_PREFIX)/GSPerformance/
	install -m 644 include/os/*.h $(DESTDIR)$(HEADER_PREFIX)/os/
else
all: $(OBJDIR)/libgsperf-agent.so $(OBJDIR)/libgsperf.so

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

endif

clean:
	rm -rf $(OBJDIR)

.PHONY: all install clean
