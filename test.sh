#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
TEST_DIR=$(mktemp -d /private/tmp/course-player-tests.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT

/usr/bin/swiftc \
  -swift-version 5 \
  -parse-as-library \
  -module-cache-path "$TEST_DIR/module-cache" \
  "$SCRIPT_DIR/Models.swift" \
  "$SCRIPT_DIR/Tests/DataDurabilityTests.swift" \
  -o "$TEST_DIR/data-durability-tests"

"$TEST_DIR/data-durability-tests"
