#!/usr/bin/env bash
set -euxo pipefail

source "$(dirname "$0")/common.sh"

echo "=== Test 02: Config Corruption ==="
setup

echo "  -> Initializing independent and mismatched repositories..."
restic -r rest:$REST_SYNC_SOURCE init || true
restic -r rest:$REST_SYNC_DEST init || true
curl -sX POST ${REST_SYNC_DEST}config -H "Content-Type: application/octet-stream" --data-binary "mismatched config data" || true

echo "  -> Attempting synchronization with mismatch configs (expected to fail)..."
if cargo run; then
    echo "     [!] Config corruption test failed: Sync tool succeeded despite mismatched configs!"
    exit 1
else
    echo "  -> Sync properly aborted."
fi

echo "=== Test 02: PASSED ==="
teardown
