include $(GNUSTEP_MAKEFILES)/common.make

APP_NAME = Instruments
Instruments_OBJC_FILES = \
  main.m \
  INAppController.m \
  INTraceWindowController.m \
  INTimelineView.m \
  INTrackRenderer.m \
  INDetailController.m \
  INInspectorView.m \
  INRecordPanel.m \
  INTheme.m

WINDOWS = $(findstring mingw,$(GNUSTEP_HOST_OS))$(findstring windows,$(GNUSTEP_HOST_OS))

Instruments_RESOURCE_FILES = Resources/Instruments.png
ifneq (,$(WINDOWS))
Instruments_RESOURCE_FILES += ../Runtime/obj/gsperf-agent.dll
else
Instruments_RESOURCE_FILES += \
  ../Runtime/obj/libgsperf-agent.so \
  ../Tools/gstrace-helper/gstrace-helper \
  ../Tools/gstrace-helper/org.gnustep.instruments.policy
endif

Instruments_MAIN_MODEL_FILE =
Instruments_APPLICATION_ICON = Instruments.png

ADDITIONAL_OBJCFLAGS += -fobjc-arc -Wall -Wno-deprecated-declarations -Wno-protocol
ADDITIONAL_INCLUDE_DIRS += -I../Runtime/include -I..
ADDITIONAL_LIB_DIRS += -L../GSPerformance/obj
ADDITIONAL_GUI_LIBS += -lGSPerformance
ifeq (,$(WINDOWS))
ADDITIONAL_LDFLAGS += -Wl,-rpath,'$$ORIGIN/../../GSPerformance/obj'
endif

include $(GNUSTEP_MAKEFILES)/application.make
