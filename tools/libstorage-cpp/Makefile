CXX := g++
CXXFLAGS := -std=c++17 -Wall -Wextra -O2 -I../../library
LIBSTORAGE := ../../build/libstorage.so
LDFLAGS := $(LIBSTORAGE) -pthread
RPATH := -Wl,-rpath,'$$ORIGIN/../../build'

TARGETS := storage_lib_cli storage_lib storage_lib_ctl
COMMON_SRCS := storage_client.cpp

.PHONY: all clean run

all: $(TARGETS)

storage_lib_cli: storage_lib_cli.cpp $(COMMON_SRCS) storage_client.hpp $(LIBSTORAGE)
	$(CXX) $(CXXFLAGS) storage_lib_cli.cpp $(COMMON_SRCS) -o $@ $(LDFLAGS) $(RPATH)

storage_lib: storage_lib.cpp $(COMMON_SRCS) storage_client.hpp $(LIBSTORAGE)
	$(CXX) $(CXXFLAGS) storage_lib.cpp $(COMMON_SRCS) -o $@ $(LDFLAGS) $(RPATH)

storage_lib_ctl: storage_lib_ctl.cpp
	$(CXX) $(CXXFLAGS) storage_lib_ctl.cpp -o $@

$(LIBSTORAGE):
	@echo "Missing $(LIBSTORAGE). Run 'make libstorage' from the repository root first." >&2
	@exit 1

run: storage_lib_cli
	LD_LIBRARY_PATH=../../build ./storage_lib_cli info

clean:
	rm -f $(TARGETS)
	rm -rf storage-lib-cli-data storage-lib-data
	rm -f storage_lib.sock daemon.log
	rm -f downloaded* *.download *.download.* *.roundtrip *.out.*
