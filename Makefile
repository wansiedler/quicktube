APP      := QuickTube.app
BIN      := .build/release/QuickTube
PLIST    := Sources/QuickTube/Info.plist
# SwiftPM copies the Sparkle binary framework next to the executable; the executable's rpath
# (@executable_path/../Frameworks, set in Package.swift) finds it in the bundle.
SPARKLE  := .build/release/Sparkle.framework
VERSION  := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' $(PLIST))
DMG_STAGE := build/dmg
DMG      := build/QuickTube-$(VERSION).dmg
# Hardened runtime needs QuickTube.entitlements (audio-input, camera) or the microphone and camera are denied silently.
ENTITLEMENTS := QuickTube.entitlements
# First "Apple Development" identity in the login keychain; ad-hoc ("-") otherwise.
# A stable identity keeps the Screen Recording grant across rebuilds.
IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $$2; exit}')
ifeq ($(IDENTITY),)
IDENTITY := -
endif
SIGN := codesign --force --sign "$(IDENTITY)" --options runtime --timestamp=none
# Hardened runtime enforces library validation: an ad-hoc app has no Team ID, so dyld refuses the
# (also ad-hoc) Sparkle.framework and the app aborts at launch. Ad-hoc builds therefore add
# com.apple.security.cs.disable-library-validation; identity-signed builds share a Team ID and keep
# the plain entitlements.
ifeq ($(IDENTITY),-)
APP_ENTITLEMENTS := QuickTube.adhoc.entitlements
else
APP_ENTITLEMENTS := $(ENTITLEMENTS)
endif

# App icon: Resources/AppIcon.svg -> build/AppIcon.icns. Needs rsvg-convert (brew install librsvg).
ICON_SVG  := Resources/AppIcon.svg
ICONSET   := build/AppIcon.iconset
ICNS      := build/AppIcon.icns
ICON_SIZES := 16 32 128 256 512

.PHONY: build app dmg version icon install test lint clean

build:
	swift build -c release --product QuickTube

icon: $(ICNS)

$(ICNS): $(ICON_SVG)
	rm -rf $(ICONSET)
	mkdir -p $(ICONSET)
	for s in $(ICON_SIZES); do \
	  rsvg-convert -w $$s -h $$s $(ICON_SVG) -o $(ICONSET)/icon_$${s}x$${s}.png; \
	  rsvg-convert -w $$((s*2)) -h $$((s*2)) $(ICON_SVG) -o $(ICONSET)/icon_$${s}x$${s}@2x.png; \
	done
	iconutil -c icns $(ICONSET) -o $(ICNS)

app: build $(ICNS)
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources $(APP)/Contents/Frameworks
	cp $(BIN) $(APP)/Contents/MacOS/QuickTube
	cp $(PLIST) $(APP)/Contents/Info.plist
	cp $(ICNS) $(APP)/Contents/Resources/AppIcon.icns
	ditto $(SPARKLE) $(APP)/Contents/Frameworks/Sparkle.framework
	# Inside out: Sparkle's XPC services and helpers, the framework, then the app. The Downloader
	# service is sandboxed and keeps its own entitlements.
	$(SIGN) $(APP)/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc
	$(SIGN) --preserve-metadata=entitlements $(APP)/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc
	$(SIGN) $(APP)/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate
	$(SIGN) $(APP)/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app
	$(SIGN) $(APP)/Contents/Frameworks/Sparkle.framework
	$(SIGN) --entitlements $(APP_ENTITLEMENTS) $(APP)
	@echo "Signed with: $(IDENTITY)"

# build/QuickTube-<version>.dmg: the app and an Applications link, signed with the same identity.
dmg: app
	rm -rf $(DMG_STAGE) $(DMG)
	mkdir -p $(DMG_STAGE)
	ditto $(APP) $(DMG_STAGE)/$(APP)
	ln -s /Applications $(DMG_STAGE)/Applications
	hdiutil create -volname QuickTube -srcfolder $(DMG_STAGE) -ov -format UDZO $(DMG)
	codesign --force --sign "$(IDENTITY)" --timestamp=none $(DMG)
	@echo "Built $(DMG)"

# CFBundleShortVersionString; the release workflow checks it against the tag.
version:
	@echo $(VERSION)

install: app
	rm -rf /Applications/$(APP)
	cp -R $(APP) /Applications/
	@echo "Installed /Applications/$(APP)"

test:
	swift test --enable-code-coverage

lint:
	xcrun swift-format lint --strict --recursive Package.swift Sources Tests

clean:
	rm -rf .build $(APP) $(DMG_STAGE) build/QuickTube-*.dmg
