CC      ?= gcc
CXX     ?= g++
CFLAGS  := -O2 -Wall -Wextra -Iinclude -fPIC
CXXFLAGS:= -std=c++20 -O2 -Wall -Wextra -Iinclude

all: build/daemond build/libdaemond_hook.so build/daemond-egui

build/daemond: src/daemon/daemond.cpp include/daemond_shm.h
	@mkdir -p build
	$(CXX) $(CXXFLAGS) src/daemon/daemond.cpp -o build/daemond -lrt -lpthread

build/libdaemond_hook.so: src/interceptor/libdaemond_hook.c include/daemond_shm.h
	@mkdir -p build
	$(CC) $(CFLAGS) -shared src/interceptor/libdaemond_hook.c -o build/libdaemond_hook.so -ldl -lrt

build/daemond-egui: src/egui/egui_bridge.c include/daemond_shm.h
	@mkdir -p build
	$(CC) $(CFLAGS) src/egui/egui_bridge.c -o build/daemond-egui

clean:
	rm -rf build

.PHONY: all clean
