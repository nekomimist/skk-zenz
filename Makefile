BUILD_DIR ?= build
DIST_BUILD_DIR ?= build-dist
DIST_DIR ?= dist
BUILD_TYPE ?= Release
JOBS ?= $(shell nproc 2>/dev/null || echo 4)
EMACS ?= emacs

# DDSKK sources for Emacs Lisp tests. Point this at an installed copy to avoid
# the clone, e.g. make test DDSKK_DIR=~/.emacs.d/elpa/ddskk-...
DDSKK_DIR ?= $(BUILD_DIR)/deps/ddskk
DDSKK_REPO ?= https://github.com/skk-dev/ddskk.git

# Model used by `make model` and by opt-in model tests (which skip when it is
# absent). The URL is pinned to a model repository revision.
ZENZ_MODEL ?= models/zenz-v3.2-small-Q5_K_M.gguf
export ZENZ_MODEL := $(abspath $(ZENZ_MODEL))
MODEL_URL ?= https://huggingface.co/Miwa-Keita/zenz-v3.2-small-gguf/resolve/c67e03e07d215c869f591b274c1631170d3e11fe/ggml-model-Q5_K_M.gguf
MODEL_SHA256 ?= 29c223d4c23327b80fd13ebb5ab2555057a46317997d5da391584ffbef0db673

# DDSKK sources lack lexical-binding cookies, which Emacs 30+ warns about.
EMACS_BATCH = $(EMACS) -Q --batch --eval "(setq warning-suppress-log-types '((files missing-lexbind-cookie)))" \
	-L . -L $(DDSKK_DIR)

.PHONY: all build dist model test test-cpp test-elisp compile clean

all: build

$(BUILD_DIR)/CMakeCache.txt:
	cmake -S . -B $(BUILD_DIR) -DCMAKE_BUILD_TYPE=$(BUILD_TYPE)

build: $(BUILD_DIR)/CMakeCache.txt
	cmake --build $(BUILD_DIR) -j $(JOBS)

# Release archive of a portable zenz-server (see scripts/dist.sh).
dist:
	cmake -S . -B $(DIST_BUILD_DIR) -DCMAKE_BUILD_TYPE=Release -DZENZ_PORTABLE=ON
	cmake --build $(DIST_BUILD_DIR) -j $(JOBS) --target zenz-server
	scripts/dist.sh $(DIST_BUILD_DIR) $(DIST_DIR)

# A source checkout has no autoloads until `make install`; generate them.
# loaddefs-gen warns that it cannot load skk-gadget.el; the output is complete
# enough for the tests.
model: $(ZENZ_MODEL)

$(ZENZ_MODEL):
	mkdir -p $(dir $@)
	curl -fL --retry 3 -o $@.tmp $(MODEL_URL)
	echo "$(MODEL_SHA256)  $@.tmp" | sha256sum -c -
	mv $@.tmp $@

$(DDSKK_DIR):
	git clone --depth 1 $(DDSKK_REPO) $@
	cd $@ && $(EMACS) -Q --batch -L . \
		--eval '(loaddefs-generate "." (expand-file-name "skk-autoloads.el"))'

test: test-cpp test-elisp

test-cpp: build
	ctest --test-dir $(BUILD_DIR) --output-on-failure

compile: $(DDSKK_DIR)
	$(EMACS_BATCH) --eval '(setq byte-compile-error-on-warn t)' \
		-f batch-byte-compile skk-zenz.el

test-elisp: compile
	$(EMACS_BATCH) -l tests/skk-zenz-test.el -f ert-run-tests-batch-and-exit

clean:
	rm -rf $(BUILD_DIR) $(DIST_BUILD_DIR) $(DIST_DIR) skk-zenz.elc
