#!/usr/bin/env bash
set -euxo pipefail

source "$(dirname "$0")/common.sh"

echo "=== Test 03: Dockerized Cron Sync ==="
setup

echo "  -> Initializing source repository..."
dd if=/dev/urandom of=data_test_files/docker_test.bin bs=1M count=1

restic -r rest:$REST_SYNC_SOURCE init || true
restic -r rest:$REST_SYNC_SOURCE backup data_test_files || true

echo "  -> Building and starting background synchronization container..."
docker compose up -d --build sync

echo "  -> Waiting for cron job to trigger (around 10s)..."
sleep 10

echo "  -> Verifying Docker cron synchronization..."
if restic -r rest:$REST_SYNC_DEST check; then
    echo "  -> Background sync verified."
else
    echo "     [!] Dockerized cron sync test failed!"
    docker compose logs sync
    exit 1
fi

echo "=== Test 03: PASSED ==="
teardown
