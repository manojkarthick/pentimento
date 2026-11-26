PROJECT := Pentimento.xcodeproj
SCHEME := Pentimento
DERIVED := build
APP := $(DERIVED)/Build/Products/Release/Pentimento.app
# Extra build settings, e.g. MARKETING_VERSION=0.1.0 (script/release.sh sets the version this way).
XCODEBUILD_FLAGS ?=
XCODEBUILD := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath $(DERIVED) CODE_SIGNING_ALLOWED=NO $(XCODEBUILD_FLAGS)

.DEFAULT_GOAL := help
.PHONY: help exiftool generate build test run dist release clean

help: ## Show this list of commands
	@grep -E '^[a-z]+:.*## ' $(MAKEFILE_LIST) | awk -F ':.*## ' '{printf "  make %-10s %s\n", $$1, $$2}'

exiftool: ## Download the pinned ExifTool into Pentimento/Resources/ExifTool
	script/fetch_exiftool.sh

# The project file is generated from project.yml, so regenerate before every build
# to pick up added or removed source files.
generate: exiftool ## Regenerate the Xcode project from project.yml
	xcodegen generate

build: generate ## Release build
	$(XCODEBUILD) -configuration Release build

test: generate ## Debug build and run the tests
	$(XCODEBUILD) -configuration Debug test

run: build ## Build, then open the app
	open $(APP)

dist: build ## Build, then copy the app to dist/Pentimento.app
	rm -rf dist/Pentimento.app
	mkdir -p dist
	ditto $(APP) dist/Pentimento.app

release: ## Build a signed DMG, e.g. make release VERSION=0.1.0
	PENTIMENTO_VERSION=$(VERSION) script/release.sh

clean: ## Delete build output
	rm -rf $(DERIVED) dist
