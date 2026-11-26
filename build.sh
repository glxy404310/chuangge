#!/bin/zsh
set -eu
cd "${0:A:h}"
bundle="$PWD/build/窗格.app"
mkdir -p "$bundle/Contents/MacOS"
cp Info.plist "$bundle/Contents/"
xcrun swiftc -O Layout.swift Windows.swift Panel.swift main.swift -o "$bundle/Contents/MacOS/WindowTiler"
codesign --force --sign "${SIGN_IDENTITY:--}" "$bundle"
