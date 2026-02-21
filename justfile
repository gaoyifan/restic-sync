# Format the Rust code
fmt:
    cargo fmt

# Check the Rust code
check:
    cargo check
    cargo clippy -- -D warnings

# Build the Rust project
build:
    cargo build

# Run the e2e test
test: build
    #!/usr/bin/env bash
    set -euxo pipefail
    
    export RESTIC_PASSWORD="test"
    export REST_SYNC_SOURCE="http://localhost:8000/"
    export REST_SYNC_DEST="http://localhost:8001/"
    
    echo "Preparing test data..."
    docker compose down -v || true
    
    # We still need a local directory to generate the test files to backup into the source repo
    # but we don't need to mount it to the container anymore.
    rm -rf data_test_files
    mkdir -p data_test_files
    
    echo "Starting test servers..."
    docker compose up -d
    echo "Waiting for servers to start..."
    sleep 2
    
    # Initialize source repo via rest-server API or using restic directly
    echo "Initializing source repository"
    
    # Generate some random files
    dd if=/dev/urandom of=data_test_files/file1.bin bs=1M count=1
    dd if=/dev/urandom of=data_test_files/file2.bin bs=2M count=1

    # Initialize source repo using Restic binary to ensure valid structure
    restic -r rest:$REST_SYNC_SOURCE init || true
    restic -r rest:$REST_SYNC_SOURCE backup data_test_files || true

    echo "--- 1. Initial Sync ---"
    cargo run
    
    echo "Verifying destination repo..."
    restic -r rest:$REST_SYNC_DEST check
    
    echo "--- 2. Idempotency Test ---"
    cargo run
    
    echo "--- 3. Pruning Test ---"
    # Create an extra file in dest directly via API (setting Content-Type to avoid 400 Bad Request)
    DUMMY_BLOB_CONTENT="dummy blob"
    DUMMY_BLOB_HASH=$(echo -n "$DUMMY_BLOB_CONTENT" | sha256sum | awk '{print $1}')
    curl -sX POST ${REST_SYNC_DEST}data/${DUMMY_BLOB_HASH} -H "Content-Type: application/octet-stream" --data-binary "$DUMMY_BLOB_CONTENT"
    
    # Verify the dummy file was created (to prevent false positive pruning test)
    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" ${REST_SYNC_DEST}data/${DUMMY_BLOB_HASH})
    if [ "$HTTP_STATUS" != "200" ]; then
        echo "Target mock blob creation failed with status $HTTP_STATUS!"
        exit 1
    fi

    # Run sync with prune
    cargo run -- --prune
    
    # Assert extra file is deleted
    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" ${REST_SYNC_DEST}data/${DUMMY_BLOB_HASH})
    if [ "$HTTP_STATUS" == "200" ]; then
        echo "Pruning failed. File still exists."
        exit 1
    fi

    echo "Tests passed!"
    docker compose down -v
    
    echo "--- 4. Config Corruption Test ---"
    docker compose up -d
    sleep 2
    
    # Initialize mismatched repos
    restic -r rest:$REST_SYNC_SOURCE init || true
    restic -r rest:$REST_SYNC_DEST init || true
    # Alter the destination config slightly to fake a different repo password or init
    curl -sX POST ${REST_SYNC_DEST}config -H "Content-Type: application/octet-stream" --data-binary "mismatched config data" || true
    
    # Run sync, it MUST fail
    if cargo run; then
        echo "Config corruption test failed: Sync tool succeeded despite mismatched configs!"
        exit 1
    else
        echo "Config corruption test passed: Sync properly aborted."
    fi

    docker compose down -v
    rm -rf data_test_files
