# GNUstep Instruments - top-level build.
#
#   make            build everything
#   make check      build, then run the regression suite
#   make install    install (honours DESTDIR)
#
# Needs a shell where GNUstep.sh has been sourced (GNUSTEP_MAKEFILES set).

# The recording runtime and the privileged helper are Linux-only so far;
# on Windows the framework, gstrace and the app build as a trace viewer.
ifneq (,$(findstring mingw,$(GNUSTEP_HOST_OS))$(findstring windows,$(GNUSTEP_HOST_OS)))
SUBDIRS = GSPerformance Tools/gstrace Instruments
else
SUBDIRS = Runtime GSPerformance Tools/gstrace Tools/gstrace-helper Instruments
endif

all install clean:
	@for d in $(SUBDIRS); do \
	  $(MAKE) -C $$d $@ || exit 1; \
	done

check: all
	sh Tests/run.sh

.PHONY: all install clean check
