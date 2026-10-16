include $(GNUSTEP_MAKEFILES)/common.make

LIBRARY_NAME = libGSPerformance
VERSION = 0.1.0

libGSPerformance_OBJC_FILES = \
  GSPTrace.m \
  GSPStackTable.m \
  GSPSymbolicator.m \
  GSPCallTree.m \
  GSPAnalysis.m \
  GSPInstruments.m \
  GSPRecorder.m \
  GSPExporter.m \
  GSPComparison.m

libGSPerformance_HEADER_FILES = \
  GSPerformance.h \
  GSPTrace.h \
  GSPStackTable.h \
  GSPSymbolicator.h \
  GSPCallTree.h \
  GSPAnalysis.h \
  GSPInstruments.h \
  GSPRecorder.h \
  GSPExporter.h \
  GSPComparison.h

libGSPerformance_HEADER_FILES_INSTALL_DIR = GSPerformance

ADDITIONAL_OBJCFLAGS += -fobjc-arc -Wall -Wno-unused-function
ADDITIONAL_INCLUDE_DIRS += -I../Runtime/include -I..
libGSPerformance_LIBRARIES_DEPEND_UPON += -lgnustep-base -lobjc -ldl

include $(GNUSTEP_MAKEFILES)/library.make
