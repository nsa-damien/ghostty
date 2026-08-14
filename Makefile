MACOS_APP_NAME := Ghostty Dev
MACOS_BUNDLE_ID := com.northshoreautomation.ghostty-dev
GHOSTTY_DEV_VERSION ?= 1.3.2-sidebar.1
MACOS_APP := $(CURDIR)/macos/build/Debug/$(MACOS_APP_NAME).app
MACOS_RELEASE_APP := $(CURDIR)/macos/build/ReleaseLocal/$(MACOS_APP_NAME).app
MACOS_DIST_DIR := $(CURDIR)/macos/build/dist
MACOS_RELEASE_ARCHIVE := $(MACOS_DIST_DIR)/Ghostty-Dev-macos-universal.zip
MACOS_SIGNING_IDENTITY ?= Developer ID Application: North Shore Automation, LLC (26M5Y48BJZ)
MACOS_NOTARY_PROFILE ?= csviewer-notary
MACOS_BUILD_ENV := env -i HOME="$(HOME)" PATH=/usr/bin:/bin:/usr/sbin:/sbin TOOLCHAINS=Metal

help:
	@echo "Ghostty development commands:"
	@echo "  make run          Rebuild and launch a new debug macOS app instance"
	@echo "  make release      Build an optimized local macOS app"
	@echo "  make release-run  Rebuild and launch the optimized local macOS app"
	@echo "  make release-install  Rebuild and replace /Applications/Ghostty Dev.app"
	@echo "  make test-release-contract  Verify Ghostty Dev distribution wiring"
	@echo "  make release-sign     Rebuild and Developer ID-sign the optimized app"
	@echo "  make release-notarize Build, sign, notarize, and package for distribution"
	@echo "  make clean        Remove Zig and macOS build artifacts"
	@echo "  make glad         Update the vendored GLAD loader from glad.zip"
.PHONY: help

run:
	TOOLCHAINS=Metal zig build -Dversion-string=$(GHOSTTY_DEV_VERSION) -Demit-macos-app=false
	$(MACOS_BUILD_ENV) xcodebuild \
		-project macos/Ghostty.xcodeproj \
		-scheme Ghostty \
		-configuration Debug \
		SYMROOT="$(CURDIR)/macos/build" \
		GHOSTTY_PRODUCT_NAME="$(MACOS_APP_NAME)" \
		GHOSTTY_DISPLAY_NAME="$(MACOS_APP_NAME)" \
		GHOSTTY_BUNDLE_IDENTIFIER="$(MACOS_BUNDLE_ID)" \
		MARKETING_VERSION="$(GHOSTTY_DEV_VERSION)" \
		build
	open -n "$(MACOS_APP)"
.PHONY: run

release:
	TOOLCHAINS=Metal zig build -Dversion-string=$(GHOSTTY_DEV_VERSION) -Doptimize=ReleaseFast -Demit-macos-app=false
	$(MACOS_BUILD_ENV) xcodebuild \
		-project macos/Ghostty.xcodeproj \
		-scheme Ghostty \
		-configuration ReleaseLocal \
		SYMROOT="$(CURDIR)/macos/build" \
		GHOSTTY_PRODUCT_NAME="$(MACOS_APP_NAME)" \
		GHOSTTY_DISPLAY_NAME="$(MACOS_APP_NAME)" \
		GHOSTTY_BUNDLE_IDENTIFIER="$(MACOS_BUNDLE_ID)" \
		MARKETING_VERSION="$(GHOSTTY_DEV_VERSION)" \
		build
.PHONY: release

release-run: release
	open -n "$(MACOS_RELEASE_APP)"
.PHONY: release-run

release-install: release
	rm -rf "/Applications/$(MACOS_APP_NAME).app"
	ditto "$(MACOS_RELEASE_APP)" "/Applications/$(MACOS_APP_NAME).app"
.PHONY: release-install

test-release-contract:
	sh test/macos/release-contract.sh
.PHONY: test-release-contract

release-sign: test-release-contract release
	macos/scripts/sign-local-release.sh \
		"$(MACOS_RELEASE_APP)" \
		"$(MACOS_SIGNING_IDENTITY)" \
		"$(CURDIR)/macos/Ghostty.entitlements"
.PHONY: release-sign

release-notarize: release-sign
	macos/scripts/notarize-local-release.sh \
		"$(MACOS_RELEASE_APP)" \
		"$(MACOS_RELEASE_ARCHIVE)" \
		"$(MACOS_NOTARY_PROFILE)"
.PHONY: release-notarize

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
