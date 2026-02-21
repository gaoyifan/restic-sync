FROM rust:alpine AS builder

WORKDIR /usr/src/restic-sync
RUN apk add --no-cache musl-dev
COPY Cargo.toml Cargo.lock ./
COPY src ./src
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=/usr/src/restic-sync/target \
    cargo build --release && cp target/release/restic-sync /usr/local/bin/restic-sync

FROM alpine:latest
RUN apk add --no-cache ca-certificates \
    && adduser -D appuser
USER appuser
COPY --from=builder /usr/local/bin/restic-sync /usr/local/bin/restic-sync

CMD ["restic-sync"]
