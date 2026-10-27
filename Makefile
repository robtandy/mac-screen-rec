# mac-screen-rec build
#
#   make            build the app (native arch)      -> build/MacScreenRec.app
#   make install    build + copy into /Applications
#   make release    universal (arm64 + x86_64) build -> dist/*.zip
#   make smoke      build + launch briefly to verify it runs
#
# Requires Xcode Command Line Tools. The universal target must run on
# Apple Silicon (x86_64 cross-compiles from arm64; not the reverse).

VERSION   := 1.0.0
APP_NAME  := MacScreenRec
BUNDLE_ID := com.robtandy.MacScreenRec
MIN_MACOS := 13.0

BUILD := build
DIST  := dist
APP   := $(BUILD)/$(APP_NAME).app
SRCS  := $(wildcard Sources/*.swift)
ARCH  := $(shell uname -m)

.PHONY: all app universal release install clean smoke

all: app

$(BUILD)/$(APP_NAME): $(SRCS)
	@mkdir -p $(BUILD)
	swiftc -O -target $(ARCH)-apple-macos$(MIN_MACOS) -o $@ $(SRCS)

$(APP): $(BUILD)/$(APP_NAME) $(BUILD)/AppIcon.icns App/Info.plist
	@rm -rf $(APP)
	@mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	@cp $(BUILD)/$(APP_NAME) $(APP)/Contents/MacOS/$(APP_NAME)
	@sed -e 's|@EXECUTABLE@|$(APP_NAME)|g' \
	     -e 's|@BUNDLE_ID@|$(BUNDLE_ID)|g' \
	     -e 's|@VERSION@|$(VERSION)|g' App/Info.plist > $(APP)/Contents/Info.plist
	@if [ -f $(BUILD)/AppIcon.icns ]; then cp $(BUILD)/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns; fi
	@codesign --force --sign - $(APP)
	@echo "Built $(APP)"

app: $(APP)

universal:
	@mkdir -p $(BUILD)
	swiftc -O -target arm64-apple-macos$(MIN_MACOS) -o $(BUILD)/$(APP_NAME)-arm64 $(SRCS)
	swiftc -O -target x86_64-apple-macos$(MIN_MACOS) -o $(BUILD)/$(APP_NAME)-x86_64 $(SRCS)
	lipo -create -output $(BUILD)/$(APP_NAME) $(BUILD)/$(APP_NAME)-arm64 $(BUILD)/$(APP_NAME)-x86_64
	@$(MAKE) --no-print-directory $(APP)

release: universal
	@mkdir -p $(DIST)
	ditto -c -k --keepParent $(APP) $(DIST)/$(APP_NAME)-$(VERSION)-universal-macos.zip
	shasum -a 256 $(DIST)/$(APP_NAME)-$(VERSION)-universal-macos.zip > $(DIST)/$(APP_NAME)-$(VERSION)-SHA256.txt
	@echo "Release artifact in $(DIST)/"

install: app
	@if ditto $(APP) /Applications/ 2>/dev/null; then \
		echo "Installed: /Applications/$(APP_NAME).app"; \
	else \
		mkdir -p ~/Applications; \
		ditto $(APP) ~/Applications/; \
		echo "Installed: ~/Applications/$(APP_NAME).app"; \
	fi

smoke: app
	$(APP)/Contents/MacOS/$(APP_NAME) --smoke

$(BUILD)/AppIcon.icns: Scripts/IconGen.swift
	@mkdir -p $(BUILD)
	swift Scripts/IconGen.swift $(BUILD)/icon-1024.png
	@rm -rf $(BUILD)/AppIcon.iconset && mkdir -p $(BUILD)/AppIcon.iconset
	@for sz in 16 32 64 128 256 512; do \
		sips -z $$sz $$sz $(BUILD)/icon-1024.png --out $(BUILD)/AppIcon.iconset/icon_$${sz}x$${sz}.png >/dev/null; \
		sips -z $$((sz*2)) $$((sz*2)) $(BUILD)/icon-1024.png --out $(BUILD)/AppIcon.iconset/icon_$${sz}x$${sz}@2x.png >/dev/null; \
	done
	iconutil -c icns -o $@ $(BUILD)/AppIcon.iconset

clean:
	rm -rf $(BUILD) $(DIST)
