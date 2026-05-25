.PHONY: build verify clean clean-build clean-output distclean help

HERE := $(CURDIR)
BUILD_DIR ?= $(HERE)/build
IMAGE_GLOB := $(BUILD_DIR)/output/images/Armbian_*_Turing-rk1_trixie_*.img
IMAGE := $(firstword $(wildcard $(IMAGE_GLOB)))

help:
	@echo "Targets:"
	@echo "  build       - run Armbian compile.sh (clones armbian/build if needed)"
	@echo "  verify      - loop-mount the built image and sanity-check it"
	@echo "  clean       - remove built images and logs (keep cache + cloned tree)"
	@echo "  clean-build - remove the cloned armbian/build tree entirely"
	@echo "  distclean   - clean + clean-build"

build:
	./build.sh

verify:
	@if [ -z "$(IMAGE)" ]; then \
	  echo "no image found at $(IMAGE_GLOB)"; exit 1; \
	fi
	sudo ./verify.sh "$(IMAGE)"

clean:
	rm -rf "$(BUILD_DIR)/output/images" "$(BUILD_DIR)/output/logs"

clean-build:
	rm -rf "$(BUILD_DIR)"

distclean: clean clean-build
