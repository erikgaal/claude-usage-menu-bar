APP_NAME = Claude Usage
BUILD_DIR = build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app

.PHONY: build bundle run clean

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

clean:
	rm -rf .build $(BUILD_DIR)
