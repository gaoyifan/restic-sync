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
    
    echo "Running tests via run-parts..."
    chmod +x tests/*.sh
    run-parts --exit-on-error --regex '^[0-9]+.*\.sh$' tests
