include $(GNUSTEP_MAKEFILES)/common.make

TOOL_NAME = gstrace
gstrace_OBJC_FILES = main.m

ADDITIONAL_OBJCFLAGS += -fobjc-arc -Wall
ADDITIONAL_INCLUDE_DIRS += -I../../Runtime/include -I../..
ADDITIONAL_LIB_DIRS += -L../../GSPerformance/obj
ADDITIONAL_TOOL_LIBS += -lGSPerformance
ADDITIONAL_LDFLAGS += -Wl,-rpath,'$$ORIGIN/../../../GSPerformance/obj'

include $(GNUSTEP_MAKEFILES)/tool.make
