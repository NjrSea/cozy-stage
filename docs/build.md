# Building Cozy Stage from source

Requirements: macOS 14+, Swift 6.1+ toolchain (Xcode 16.3+).

## Run in development mode

    swift build
    swift run ScreenSwitcherApp

On first launch the app requests Accessibility permission (System Settings →
Privacy & Security → Accessibility). Window switching reads window metadata
through the Accessibility system, nothing else.

## Run the test suite

    swift test

## Package a runnable .app bundle (ad-hoc signed, for local use)

    swift build -c release
    mkdir -p "Cozy Stage.app/Contents/MacOS" "Cozy Stage.app/Contents/Resources"
    cp App/Info.plist "Cozy Stage.app/Contents/Info.plist"
    cp .build/release/ScreenSwitcherApp "Cozy Stage.app/Contents/MacOS/"
    cp App/Resources/AppIcon.icns "Cozy Stage.app/Contents/Resources/"
    codesign --force --sign - "Cozy Stage.app"
    open "Cozy Stage.app"

The ad-hoc signature keeps Gatekeeper quiet for local builds only. It is not
a Developer ID distribution signature.
