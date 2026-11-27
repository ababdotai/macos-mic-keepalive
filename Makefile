APP := .build/KeepMicAlive.app
SWIFTC := xcrun swiftc
FLAGS := -target $(shell uname -m)-apple-macosx14.0 -swift-version 5 -framework AppKit -framework AVFoundation -framework ServiceManagement -framework CoreAudio -framework AudioToolbox -framework Accelerate

.PHONY: build run test test-enhancement-loopback release clean

build:
	mkdir -p "$(APP)/Contents/MacOS"
	$(SWIFTC) $(FLAGS) -O Localization.swift RecoveryPolicy.swift SystemAudio.swift VoiceProcessing.swift Enhancement.swift UpdateSupport.swift Updates.swift UpdateInstaller.swift ControlPanel.swift main.swift -o "$(APP)/Contents/MacOS/KeepMicAlive"
	mkdir -p "$(APP)/Contents/Resources"
	cp -R Resources/. "$(APP)/Contents/Resources/"
	cp Info.plist "$(APP)/Contents/Info.plist"
	python3 scripts/build_icon.py "$(APP)"
	mkdir -p "$(APP)/Contents/Helpers"
	$(SWIFTC) -target $(shell uname -m)-apple-macosx14.0 -swift-version 5 -O -framework AppKit UpdateSupport.swift helpers/Updater/main.swift -o "$(APP)/Contents/Helpers/KeepMicAliveUpdater"
	codesign --force --sign - "$(APP)/Contents/Helpers/KeepMicAliveUpdater"
	codesign --force --sign - "$(APP)"
	codesign --verify --strict "$(APP)"

run: build
	open "$(APP)"

test:
	mkdir -p .build
	cp -R Resources/. .build/
	$(SWIFTC) -swift-version 5 Localization.swift UpdateSupport.swift Updates.swift tests/Updates/main.swift -o .build/updates-test
	.build/updates-test
	$(SWIFTC) -swift-version 5 UpdateSupport.swift tests/UpdateInstall/main.swift -o .build/update-install-test
	.build/update-install-test
	$(SWIFTC) -swift-version 5 -framework Accelerate VoiceProcessing.swift tests/VoiceProcessing/main.swift -o .build/voice-processing-test
	.build/voice-processing-test
	$(SWIFTC) $(FLAGS) Localization.swift RecoveryPolicy.swift SystemAudio.swift VoiceProcessing.swift Enhancement.swift UpdateSupport.swift Updates.swift UpdateInstaller.swift ControlPanel.swift main.swift -o .build/KeepMicAlive-test
	cp -R Resources/. .build/
	.build/KeepMicAlive-test --self-test
	.build/KeepMicAlive-test --localization-report -AppleLanguages '(en)'
	.build/KeepMicAlive-test --localization-report -AppleLanguages '(zh-Hans)'
	.build/KeepMicAlive-test --localization-report -AppleLanguages '(zh-Hant)'

release: test
	python3 scripts/package_release.py

clean:
	rm -rf .build

# Explicit opt-in: sends a quiet synthetic tone only to BlackHole and reads it back.
test-enhancement-loopback:
	mkdir -p .build
	$(SWIFTC) $(FLAGS) -DROUTING_TESTS Localization.swift SystemAudio.swift VoiceProcessing.swift Enhancement.swift tests/EnhancementLoopback/main.swift -o .build/enhancement-check
	cp -R Resources/. .build/
	.build/enhancement-check
