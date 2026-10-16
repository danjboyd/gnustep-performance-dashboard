include $(GNUSTEP_MAKEFILES)/common.make

TOOL_NAME = gstrace
gstrace_OBJC_FILES = main.m

ADDITIONAL_OBJCFLAGS += -fobjc-arc -Wall
ADDITIONAL_INCLUDE_DIRS += -I../../Runtime/include -I../..
ADDITIONAL_LIB_DIRS += -L../../GSPerformance/obj
ADDITIONAL_TOOL_LIBS += -lGSPerformance
ifeq (,$(findstring mingw,$(GNUSTEP_HOST_OS))$(findstring windows,$(GNUSTEP_HOST_OS)))
ADDITIONAL_LDFLAGS += -Wl,-rpath,'$$ORIGIN/../../../GSPerformance/obj'
endif

include $(GNUSTEP_MAKEFILES)/tool.make
