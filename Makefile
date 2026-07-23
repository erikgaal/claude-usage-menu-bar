APP_NAME = Claude Usage
BUILD_DIR = build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
VERSION = 1.0.0
RELEASE_ZIP = $(BUILD_DIR)/Claude-Usage-$(VERSION).zip

# Sign with a real identity when available so the app keeps the same code
# identity across rebuilds (otherwise Keychain re-prompts after every build).
# Developer ID (distribution/notarization) wins over Apple Development (local).
CODESIGN_ID := $(shell security find-identity -v -p codesigning 2>/dev/null \
	| awk -F'"' '/Developer ID Application/{print $$2; exit}')
ifeq ($(CODESIGN_ID),)
CODESIGN_ID := $(shell security find-identity -v -p codesigning 2>/dev/null \
	| awk -F'"' '/Apple Development/{print $$2; exit}')
endif
ifeq ($(CODESIGN_ID),)
CODESIGN_ID := -
endif

# Hardened runtime + secure timestamp are required for notarization; they
# only apply with a real identity (ad-hoc signatures can't be timestamped).
ifneq ($(CODESIGN_ID),-)
CODESIGN_FLAGS = --options runtime --timestamp
endif

# `notarytool store-credentials` profile name used by `make notarize`.
NOTARY_PROFILE ?= claude-usage

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
	codesign --force $(CODESIGN_FLAGS) --sign "$(CODESIGN_ID)" "$(APP_BUNDLE)"
endef

.PHONY: build bundle run release notarize clean

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
	@echo "Signed as: $(CODESIGN_ID)"
	@echo "Release artifact: $(RELEASE_ZIP)"

# Requires a Developer ID Application signature (paid Apple Developer
# Program) and stored notarytool credentials:
#   xcrun notarytool store-credentials claude-usage \
#     --apple-id you@example.com --team-id TEAMID --password <app-specific>
# Submits, waits for the verdict, staples the ticket, and re-zips.
notarize: release
	@case "$(CODESIGN_ID)" in "Developer ID Application"*) ;; \
	*) echo "error: signed as '$(CODESIGN_ID)' — notarization needs a Developer ID Application identity" >&2; exit 1 ;; esac
	xcrun notarytool submit "$(RELEASE_ZIP)" --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple "$(APP_BUNDLE)"
	rm -f "$(RELEASE_ZIP)"
	ditto -c -k --sequesterRsrc --keepParent "$(APP_BUNDLE)" "$(RELEASE_ZIP)"
	@echo "Notarized artifact: $(RELEASE_ZIP)"

clean:
	rm -rf .build $(BUILD_DIR)
