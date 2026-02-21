#!/usr/bin/env bash

# Common environment variables ensuring independent execution
export RESTIC_PASSWORD="test"
export REST_SYNC_SOURCE="http://localhost:8000/"
export REST_SYNC_DEST="http://localhost:8001/"

setup() {
    echo "=> Setting up test environment..."
    docker compose down -v || true
    rm -rf data_test_files
    mkdir -p data_test_files

    docker compose up -d rest-server-source rest-server-dest
    echo "=> Waiting for servers to start..."
    sleep 2
}

teardown() {
    echo "=> Tearing down test environment..."
    docker compose down -v
    rm -rf data_test_files
}
