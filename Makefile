APP := .build/Mic KeepAlive.app
SWIFTC := xcrun swiftc
FLAGS := -target $(shell uname -m)-apple-macosx14.0 -swift-version 5 -framework AppKit -framework AVFoundation

.PHONY: build run test clean

build:
	mkdir -p "$(APP)/Contents/MacOS"
	$(SWIFTC) $(FLAGS) -O Localization.swift main.swift -o "$(APP)/Contents/MacOS/MicKeepAlive"
	mkdir -p "$(APP)/Contents/Resources"
	cp -R Resources/. "$(APP)/Contents/Resources/"
	cp Info.plist "$(APP)/Contents/Info.plist"
	codesign --force --sign - "$(APP)"
	codesign --verify --strict "$(APP)"

run: build
	open "$(APP)"

test:
	mkdir -p .build
	$(SWIFTC) $(FLAGS) Localization.swift main.swift -o .build/MicKeepAlive-test
	cp -R Resources/. .build/
	.build/MicKeepAlive-test --self-test
	.build/MicKeepAlive-test --localization-report -AppleLanguages '(en)'
	.build/MicKeepAlive-test --localization-report -AppleLanguages '(zh-Hans)'
	.build/MicKeepAlive-test --localization-report -AppleLanguages '(zh-Hant)'

clean:
	rm -rf .build
