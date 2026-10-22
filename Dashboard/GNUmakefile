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
  PDSourceWindowController.m \
  PDInvestigationWindowController.m \
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
# main.m keeps a real NSAutoreleasePool at the bottom (see the comment there).
main.m_FILE_FILTER_OUT_FLAGS = -fobjc-arc
ADDITIONAL_INCLUDE_DIRS += -I../Runtime/include -I..
ADDITIONAL_LIB_DIRS += -L../GSPerformance/obj -L../Runtime/obj
ADDITIONAL_GUI_LIBS += -lGSPerformance -lgsperf

# The packaged updater (third_party/gnustep-packager-updater/VENDORED.md):
# GPUpdaterCore and GPUpdaterUI linked in, gp-update-helper in the bundle.
UPDATER_ROOT = $(CURDIR)/../third_party/gnustep-packager-updater/objc
UPDATER_CORE_DIR = $(UPDATER_ROOT)/GPUpdaterCore
UPDATER_UI_DIR = $(UPDATER_ROOT)/GPUpdaterUI
UPDATER_HELPER_DIR = $(UPDATER_ROOT)/gp-update-helper
ADDITIONAL_INCLUDE_DIRS += -I$(UPDATER_CORE_DIR)/Headers -I$(UPDATER_UI_DIR)/Headers
ADDITIONAL_LIB_DIRS += -L$(UPDATER_UI_DIR) -L$(UPDATER_CORE_DIR)
ADDITIONAL_GUI_LIBS += -lGPUpdaterUI -lGPUpdaterCore
ifneq (,$(WINDOWS))
# feeds and packages through WinHTTP; URLs opened with ShellExecuteW
ADDITIONAL_GUI_LIBS += -lwinhttp -lshell32
endif
ifeq (,$(WINDOWS))
# the build tree, and the packaged layout (app/ next to runtime/lib)
ADDITIONAL_LDFLAGS += -Wl,-rpath,'$$ORIGIN/../../GSPerformance/obj:$$ORIGIN/../../Runtime/obj:$$ORIGIN/../../runtime/lib'
endif

include $(GNUSTEP_MAKEFILES)/application.make

.PHONY: updater
before-all:: updater
updater:
	@$(MAKE) -C "$(UPDATER_CORE_DIR)"
	@$(MAKE) -C "$(UPDATER_UI_DIR)"
	@$(MAKE) -C "$(UPDATER_HELPER_DIR)"

# GPStandardUpdaterController looks for the helper beside the executable.
after-all::
ifneq (,$(WINDOWS))
	cp ../Runtime/obj/gsperf.dll PerformanceDashboard.app/
endif
	@if [ -x "$(UPDATER_HELPER_DIR)/gp-update-helper.exe" ]; then \
	  cp "$(UPDATER_HELPER_DIR)/gp-update-helper.exe" PerformanceDashboard.app/; \
	else \
	  cp "$(UPDATER_HELPER_DIR)/gp-update-helper" PerformanceDashboard.app/; \
	fi

after-clean::
	@$(MAKE) -C "$(UPDATER_CORE_DIR)" clean
	@$(MAKE) -C "$(UPDATER_UI_DIR)" clean
	@$(MAKE) -C "$(UPDATER_HELPER_DIR)" clean
