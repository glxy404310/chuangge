#!/bin/zsh
set -eu
cd "${0:A:h}"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
xcrun swiftc Layout.swift Tests/main.swift -o "$tmp/tests"
"$tmp/tests"
