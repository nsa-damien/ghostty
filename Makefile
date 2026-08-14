MACOS_APP_NAME := Ghostty Dev
MACOS_APP := $(CURDIR)/macos/build/Debug/$(MACOS_APP_NAME).app
MACOS_BUILD_ENV := env -i HOME="$(HOME)" PATH=/usr/bin:/bin:/usr/sbin:/sbin TOOLCHAINS=Metal

help:
	@echo "Ghostty development commands:"
	@echo "  make run    Rebuild and launch a new debug macOS app instance"
	@echo "  make clean  Remove Zig and macOS build artifacts"
	@echo "  make glad   Update the vendored GLAD loader from glad.zip"
.PHONY: help

run:
	TOOLCHAINS=Metal zig build -Demit-macos-app=false
	$(MACOS_BUILD_ENV) xcodebuild \
		-project macos/Ghostty.xcodeproj \
		-scheme Ghostty \
		-configuration Debug \
		SYMROOT="$(CURDIR)/macos/build" \
		GHOSTTY_PRODUCT_NAME="$(MACOS_APP_NAME)" \
		GHOSTTY_DISPLAY_NAME="$(MACOS_APP_NAME)" \
		build
	open -n "$(MACOS_APP)"
.PHONY: run

init:
	@echo You probably want to run "zig build" instead.
.PHONY: init

# glad updates the GLAD loader. To use this, place the generated glad.zip
# in this directory next to the Makefile, remove vendor/glad and run this target.
#
# Generator: https://gen.glad.sh/
glad: vendor/glad
.PHONY: glad

vendor/glad: vendor/glad/include/glad/gl.h vendor/glad/include/glad/glad.h

vendor/glad/include/glad/gl.h: glad.zip
	rm -rf vendor/glad
	mkdir -p vendor/glad
	unzip glad.zip -dvendor/glad
	find vendor/glad -type f -exec touch '{}' +

vendor/glad/include/glad/glad.h: vendor/glad/include/glad/gl.h
	@echo "#include <glad/gl.h>" > $@

clean:
	rm -rf \
		zig-out .zig-cache \
		macos/build \
		macos/GhosttyKit.xcframework
.PHONY: clean
