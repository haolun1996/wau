#!/bin/sh
# Runs every test suite: the Core and Storage packages, then the app's tests.
set -eu
cd "$(dirname "$0")/.."
echo "== Core";    (cd Packages/Core && swift test 2>&1 | grep -E "✘|error:|Test run")
echo "== Storage"; (cd Packages/Storage && swift test 2>&1 | grep -E "✘|error:|Test run")
echo "== Sync";    (cd Packages/Sync && swift test 2>&1 | grep -E "✘|error:|Test run")
echo "== App"
xcodegen generate >/dev/null
xcodebuild -project Wau.xcodeproj -scheme Wau -configuration Debug -derivedDataPath build test 2>&1 \
  | grep -E "\.swift:[0-9]+:[0-9]+: error:|✘|Test run|TEST (SUCCEEDED|FAILED)"
