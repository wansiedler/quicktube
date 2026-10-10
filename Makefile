APP      := QuickTube.app
BIN      := .build/release/QuickTube
PLIST    := Sources/QuickTube/Info.plist
# First "Apple Development" identity in the login keychain; ad-hoc ("-") otherwise.
# A stable identity keeps the Screen Recording grant across rebuilds.
IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $$2; exit}')
ifeq ($(IDENTITY),)
IDENTITY := -
endif

.PHONY: build app install test lint clean

build:
	swift build -c release --product QuickTube

app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp $(BIN) $(APP)/Contents/MacOS/QuickTube
	cp $(PLIST) $(APP)/Contents/Info.plist
	codesign --force --sign "$(IDENTITY)" --options runtime --timestamp=none $(APP)
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
