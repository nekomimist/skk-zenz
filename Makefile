BUILD_DIR ?= build
BUILD_TYPE ?= Release
JOBS ?= $(shell nproc 2>/dev/null || echo 4)

# Model used by opt-in model tests. Tests that need it skip when it is absent.
ZENZ_MODEL ?= models/zenz-v3.2-small-Q5_K_M.gguf
export ZENZ_MODEL := $(abspath $(ZENZ_MODEL))

.PHONY: all build test clean

all: build

$(BUILD_DIR)/CMakeCache.txt:
	cmake -S . -B $(BUILD_DIR) -DCMAKE_BUILD_TYPE=$(BUILD_TYPE)

build: $(BUILD_DIR)/CMakeCache.txt
	cmake --build $(BUILD_DIR) -j $(JOBS)

test: build
	ctest --test-dir $(BUILD_DIR) --output-on-failure

clean:
	rm -rf $(BUILD_DIR)
