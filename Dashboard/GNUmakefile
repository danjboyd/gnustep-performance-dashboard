include $(GNUSTEP_MAKEFILES)/common.make

APP_NAME = PerformanceDashboard
PerformanceDashboard_OBJC_FILES = \
  main.m \
  PDAppController.m \
  PDTraceWindowController.m \
  PDTimelineView.m \
  PDTrackRenderer.m \
  PDDetailController.m \
  PDInspectorView.m \
  PDRecordPanel.m \
  PDTheme.m

WINDOWS = $(findstring mingw,$(GNUSTEP_HOST_OS))$(findstring windows,$(GNUSTEP_HOST_OS))

PerformanceDashboard_RESOURCE_FILES = Resources/PerformanceDashboard.png
ifneq (,$(WINDOWS))
PerformanceDashboard_RESOURCE_FILES += ../Runtime/obj/gsperf-agent.dll
else
PerformanceDashboard_RESOURCE_FILES += \
  ../Runtime/obj/libgsperf-agent.so \
  ../Tools/gstrace-helper/gstrace-helper \
  ../Tools/gstrace-helper/org.gnustep.performancedashboard.policy
endif

PerformanceDashboard_MAIN_MODEL_FILE =
PerformanceDashboard_APPLICATION_ICON = PerformanceDashboard.png

ADDITIONAL_OBJCFLAGS += -fobjc-arc -Wall -Wno-deprecated-declarations -Wno-protocol
ADDITIONAL_INCLUDE_DIRS += -I../Runtime/include -I..
ADDITIONAL_LIB_DIRS += -L../GSPerformance/obj
ADDITIONAL_GUI_LIBS += -lGSPerformance
ifeq (,$(WINDOWS))
# the build tree, and the packaged layout (app/ next to runtime/lib)
ADDITIONAL_LDFLAGS += -Wl,-rpath,'$$ORIGIN/../../GSPerformance/obj:$$ORIGIN/../../runtime/lib'
endif

include $(GNUSTEP_MAKEFILES)/application.make
