# Makefile for building C++ examples against Logos Storage C bindings
#
# Usage (from this directory):
#   make
#
# This produces ./storage_example
#
# The example links against the library built by the main project:
#   ../../build/libstorage.so
#
# You may need to run:
#   LD_LIBRARY_PATH=../../build ./storage_example
#
# Or build with rpath so the binary finds the library automatically.

CXX := g++
CXXFLAGS := -std=c++17 -Wall -Wextra -O2 -I../../library
LIBSTORAGE := ../../build/libstorage.so
LDFLAGS := $(LIBSTORAGE) -pthread

# Use rpath so the resulting binary can find libstorage.so relative to itself
# when run from the examples/cpp directory or nearby.
RPATH := -Wl,-rpath,'$$ORIGIN/../../build'

TARGET := storage_example
SRC := storage_example.cpp

.PHONY: all clean run

all: $(TARGET)

$(TARGET): $(SRC) $(LIBSTORAGE)
	$(CXX) $(CXXFLAGS) $(SRC) -o $(TARGET) $(LDFLAGS) $(RPATH)

$(LIBSTORAGE):
	@echo "Missing $(LIBSTORAGE). Run 'make libstorage' from the repository root first." >&2
	@exit 1

clean:
	rm -f $(TARGET)
	rm -rf cpp-example-data

# Convenience target: build + run with correct library path
run: $(TARGET)
	LD_LIBRARY_PATH=../../build ./$(TARGET)
