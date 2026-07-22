.PHONY: help project test test-core build-app test-app run clean

SIMULATOR ?= platform=iOS Simulator,name=iPhone 17 Pro

help:
	@echo "make project    regenerate Comb.xcodeproj from project.yml"
	@echo "make test       run all Swift package tests (no simulator, seconds)"
	@echo "make build-app  build the app for the simulator"
	@echo "make test-app   run the app target's tests in a simulator"
	@echo "make run        build, install, and launch on the booted simulator"
	@echo "make clean      remove build artifacts and the generated project"

project:
	xcodegen generate

# The fast loop. Everything protocol-level is verifiable here with no simulator.
test: test-core

test-core:
	swift test --package-path CombCore

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

clean:
	rm -rf CombCore/.build Comb.xcodeproj build DerivedData
