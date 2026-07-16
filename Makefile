APP_NAME = Claude Usage
BUILD_DIR = build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
VERSION = 1.0.0
RELEASE_ZIP = $(BUILD_DIR)/Claude-Usage-$(VERSION).zip

# Assembles Contents/ from an executable path passed as $(1).
# Compiles the Icon Composer document into Assets.car (Liquid Glass,
# macOS 26+) plus a flattened AppIcon.icns fallback for older systems.
define assemble_bundle
	rm -rf "$(APP_BUNDLE)"
	mkdir -p "$(APP_BUNDLE)/Contents/MacOS" "$(APP_BUNDLE)/Contents/Resources"
	cp $(1) "$(APP_BUNDLE)/Contents/MacOS/"
	cp Resources/Info.plist "$(APP_BUNDLE)/Contents/"
	xcrun actool Resources/AppIcon.icon --compile "$(APP_BUNDLE)/Contents/Resources" \
		--output-format human-readable-text --errors \
		--app-icon AppIcon --include-all-app-icons \
		--platform macosx --minimum-deployment-target 14.0 \
		--output-partial-info-plist "$(BUILD_DIR)/icon-partial.plist" > /dev/null
	codesign --force --sign - "$(APP_BUNDLE)"
endef

.PHONY: build bundle run release clean

build:
	swift build -c release

bundle: build
	$(call assemble_bundle,.build/release/ClaudeUsage)

run: bundle
	open "$(APP_BUNDLE)"

# Universal (arm64 + x86_64) build, zipped for distribution. Ad-hoc signed:
# recipients must approve it once via System Settings > Privacy & Security.
release:
	swift build -c release --arch arm64 --arch x86_64
	$(call assemble_bundle,.build/apple/Products/Release/ClaudeUsage)
	rm -f "$(RELEASE_ZIP)"
	ditto -c -k --sequesterRsrc --keepParent "$(APP_BUNDLE)" "$(RELEASE_ZIP)"
	@echo "Release artifact: $(RELEASE_ZIP)"

clean:
	rm -rf .build $(BUILD_DIR)
