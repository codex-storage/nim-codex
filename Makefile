# Copyright (c) 2020 Status Research & Development GmbH. Licensed under
# either of:
# - Apache License, version 2.0
# - MIT license
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

SHELL := bash # the shell used internally by Make

# used inside the included makefiles
BUILD_SYSTEM_DIR := vendor/nimbus-build-system

# -d:insecure - Necessary to enable Prometheus HTTP endpoint for metrics
# -d:chronicles_colors:none - Necessary to disable colors in logs for Docker
DOCKER_IMAGE_NIM_PARAMS ?= -d:chronicles_colors:none -d:insecure

LINK_PCRE := 0

# we don't want an error here, so we can handle things later, in the ".DEFAULT" target
-include $(BUILD_SYSTEM_DIR)/makefiles/variables.mk

.PHONY: \
	all \
	deps \
	update \
	leopard \
	testAll \
	test \
	libbacktrace \
	clean-leopard \
	clean

ifeq ($(NIM_PARAMS),)
# "variables.mk" was not included, so we update the submodules.
GIT_SUBMODULE_UPDATE := git submodule update --init --recursive
.DEFAULT:
	+@ echo -e "Git submodules not found. Running '$(GIT_SUBMODULE_UPDATE)'.\n"; \
		$(GIT_SUBMODULE_UPDATE); \
		echo
# Now that the included *.mk files appeared, and are newer than this file, Make will restart itself:
# https://www.gnu.org/software/make/manual/make.html#Remaking-Makefiles
#
# After restarting, it will execute its original goal, so we don't have to start a child Make here
# with "$(MAKE) $(MAKECMDGOALS)". Isn't hidden control flow great?

else # "variables.mk" was included. Business as usual until the end of this file.

# default target, because it's the first one that doesn't start with '.'
all: | test

# must be included after the default target
-include $(BUILD_SYSTEM_DIR)/makefiles/targets.mk

# detecting the os
ifeq ($(OS),Windows_NT) # is Windows_NT on XP, 2000, 7, Vista, 10...
detected_OS := Windows
else ifeq ($(strip $(shell uname)),Darwin)
detected_OS := macOS
else
 # e.g. Linux
detected_OS := $(strip $(shell uname))
endif

# "-d:release" implies "--stacktrace:off" and it cannot be added to config.nims
ifeq ($(USE_LIBBACKTRACE), 0)
NIM_PARAMS := $(NIM_PARAMS) -d:debug -d:disable_libbacktrace
else
NIM_PARAMS := $(NIM_PARAMS) -d:release
endif

deps: | deps-common nat-libs dagger.nims leopard
ifneq ($(USE_LIBBACKTRACE), 0)
deps: | libbacktrace
endif

#- deletes and recreates "dagger.nims" which on Windows is a copy instead of a proper symlink
update: | update-common
	rm -rf dagger.nims && \
		$(MAKE) dagger.nims $(HANDLE_OUTPUT)

# a phony target, because teaching `make` how to do conditional recompilation of Nim projects is too complicated

LIBLEOPARD := $(shell pwd)/vendor/leopard/build/liblibleopard.a
LIBLEOPARD_HEADER := $(shell pwd)/vendor/leopard/leopard.h

ifeq ($(detected_OS),Windows)
LIBLEOPARD_CMAKE_FLAGS ?= -G"MSYS Makefiles" -DCMAKE_BUILD_TYPE=Release
else
LIBLEOPARD_CMAKE_FLAGS ?= -DCMAKE_BUILD_TYPE=Release
endif

ifeq ($(detected_OS),Windows)
NIM_PARAMS += --passC:"-I$(shell cygpath -m $(shell dirname $(LIBLEOPARD_HEADER)))" --passL:"$(shell cygpath -m $(LIBLEOPARD))"
else
NIM_PARAMS += --passC:"-I$(shell dirname $(LIBLEOPARD_HEADER))" --passL:"$(LIBLEOPARD)"
endif

ifneq ($(detected_OS),macOS)
NIM_PARAMS += --passL:-fopenmp
endif

NIM_PARAMS += $(NIM_EXTRA_PARAMS)

$(LIBLEOPARD):
	cd vendor/leopard && \
	mkdir -p build && cd build && \
	cmake .. $(LIBLEOPARD_CMAKE_FLAGS) && \
	$(MAKE) libleopard

leopard: $(LIBLEOPARD)

testAll: | build deps
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim testAll $(NIM_PARAMS) dagger.nims

# Builds and run the test suite (Waku v1 + v2)
test: | testAll

# symlink
dagger.nims:
	ln -s dagger.nimble $@

# nim-libbacktrace
libbacktrace:
	+ $(MAKE) -C vendor/nim-libbacktrace --no-print-directory BUILD_CXX_LIB=0

clean-leopard:
	rm -rf $(shell dirname $(LIBLEOPARD))

# usual cleaning
clean: | clean-common clean-leopard
	rm -rf build
ifneq ($(USE_LIBBACKTRACE), 0)
	+ $(MAKE) -C vendor/nim-libbacktrace clean $(HANDLE_OUTPUT)
endif

endif # "variables.mk" was not included
