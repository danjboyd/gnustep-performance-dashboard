include $(GNUSTEP_MAKEFILES)/common.make

XCTEST_BUNDLE_NAME = GSPerformanceTests
GSPerformanceTests_OBJC_FILES = GSPerformanceTests.m TraceBuilder.m PDWelcomeModelTests.m PDWelcomeProviderTests.m ../../Dashboard/PDWelcomeModel.m ../../Dashboard/PDWelcomeProcessProvider.m ../../Dashboard/PDWelcomeArguments.m

ADDITIONAL_OBJCFLAGS += -fobjc-arc -Wall
ADDITIONAL_INCLUDE_DIRS += -I../../Runtime/include -I../..
ADDITIONAL_LIB_DIRS += -L../../GSPerformance/obj
GSPerformanceTests_BUNDLE_LIBS += -lGSPerformance
ifeq (,$(findstring mingw,$(GNUSTEP_HOST_OS))$(findstring windows,$(GNUSTEP_HOST_OS)))
ADDITIONAL_LDFLAGS += -Wl,-rpath,$(CURDIR)/../../GSPerformance/obj
GSPerformanceTests_BUNDLE_LIBS += -lz
endif

include $(GNUSTEP_MAKEFILES)/Auxiliary/xctest.make
