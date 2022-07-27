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
	clean \
	coverage \
	deps \
	libbacktrace \
	test \
	update

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

# "-d:release" implies "--stacktrace:off" and it cannot be added to config.nims
ifeq ($(USE_LIBBACKTRACE), 0)
NIM_PARAMS := $(NIM_PARAMS) -d:debug -d:disable_libbacktrace
else
NIM_PARAMS := $(NIM_PARAMS) -d:release
endif

deps: | deps-common nat-libs codex.nims
ifneq ($(USE_LIBBACKTRACE), 0)
deps: | libbacktrace
endif

#- deletes and recreates "codex.nims" which on Windows is a copy instead of a proper symlink
update: | update-common
	rm -rf codex.nims && \
		$(MAKE) codex.nims $(HANDLE_OUTPUT)

# detecting the os
ifeq ($(OS),Windows_NT) # is Windows_NT on XP, 2000, 7, Vista, 10...
 detected_OS := Windows
else ifeq ($(strip $(shell uname)),Darwin)
 detected_OS := macOS
else
 # e.g. Linux
 detected_OS := $(strip $(shell uname))
endif

# Builds and run a part of the test suite
test: | build deps
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim test $(NIM_PARAMS) codex.nims

# Builds and runs all tests
testAll: | build deps
	echo -e $(BUILD_MSG) "build/testCodex" "build/testContracts" && \
		$(ENV_SCRIPT) nim testAll $(NIM_PARAMS) codex.nims

# Builds the codex binary
exec: | build deps
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim codex codex.nims

# symlink
codex.nims:
	ln -s codex.nimble $@

# nim-libbacktrace
LIBBACKTRACE_MAKE_FLAGS := -C vendor/nim-libbacktrace --no-print-directory BUILD_CXX_LIB=0
libbacktrace:
ifeq ($(detected_OS), Windows)
# MSYS2 detection
ifneq ($(MSYSTEM),)
	+ $(MAKE) $(LIBBACKTRACE_MAKE_FLAGS) CMAKE_ARGS="-G'MSYS Makefiles'"
else
	+ $(MAKE) $(LIBBACKTRACE_MAKE_FLAGS)
endif
else
	+ $(MAKE) $(LIBBACKTRACE_MAKE_FLAGS)
endif

coverage:
	$(MAKE) NIMFLAGS="$(NIMFLAGS) --lineDir:on --passC:-fprofile-arcs --passC:-ftest-coverage --passL:-fprofile-arcs --passL:-ftest-coverage" testAll
	cd nimcache/release/codex && rm -f *.c
	cd nimcache/release/testCodex && rm -f *.c
	cd nimcache/release/testContracts && rm -f *.c
	cd nimcache/release/testIntegration && rm -f *.c
	mkdir -p coverage
	lcov --capture --directory nimcache/release/codex --directory nimcache/release/testCodex --directory nimcache/release/testContracts --directory nimcache/release/testIntegration --output-file coverage/coverage.info
	shopt -s globstar && ls $$(pwd)/codex/{*,**/*}.nim
	shopt -s globstar && lcov --extract coverage/coverage.info $$(pwd)/codex/{*,**/*}.nim --output-file coverage/coverage.f.info
	echo -e $(BUILD_MSG) "coverage/report/index.html"
	genhtml coverage/coverage.f.info --output-directory coverage/report
	if which open >/dev/null; then (echo -e "\e[92mOpening\e[39m HTML coverage report in browser..." && open coverage/report/index.html) || true; fi

# usual cleaning
clean: | clean-common
	rm -rf build
ifneq ($(USE_LIBBACKTRACE), 0)
	+ $(MAKE) -C vendor/nim-libbacktrace clean $(HANDLE_OUTPUT)
endif

endif # "variables.mk" was not included
