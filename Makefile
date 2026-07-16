APP_NAME = Claude Usage
BUILD_DIR = build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
VERSION = 1.0.0
RELEASE_ZIP = $(BUILD_DIR)/Claude-Usage-$(VERSION).zip

.PHONY: build bundle run release clean

build:
	swift build -c release

bundle: build
	rm -rf "$(APP_BUNDLE)"
	mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	cp .build/release/ClaudeUsage "$(APP_BUNDLE)/Contents/MacOS/"
	cp Resources/Info.plist "$(APP_BUNDLE)/Contents/"
	codesign --force --sign - "$(APP_BUNDLE)"

run: bundle
	open "$(APP_BUNDLE)"

# Universal (arm64 + x86_64) build, zipped for distribution. Ad-hoc signed:
# recipients must approve it once via System Settings > Privacy & Security.
release:
	swift build -c release --arch arm64 --arch x86_64
	rm -rf "$(APP_BUNDLE)" "$(RELEASE_ZIP)"
	mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	cp .build/apple/Products/Release/ClaudeUsage "$(APP_BUNDLE)/Contents/MacOS/"
	cp Resources/Info.plist "$(APP_BUNDLE)/Contents/"
	codesign --force --sign - "$(APP_BUNDLE)"
	ditto -c -k --sequesterRsrc --keepParent "$(APP_BUNDLE)" "$(RELEASE_ZIP)"
	@echo "Release artifact: $(RELEASE_ZIP)"

clean:
	rm -rf .build $(BUILD_DIR)
