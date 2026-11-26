#!/bin/zsh
set -eu
cd "${0:A:h}"
bundle="$PWD/build/窗格.app"
mkdir -p "$bundle/Contents/MacOS"
cp Info.plist "$bundle/Contents/"
xcrun swiftc -O Layout.swift Windows.swift Panel.swift main.swift -o "$bundle/Contents/MacOS/WindowTiler"
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  if security find-identity -v -p codesigning 2>/dev/null | grep -Fq '"Chuangge Local Sign"'; then
    SIGN_IDENTITY="Chuangge Local Sign"
  else
    SIGN_IDENTITY="-"
  fi
fi
codesign --force --sign "$SIGN_IDENTITY" "$bundle"
