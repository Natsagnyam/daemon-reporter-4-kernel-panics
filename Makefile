CC       ?= gcc
CXX      ?= g++
CFLAGS   := -O2 -Wall -Wextra -Iinclude -fPIC
CXXFLAGS := -std=c++20 -O2 -Wall -Wextra -Iinclude

all: build/daemond build/libdaemond_hook.so build/daemond-egui build/app1 build/app2 build/app3 build/app4_panic

build/daemond: src/daemon/daemond.cpp include/daemond_shm.h
	@mkdir -p build
	$(CXX) $(CXXFLAGS) src/daemon/daemond.cpp -o build/daemond -lrt -lpthread

build/libdaemond_hook.so: src/interceptor/libdaemond_hook.c include/daemond_shm.h
	@mkdir -p build
	$(CC) $(CFLAGS) -shared src/interceptor/libdaemond_hook.c -o build/libdaemond_hook.so -ldl -lrt

build/daemond-egui: src/egui/egui_bridge.c include/daemond_shm.h
	@mkdir -p build
	$(CC) $(CFLAGS) src/egui/egui_bridge.c -o build/daemond-egui

build/app1: tests/app1.c build/libdaemond_hook.so
	@mkdir -p build
	./wrappers/daemond-cc-mem tests/app1.c -o build/app1

build/app2: tests/app2.c build/libdaemond_hook.so
	@mkdir -p build
	./wrappers/daemond-cc-race tests/app2.c -lpthread -o build/app2

build/app3: tests/app3.c build/libdaemond_hook.so
	@mkdir -p build
	$(CC) -O1 -g -fno-omit-frame-pointer -Iinclude -Lbuild -Wl,-rpath,$(CURDIR)/build -Wl,--no-as-needed -ldaemond_hook tests/app3.c -o build/app3

build/app4_panic: tests/app4_panic.c include/daemond_shm.h
	@mkdir -p build
	$(CC) $(CFLAGS) tests/app4_panic.c -o build/app4_panic -lrt

egui-rust: build/daemond
	cd egui-viewer && cargo run --release

clean:
	rm -rf build

.PHONY: all clean egui-rust
