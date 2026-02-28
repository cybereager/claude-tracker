VERSION  := 1.1.0
APP_NAME := ClaudeScope
BUNDLE   := dist/$(APP_NAME).app
DMG_NAME := dist/$(APP_NAME)-$(VERSION).dmg

.PHONY: all debug release clean

all: debug

# ── Debug build ──────────────────────────────────────────────────────────────

debug:
	swift build

# ── Release: binary + .app bundle + DMG ──────────────────────────────────────

release: dist/$(APP_NAME)-$(VERSION).dmg

dist/$(APP_NAME)-$(VERSION).dmg: $(BUNDLE)
	@echo "→ Creating DMG…"
	@rm -rf dist/dmg-staging
	@mkdir -p dist/dmg-staging
	@cp -r $(BUNDLE) dist/dmg-staging/
	@ln -sf /Applications dist/dmg-staging/Applications
	@cp "Resources/Install $(APP_NAME).command" "dist/dmg-staging/Install $(APP_NAME).command"
	@hdiutil create -volname "$(APP_NAME)" \
	  -srcfolder dist/dmg-staging \
	  -ov -format UDRW -fs HFS+ dist/temp-rw.dmg > /dev/null
	@MOUNT_DIR="/Volumes/$(APP_NAME)"; \
	 hdiutil attach dist/temp-rw.dmg -mountpoint "$$MOUNT_DIR" -nobrowse -quiet; \
	 osascript -e 'tell application "Finder" \
	   to tell disk "$(APP_NAME)" \
	     set current view of container window to icon view; \
	     set toolbar visible of container window to false; \
	     set statusbar visible of container window to false; \
	     set bounds of container window to {100,100,660,400}; \
	     set icon size of icon view options of container window to 100; \
	     set position of item "$(APP_NAME).app" of container window to {130,150}; \
	     set position of item "Applications" of container window to {390,150}; \
	     set position of item "Install $(APP_NAME).command" of container window to {260,280}; \
	     update without registering applications; \
	   end tell' 2>/dev/null || true; \
	 hdiutil detach "$$MOUNT_DIR" -quiet
	@hdiutil convert dist/temp-rw.dmg \
	  -format UDZO -imagekey zlib-level=9 \
	  -o $(DMG_NAME) > /dev/null
	@rm -f dist/temp-rw.dmg
	@rm -rf dist/dmg-staging
	@echo "✓ $(DMG_NAME)"

$(BUNDLE): .build/release/$(APP_NAME)
	@echo "→ Assembling .app bundle…"
	@rm -rf $(BUNDLE)
	@mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	@cp .build/release/$(APP_NAME) $(BUNDLE)/Contents/MacOS/$(APP_NAME)
	@cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	@cp Resources/AppIcon.icns $(BUNDLE)/Contents/Resources/AppIcon.icns
	@codesign --force --deep --sign - $(BUNDLE)
	@echo "✓ $(BUNDLE)"

.build/release/$(APP_NAME):
	@echo "→ Building release binary…"
	@swift build -c release

# ── Clean ─────────────────────────────────────────────────────────────────────

clean:
	@rm -rf dist .build
	@echo "✓ Cleaned"
