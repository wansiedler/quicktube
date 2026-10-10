APP      := QuickTube.app
BIN      := .build/release/QuickTube
PLIST    := Sources/QuickTube/Info.plist
# Hardened runtime needs QuickTube.entitlements (audio-input, camera) or the microphone and camera are denied silently.
ENTITLEMENTS := QuickTube.entitlements
# First "Apple Development" identity in the login keychain; ad-hoc ("-") otherwise.
# A stable identity keeps the Screen Recording grant across rebuilds.
IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $$2; exit}')
ifeq ($(IDENTITY),)
IDENTITY := -
endif

# App icon: Resources/AppIcon.svg -> build/AppIcon.icns. Needs rsvg-convert (brew install librsvg).
ICON_SVG  := Resources/AppIcon.svg
ICONSET   := build/AppIcon.iconset
ICNS      := build/AppIcon.icns
ICON_SIZES := 16 32 128 256 512

.PHONY: build app icon install test lint clean

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
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BIN) $(APP)/Contents/MacOS/QuickTube
	cp $(PLIST) $(APP)/Contents/Info.plist
	cp $(ICNS) $(APP)/Contents/Resources/AppIcon.icns
	codesign --force --sign "$(IDENTITY)" --options runtime --entitlements $(ENTITLEMENTS) --timestamp=none $(APP)
	@echo "Signed with: $(IDENTITY)"

install: app
	rm -rf /Applications/$(APP)
	cp -R $(APP) /Applications/
	@echo "Installed /Applications/$(APP)"

test:
	swift test --enable-code-coverage

lint:
	xcrun swift-format lint --strict --recursive Package.swift Sources Tests

clean:
	rm -rf .build $(APP)
