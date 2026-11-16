# Shared build-time product identity. Trace format and library ABI are separate.
PD_VERSION_SCRIPT := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))app-version.py
PD_VERSION_HEADER := $(CURDIR)/obj/PDProductVersion.h
PD_PRODUCT_VERSION := $(shell python3 "$(PD_VERSION_SCRIPT)" value --header "$(PD_VERSION_HEADER)")
ifeq ($(strip $(PD_PRODUCT_VERSION)),)
$(error Cannot determine effective package version)
endif
# Included headers enter GNUstep's normal dependency files. A changed effective
# version therefore rebuilds embedded reporting strings even without make clean.
PD_PRODUCT_VERSION_CPPFLAGS := -include "$(PD_VERSION_HEADER)"
