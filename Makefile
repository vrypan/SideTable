PROJECT = Sidetable.xcodeproj
SCHEME = Sidetable
APP = build/Build/Products/Debug/SideTable.app
XCODE = xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath build -destination 'platform=macOS' CODE_SIGN_IDENTITY=-

.PHONY: build run preview test-core test-app test-ui check generate

build:
	$(XCODE) -configuration Debug build

run: build
	open "$(APP)"

preview: build
	open -n "$(APP)" --args --preview

test-core:
	swift test --package-path Packages/ApronCore

test-app:
	$(XCODE) -only-testing:SidetableTests test

test-ui:
	$(XCODE) -only-testing:SidetableUITests -test-timeouts-enabled YES -default-test-execution-time-allowance 30 -maximum-test-execution-time-allowance 60 test

check: test-core build

generate:
	xcodegen generate
