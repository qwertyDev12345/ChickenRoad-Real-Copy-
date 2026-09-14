#!/usr/bin/env bash
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${1:-$TESTS_DIR/../../build/routing-tests}"
DESTINATION="${IOS_TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 16}"
mkdir -p "$OUTPUT_DIR"
ruby "$TESTS_DIR/create_project.rb" "$OUTPUT_DIR"
python3 "$TESTS_DIR/redirect_server.py" &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT
# Ensure that our own fixture owns the port; fail if startup exited.
sleep 1
kill -0 "$SERVER_PID"
xcodebuild test -project "$OUTPUT_DIR/RoutingTests.xcodeproj" \
  -scheme RoutingTests -destination "$DESTINATION" \
  -parallel-testing-enabled NO -resultBundlePath "$OUTPUT_DIR/Results-$(date +%s).xcresult" \
  CODE_SIGNING_ALLOWED=NO
