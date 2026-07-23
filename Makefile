.PHONY: help project test test-core test-store test-net build-app test-app run archive export clean

SIMULATOR ?= platform=iOS Simulator,name=iPhone 17 Pro

# Your Apple Developer team id, for archiving. Find it at
# developer.apple.com/account under Membership, or in Xcode's Signing tab.
# Pass on the command line: make archive DEVELOPMENT_TEAM=ABCDE12345
DEVELOPMENT_TEAM ?=

help:
	@echo "make project    regenerate Comb.xcodeproj from project.yml"
	@echo "make test       run all Swift package tests (no simulator, seconds)"
	@echo "make build-app  build the app for the simulator"
	@echo "make test-app   run the app target's tests in a simulator"
	@echo "make run        build, install, and launch on the booted simulator"
	@echo "make archive    build a signed archive for the App Store (needs DEVELOPMENT_TEAM)"
	@echo "make export     export the archive to a .ipa for upload (needs DEVELOPMENT_TEAM)"
	@echo "make clean      remove build artifacts and the generated project"

project:
	xcodegen generate

# The fast loop. Everything protocol-level is verifiable here with no simulator.
test: test-core test-store test-net

test-core:
	swift test --package-path CombCore

test-store:
	swift test --package-path CombStore

test-net:
	swift test --package-path CombNet

# swift-secp256k1 ships a build plugin, which Xcode refuses to run unless trust
# is granted interactively. The skip flags are what make a headless build work.
XCFLAGS = -skipPackagePluginValidation -skipMacroValidation

build-app: project
	xcodebuild build \
		-project Comb.xcodeproj \
		-scheme Comb \
		-destination '$(SIMULATOR)' \
		-derivedDataPath DerivedData \
		$(XCFLAGS)

test-app: project
	xcodebuild test \
		-project Comb.xcodeproj \
		-scheme Comb \
		-destination '$(SIMULATOR)' \
		-derivedDataPath DerivedData \
		$(XCFLAGS)

# Build, install, launch, and screenshot on a booted simulator.
run: build-app
	xcrun simctl install booted DerivedData/Build/Products/Debug-iphonesimulator/Comb.app
	xcrun simctl launch booted dev.jedbridges.comb

# Release build for the App Store. Automatic signing fetches or creates the
# distribution certificate and profile from your team, which is why the team id
# is required and -allowProvisioningUpdates is set.
archive: project
	@test -n "$(DEVELOPMENT_TEAM)" || { echo "error: set DEVELOPMENT_TEAM (see 'make help')"; exit 1; }
	xcodebuild archive \
		-project Comb.xcodeproj \
		-scheme Comb \
		-configuration Release \
		-destination 'generic/platform=iOS' \
		-archivePath build/Comb.xcarchive \
		-allowProvisioningUpdates \
		DEVELOPMENT_TEAM=$(DEVELOPMENT_TEAM) \
		CODE_SIGN_STYLE=Automatic \
		$(XCFLAGS)

# Turns the archive into an uploadable .ipa under build/export/. Upload it with
# Xcode's Organizer, Transporter, or: xcrun altool / notarytool as you prefer.
export: archive
	xcodebuild -exportArchive \
		-archivePath build/Comb.xcarchive \
		-exportPath build/export \
		-exportOptionsPlist ExportOptions.plist \
		-allowProvisioningUpdates
	@echo "Exported to build/export/. Upload the .ipa to App Store Connect."

# Archives and delivers straight to App Store Connect over Xcode's
# authenticated session. Needs the app record to exist there first.
upload: archive
	xcodebuild -exportArchive \
		-archivePath build/Comb.xcarchive \
		-exportOptionsPlist ExportOptionsUpload.plist \
		-allowProvisioningUpdates
	@echo "Uploaded. Processing takes 5-30 minutes; watch the TestFlight tab."

clean:
	rm -rf CombCore/.build Comb.xcodeproj build DerivedData
