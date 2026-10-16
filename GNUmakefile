# Performance Dashboard - top-level build.
#
#   make            build everything
#   make check      build, then run the regression suite
#   make install    install (honours DESTDIR)
#
# Needs a shell where GNUstep.sh has been sourced (GNUSTEP_MAKEFILES set).

# The privileged helper is Linux-only (perf_event); on Windows the runtime
# builds gsperf-agent.dll and gsperf.dll instead.
UNAME := $(shell uname -s 2>/dev/null)
WINDOWS := $(findstring MINGW,$(UNAME))$(findstring MSYS,$(UNAME))$(findstring mingw,$(GNUSTEP_HOST_OS))$(findstring windows,$(GNUSTEP_HOST_OS))
ifneq (,$(WINDOWS))
SUBDIRS = Runtime GSPerformance Tools/gstrace Dashboard
else
SUBDIRS = Runtime GSPerformance Tools/gstrace Tools/gstrace-helper Dashboard
endif

all install clean:
	@for d in $(SUBDIRS); do \
	  $(MAKE) -C $$d $@ || exit 1; \
	done

check: all
	sh Tests/run.sh

.PHONY: all install clean check
