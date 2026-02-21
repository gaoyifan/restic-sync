#!/usr/bin/env bash
set -euxo pipefail

source "$(dirname "$0")/common.sh"

echo "=== Test 01: Initial Sync & Prune ==="
setup

echo "  -> Initializing source repository..."
dd if=/dev/urandom of=data_test_files/file1.bin bs=1M count=1
dd if=/dev/urandom of=data_test_files/file2.bin bs=2M count=1

restic -r rest:$REST_SYNC_SOURCE init || true
restic -r rest:$REST_SYNC_SOURCE backup data_test_files || true

echo "  -> Running initial sync..."
cargo run

echo "  -> Verifying destination repository state..."
restic -r rest:$REST_SYNC_DEST check

echo "  -> Running idempotency sync (should not copy data)..."
cargo run

echo "  -> Setting up pruning scenario..."
DUMMY_BLOB_CONTENT="dummy blob"
DUMMY_BLOB_HASH=$(echo -n "$DUMMY_BLOB_CONTENT" | sha256sum | awk '{print $1}')
curl -sX POST ${REST_SYNC_DEST}data/${DUMMY_BLOB_HASH} -H "Content-Type: application/octet-stream" --data-binary "$DUMMY_BLOB_CONTENT"

HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" ${REST_SYNC_DEST}data/${DUMMY_BLOB_HASH})
if [ "$HTTP_STATUS" != "200" ]; then
    echo "     [!] Target mock blob creation failed with status $HTTP_STATUS!"
    exit 1
fi

echo "  -> Running pruning sync..."
cargo run -- --prune

HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" ${REST_SYNC_DEST}data/${DUMMY_BLOB_HASH})
if [ "$HTTP_STATUS" == "200" ]; then
    echo "     [!] Pruning failed. File still exists."
    exit 1
fi

echo "=== Test 01: PASSED ==="
teardown
