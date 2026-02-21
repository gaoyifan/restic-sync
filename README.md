# restic-sync

`restic-sync` is a simple and efficient command-line tool written in Rust to synchronize one [Restic](https://restic.net/) REST repository to another. It communicates directly with the Restic REST Server API to duplicate data securely and reliably.

## Features

- **Direct Synchronization:** Syncs the config file, data blobs, keys, locks, snapshots, and indexes between a source and a destination REST server.
- **Safety Checks:** Verifies destination config file matches the source to prevent repository corruption.
- **Pruning:** Option to `--prune` (delete) files in the destination repository that no longer exist in the source.
- **Data Integrity:** Computes SHA-256 sums of downloaded blobs and verifies them before uploading to the destination.
- **Scheduled Sync:** Built-in asynchronous periodic synchronization using cron expressions.
- **Docker Ready:** Built with Alpine Linux and `musl`, delivering a minimal final image form factor.

## Requirements

- [Rust](https://rustup.rs/) (edition 2024, generally Rust 1.85+)
- Or [Docker](https://docs.docker.com/engine/install/) / Docker Compose

## Installation

### From Source

Clone the repository and build the binary using Cargo:

```bash
git clone https://github.com/gaoyifan/restic-sync.git
cd restic-sync
cargo build --release
```

The compiled binary will be available at `target/release/restic-sync`.

## Usage

```bash
restic-sync --source <SOURCE_URL> --dest <DEST_URL> [OPTIONS]
```

### Options

| Argument | Environment Variable | Description |
| :--- | :--- | :--- |
| `--source <URL>` | `REST_SYNC_SOURCE` | Source Restic REST repository URL (e.g., `http://source:8000/`) |
| `--dest <URL>` | `REST_SYNC_DEST` | Destination Restic REST repository URL (e.g., `http://dest:8000/`) |
| `--prune` | | Delete files in the destination that do not exist in the source |
| `--cron <CRON>` | `REST_SYNC_CRON` | Cron expression for periodic sync (e.g., `0 0 * * * *`) |

### Example

To perform a one-time synchronization and delete extra data at the destination:
```bash
restic-sync \
  --source http://rest-server-1:8000 \
  --dest http://rest-server-2:8000 \
  --prune
```

To schedule a synchronization job that runs at midnight every day:
```bash
restic-sync \
  --source http://rest-server-1:8000 \
  --dest http://rest-server-2:8000 \
  --cron "0 0 0 * * * *"
```

## Docker Compose

You can deploy `restic-sync` using Docker and Docker Compose. A sample `docker-compose.yml` is provided in the repository which provisions a local source REST server, a local destination REST server, and the synchronization service.

```yaml
services:
  rest-server-source:
    image: restic/rest-server:latest
    ports:
      - "8000:8000"
    environment:
      - DISABLE_AUTHENTICATION=1
    volumes:
      - source-data:/data

  rest-server-dest:
    image: restic/rest-server:latest
    ports:
      - "8001:8000"
    environment:
      - DISABLE_AUTHENTICATION=1
    volumes:
      - dest-data:/data

  sync:
    build: .
    environment:
      - REST_SYNC_SOURCE=http://rest-server-source:8000/
      - REST_SYNC_DEST=http://rest-server-dest:8000/
      - REST_SYNC_CRON=1/5 * * * * * # Runs every 5 seconds for testing
    depends_on:
      - rest-server-source
      - rest-server-dest

volumes:
  source-data:
  dest-data:
```

Run the stack locally:
```bash
docker-compose up -d --build
```
## License

MIT License. See the [Cargo.toml](Cargo.toml) file for details.
