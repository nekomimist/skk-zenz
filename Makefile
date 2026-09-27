BUILD_DIR ?= build
BUILD_TYPE ?= Release
JOBS ?= $(shell nproc 2>/dev/null || echo 4)
EMACS ?= emacs

# DDSKK sources for Emacs Lisp tests. Point this at an installed copy to avoid
# the clone, e.g. make test DDSKK_DIR=~/.emacs.d/elpa/ddskk-...
DDSKK_DIR ?= $(BUILD_DIR)/deps/ddskk
DDSKK_REPO ?= https://github.com/skk-dev/ddskk.git

# Model used by opt-in model tests. Tests that need it skip when it is absent.
ZENZ_MODEL ?= models/zenz-v3.2-small-Q5_K_M.gguf
export ZENZ_MODEL := $(abspath $(ZENZ_MODEL))

# DDSKK sources lack lexical-binding cookies, which Emacs 30+ warns about.
EMACS_BATCH = $(EMACS) -Q --batch --eval "(setq warning-suppress-log-types '((files missing-lexbind-cookie)))" \
	-L . -L $(DDSKK_DIR)

.PHONY: all build test test-cpp test-elisp compile clean

all: build

$(BUILD_DIR)/CMakeCache.txt:
	cmake -S . -B $(BUILD_DIR) -DCMAKE_BUILD_TYPE=$(BUILD_TYPE)

build: $(BUILD_DIR)/CMakeCache.txt
	cmake --build $(BUILD_DIR) -j $(JOBS)

# A source checkout has no autoloads until `make install`; generate them.
# loaddefs-gen warns that it cannot load skk-gadget.el; the output is complete
# enough for the tests.
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
	rm -rf $(BUILD_DIR) skk-zenz.elc
