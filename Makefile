.PHONY: help project test test-core test-store test-net check-dead-ui relay-up relay-down test-live build-app test-app test-ui run archive export clean

SIMULATOR ?= platform=iOS Simulator,name=iPhone 17 Pro

# Your Apple Developer team id, for archiving. Find it at
# developer.apple.com/account under Membership, or in Xcode's Signing tab.
# Pass on the command line: make archive DEVELOPMENT_TEAM=ABCDE12345
DEVELOPMENT_TEAM ?=

help:
	@echo "make project    regenerate Comb.xcodeproj from project.yml"
	@echo "make test       run all Swift package tests (no simulator, seconds)"
	@echo "make build-app  build the app for the simulator"
	@echo "make test-app   run the app target's tests in a simulator, and the dead-UI check"
	@echo "make test-ui    run the UI flows in a simulator (minutes, not seconds)"
	@echo "make relay-up   start a real Buzz relay in Docker for the contract suite"
	@echo "make test-live  run the contract suite against that relay as well as the fake"
	@echo "make relay-down stop it and discard its data"
	@echo "make run        build, install, and launch on the booted simulator"
	@echo "make archive    build a signed archive for the App Store (needs DEVELOPMENT_TEAM)"
	@echo "make export     export the archive to a .ipa for upload (needs DEVELOPMENT_TEAM)"
	@echo "make clean      remove build artifacts and the generated project"

# Build and test output is filtered to diagnostics, failures, and the result
# line. The full log lands in .logs/. Set V=1 for the raw firehose.
Q = scripts/quiet.sh

project:
	@$(Q) project xcodegen generate

# The fast loop. Everything protocol-level is verifiable here with no simulator.
test: test-core test-store test-net

test-core:
	@$(Q) test-core swift test --package-path CombCore

test-store:
	@$(Q) test-store swift test --package-path CombStore

test-net:
	@$(Q) test-net swift test --package-path CombNet

# The contract suite against a real Buzz relay in Docker, rather than against
# our model of one. Deliberately not part of `make test`: that loop is seconds
# long and simulator-free, and it stays that way.
#
# The suite runs the same cases either way. Without COMB_LIVE_RELAY it runs
# them against the fake only, so a machine with no Docker is not a failure.
relay-up:
	@scripts/relay/up.sh

relay-down:
	@scripts/relay/down.sh

# The precheck is not politeness. Without it, running this against a stopped
# relay produces a dozen identical connection timeouts that read like a
# protocol disagreement rather than like nothing being there.
test-live:
	@curl -fsS -H 'Accept: application/nostr+json' http://localhost:3030 >/dev/null 2>&1 \
		|| { echo "no relay on localhost:3030. Start one with: make relay-up"; exit 1; }
	@COMB_LIVE_RELAY=ws://localhost:3030 $(Q) test-live swift test --package-path CombNet

# swift-secp256k1 ships a build plugin, which Xcode refuses to run unless trust
# is granted interactively. The skip flags are what make a headless build work.
XCFLAGS = -skipPackagePluginValidation -skipMacroValidation

build-app: project
	@$(Q) build-app xcodebuild build \
		-project Comb.xcodeproj \
		-scheme Comb \
		-destination '$(SIMULATOR)' \
		-derivedDataPath DerivedData \
		$(XCFLAGS)

# Two ways UI dies quietly: state nothing ever fills in, and a property every
# caller passes that the view never reads. Neither costs a build, so this runs
# ahead of the simulator rather than after it.
check-dead-ui:
	@scripts/check-dead-ui.sh

test-app: project check-dead-ui
	@$(Q) test-app xcodebuild test \
		-project Comb.xcodeproj \
		-scheme Comb \
		-destination '$(SIMULATOR)' \
		-derivedDataPath DerivedData \
		-skip-testing:CombUITests \
		$(XCFLAGS)

# The UI flows, on their own, because they are minutes rather than seconds and
# the loop above has to stay usable. Skipped from test-app rather than left out
# of the scheme, so a full `xcodebuild test` in CI still runs everything.
test-ui: project
	@$(Q) test-ui xcodebuild test \
		-project Comb.xcodeproj \
		-scheme Comb \
		-destination '$(SIMULATOR)' \
		-derivedDataPath DerivedData \
		-only-testing:CombUITests \
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
	rm -rf CombCore/.build Comb.xcodeproj build DerivedData .logs
