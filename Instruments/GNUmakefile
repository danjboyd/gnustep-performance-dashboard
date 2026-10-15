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

Instruments_RESOURCE_FILES = \
  Resources/Instruments.png \
  ../Runtime/obj/libgsperf-agent.so \
  ../Tools/gstrace-helper/gstrace-helper \
  ../Tools/gstrace-helper/org.gnustep.instruments.policy

Instruments_MAIN_MODEL_FILE =
Instruments_APPLICATION_ICON = Instruments.png

ADDITIONAL_OBJCFLAGS += -fobjc-arc -Wall -Wno-deprecated-declarations -Wno-protocol
ADDITIONAL_INCLUDE_DIRS += -I../Runtime/include -I..
ADDITIONAL_LIB_DIRS += -L../GSPerformance/obj
ADDITIONAL_GUI_LIBS += -lGSPerformance
ADDITIONAL_LDFLAGS += -Wl,-rpath,'$$ORIGIN/../../GSPerformance/obj'

include $(GNUSTEP_MAKEFILES)/application.make
