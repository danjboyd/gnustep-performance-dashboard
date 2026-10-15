# GNUstep Instruments - top-level build.
#
#   make            build everything
#   make check      build, then run the regression suite
#   make install    install (honours DESTDIR)
#
# Needs a shell where GNUstep.sh has been sourced (GNUSTEP_MAKEFILES set).

SUBDIRS = Runtime GSPerformance Tools/gstrace Tools/gstrace-helper Instruments

all install clean:
	@for d in $(SUBDIRS); do \
	  $(MAKE) -C $$d $@ || exit 1; \
	done

check: all
	sh Tests/run.sh

.PHONY: all install clean check
