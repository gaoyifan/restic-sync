use anyhow::{bail, Context, Result};
use clap::Parser;
use log::{debug, info, warn};
use reqwest::{Client, StatusCode};
use reqwest_middleware::{ClientBuilder, ClientWithMiddleware};
use reqwest_retry::{policies::ExponentialBackoff, RetryTransientMiddleware};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::collections::HashMap;

/// Synchronizes a Restic REST repository to another.
#[derive(Parser, Debug, Clone)]
#[command(author, version, about, long_about = None)]
struct Args {
    /// Source Restic REST repository URL
    #[arg(long, env = "REST_SYNC_SOURCE")]
    source: String,

    /// Destination Restic REST repository URL
    #[arg(long, env = "REST_SYNC_DEST")]
    dest: String,

    /// Delete files in the destination that do not exist in the source
    #[arg(long, default_value_t = false)]
    prune: bool,

    /// Cron expression for periodic sync (e.g., "0 0 * * * *")
    #[arg(long, env = "REST_SYNC_CRON")]
    cron: Option<String>,
}

#[derive(Deserialize, Debug, Clone)]
struct FileInfo {
    name: String,
    size: u64,
}

const FILE_TYPES: &[&str] = &["data", "keys", "locks", "snapshots", "index"];

#[tokio::main]
async fn main() -> Result<()> {
    env_logger::init();
    let args = Args::parse();

    if let Some(cron_expr) = &args.cron {
        use tokio_cron_scheduler::{Job, JobScheduler};
        
        info!("Starting scheduled sync with cron: {}", cron_expr);
        let sched = JobScheduler::new().await?;
        
        let args_clone = args.clone();
        let job = Job::new_async(cron_expr.as_str(), move |uuid, _l| {
            let args = args_clone.clone();
            Box::pin(async move {
                info!("Running scheduled sync job {}", uuid);
                if let Err(e) = run_sync(&args).await {
                    warn!("Scheduled sync failed: {:?}", e);
                }
            })
        })?;
        
        sched.add(job).await?;
        sched.start().await?;
        
        // Wait forever
        tokio::signal::ctrl_c().await?;
        info!("Shutting down scheduled sync...");
    } else {
        run_sync(&args).await?;
    }

    Ok(())
}

async fn run_sync(args: &Args) -> Result<()> {
    let source = normalize_url(&args.source);
    let dest = normalize_url(&args.dest);

    info!("Source: {}", source);
    info!("Dest: {}", dest);
    info!("Prune: {}", args.prune);

    let retry_policy = ExponentialBackoff::builder().build_with_max_retries(5);
    let client = ClientBuilder::new(Client::new())
        .with(RetryTransientMiddleware::new_with_policy(retry_policy))
        .build();

    // 1. Initialize destination repository
    init_dest(&client, &dest).await?;

    // 2. Sync config file
    sync_config(&client, &source, &dest).await?;

    // 3. Sync each file type
    for file_type in FILE_TYPES {
        sync_type(&client, &source, &dest, file_type, args.prune).await?;
    }

    info!("Synchronization complete.");
    Ok(())
}

fn normalize_url(url: &str) -> String {
    if url.ends_with('/') {
        url.to_string()
    } else {
        format!("{}/", url)
    }
}

async fn init_dest(client: &ClientWithMiddleware, dest: &str) -> Result<()> {
    let url = format!("{}?create=true", dest);
    info!("Ensuring destination repository exists: {}", url);
    let resp = client.post(&url).send().await?;
    if !resp.status().is_success() {
        bail!("Failed to create/verify dest repository: {}", resp.status());
    }
    Ok(())
}

async fn sync_config(client: &ClientWithMiddleware, source: &str, dest: &str) -> Result<()> {
    let source_url = format!("{}config", source);
    let dest_url = format!("{}config", dest);

    info!("Syncing config file");

    let resp = client.get(&source_url).send().await?;
    if !resp.status().is_success() {
        if resp.status() == StatusCode::NOT_FOUND {
            warn!("Config file not found in source repository.");
            return Ok(());
        }
        bail!("Failed to fetch config from source: {}", resp.status());
    }

    let config_bytes = resp.bytes().await?;

    let post_resp = client.post(&dest_url).body(config_bytes.clone()).send().await?;
    if !post_resp.status().is_success() {
        if post_resp.status() == StatusCode::FORBIDDEN {
            // rest-server returns 403 when trying to overwrite an existing config.
            // We MUST verify that the destination config matches the source config.
            debug!("Config file exists (403). Fetching destination config to ensure match.");
            let dest_get = client.get(&dest_url).send().await?;
            if dest_get.status().is_success() {
                let dest_bytes = dest_get.bytes().await?;
                if dest_bytes != config_bytes {
                    bail!("Destination config file already exists and DOES NOT MATCH source config! Aborting to prevent repository corruption.");
                }
                info!("Destination config file matches source config.");
                return Ok(());
            } else {
                bail!("Failed to read existing configuration from destination to verify it: {}", dest_get.status());
            }
        }
        bail!("Failed to save config to destination: {}", post_resp.status());
    }

    Ok(())
}

async fn list_files(client: &ClientWithMiddleware, repo: &str, file_type: &str) -> Result<Vec<FileInfo>> {
    let url = format!("{}{}/", repo, file_type);
    debug!("Listing files for {}: {}", file_type, url);

    let resp = client
        .get(&url)
        .header("Accept", "application/vnd.x.restic.rest.v2")
        .send()
        .await?;

    if !resp.status().is_success() {
        if resp.status() == StatusCode::NOT_FOUND {
            return Ok(vec![]);
        }
        bail!("Failed to list generic files {}: {}", url, resp.status());
    }

    // Attempt to parse as v2 JSON array
    let text = resp.text().await?;
    let items: Vec<FileInfo> = serde_json::from_str(&text).with_context(|| {
        format!(
            "Failed to parse v2 JSON response from {} for type {}",
            url, file_type
        )
    })?;

    Ok(items)
}

async fn sync_type(
    client: &ClientWithMiddleware,
    source: &str,
    dest: &str,
    file_type: &str,
    prune: bool,
) -> Result<()> {
    info!("Syncing type: {}", file_type);

    let source_items = list_files(client, source, file_type).await?;
    let dest_items = list_files(client, dest, file_type).await?;

    let source_map: HashMap<String, u64> = source_items
        .into_iter()
        .map(|item| (item.name, item.size))
        .collect();
    let dest_map: HashMap<String, u64> = dest_items
        .into_iter()
        .map(|item| (item.name, item.size))
        .collect();

    // Identify missing
    let mut to_download = Vec::new();
    for (name, size) in &source_map {
        if let Some(dest_size) = dest_map.get(name) {
            if size != dest_size {
                to_download.push(name.clone());
            }
        } else {
            to_download.push(name.clone());
        }
    }

    // Identify extra
    let mut to_delete = Vec::new();
    if prune {
        for name in dest_map.keys() {
            if !source_map.contains_key(name) {
                to_delete.push(name.clone());
            }
        }
    }

    info!(
        "[{}] Found {} missing blobs, {} extra blobs",
        file_type,
        to_download.len(),
        to_delete.len()
    );

    // Sync missing sequentially
    for name in to_download {
        info!("[{}] Syncing file: {}", file_type, name);
        sync_file(client, source, dest, file_type, &name).await?;
    }

    // Delete extra sequentially
    if prune {
        for name in to_delete {
            info!("[{}] Deleting extra file: {}", file_type, name);
            delete_file(client, dest, file_type, &name).await?;
        }
    }

    Ok(())
}

async fn sync_file(
    client: &ClientWithMiddleware,
    source: &str,
    dest: &str,
    file_type: &str,
    name: &str,
) -> Result<()> {
    let source_url = format!("{}{}/{}", source, file_type, name);
    let dest_url = format!("{}{}/{}", dest, file_type, name);

    // Download blob into memory
    let resp = client.get(&source_url).send().await?;
    if !resp.status().is_success() {
        bail!("Failed to download {}: {}", source_url, resp.status());
    }

    let bytes = resp.bytes().await?;

    // Compute SHA256 sum
    let mut hasher = Sha256::new();
    hasher.update(&bytes);
    let result = hasher.finalize();
    let hash_hex = format!("{:x}", result);

    if hash_hex != name {
        bail!(
            "Blob verification failed for {}. Expected hash: {}, Got: {}",
            name,
            name,
            hash_hex
        );
    }

    // Upload verified blob
    let post_resp = client.post(&dest_url).body(bytes).send().await?;
    if !post_resp.status().is_success() {
        bail!("Failed to upload to {}: {}", dest_url, post_resp.status());
    }

    Ok(())
}

async fn delete_file(client: &ClientWithMiddleware, dest: &str, file_type: &str, name: &str) -> Result<()> {
    let url = format!("{}{}/{}", dest, file_type, name);
    let resp = client.delete(&url).send().await?;
    if !resp.status().is_success() {
        bail!("Failed to delete {}: {}", url, resp.status());
    }
    Ok(())
}
