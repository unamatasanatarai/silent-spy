.DEFAULT_GOAL := help
.PHONY: help build run launch revoke clean install dmg release release-dry-run

## help: Display this help message
help:
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@awk '/^##/ { printf "  \033[36m%-20s\033[0m %s\n", substr($$2, 1, length($$2)-1), substr($$0, index($$0, $$3)) }' $(MAKEFILE_LIST)

## build: Compile SilentSpy.app and sign binary
build:
	@./build.sh

## run: Launch compiled SilentSpy.app
run: build
	@echo "==> Launching SilentSpy.app..."
	@open build/SilentSpy.app

## launch: Open SilentSpy.app without rebuilding (preserves TCC CDHash)
launch:
	@echo "==> Launching SilentSpy.app (no rebuild)..."
	@open build/SilentSpy.app

## revoke: Reset macOS Microphone & ScreenCapture TCC permissions for com.silentspy.app
revoke:
	@echo "==> Resetting TCC permissions..."
	@tccutil reset Microphone com.silentspy.app 2>/dev/null || true
	@tccutil reset ScreenCapture com.silentspy.app 2>/dev/null || true
	@echo "✅ All permissions revoked."

## clean: Remove build artifacts
clean: revoke
	@echo "==> Cleaning build artifacts..."
	@rm -rf build
	@echo "✅ Clean complete."

## install: Install SilentSpy.app to /Applications
install: build
	@echo "==> Installing SilentSpy.app to /Applications..."
	@rm -rf "/Applications/SilentSpy.app"
	@cp -R "build/SilentSpy.app" /Applications/
	@echo "✅ Installed to /Applications/SilentSpy.app"

## dmg: Create DMG installer package with custom styled background
dmg: build
	@./scripts/build_dmg.sh

## release-dry-run: Preview release tagging and publishing without making remote changes
release-dry-run:
	@./scripts/release.sh --dry-run

## release: Build DMG, create & push tag, and publish GitHub Release with DMG attached
release:
	@./scripts/release.sh




