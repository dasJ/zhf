//! Crawl the full table of all builds from a evaluation

use anyhow::Result;
use reqwest_middleware::ClientBuilder;
use reqwest_retry::{policies::ExponentialBackoff, RetryTransientMiddleware};
use select::node::Node;
use select::predicate::Name;
use std::fs::{create_dir_all, File};
use std::io::Write as _;
use std::collections::HashMap;

#[tokio::main(worker_threads = 4)]
async fn main() -> Result<()> {
    env_logger::builder().format_timestamp(None).init();
    // Handle args
    let mut argv: Vec<(u64, bool)> = Vec::new();
    let mut i = 1;

    let allowed_arch_nixpkgs = ["x86_64-darwin", "aarch64-darwin"];

    let args: Vec<String> = std::env::args().collect();
    while i < args.len() {
        let eval_id = args[i].parse::<u64>().unwrap();
        let eval_nixos = args[i+1].parse::<bool>().unwrap();

        argv.push((eval_id, eval_nixos));
        i+=2;
    }

        log::info!("Will crawl evaluations: {:?}", argv.iter().map(|(e,_)| e).collect::<Vec<_>>());

    // Prepare directories
    let mut data_dir = std::env::current_dir()?;
    data_dir.push("data");
    let mut eval_cache_dir = data_dir.clone();
    eval_cache_dir.push("evalcache");
    create_dir_all(&eval_cache_dir)?;

    let retry_policy = ExponentialBackoff::builder().build_with_max_retries(10);
    let http_client = ClientBuilder::new(reqwest::Client::new())
        .with(RetryTransientMiddleware::new_with_policy(retry_policy))
        .build();

    for (eval_id, eval_nixos) in argv {
        let mut cache_file = eval_cache_dir.clone();
        cache_file.push(format!("{eval_id}.cache"));
        if cache_file.exists() {
            log::info!("Evaluation {eval_id} is already cached");
            continue;
        }

        // Holds all builds by attr name to dedup them
        let mut builds = HashMap::new();

        let res = http_client
            .get(format!("https://hydra.nixos.org/eval/{eval_id}?full=1"))
            .send()
            .await?
            .error_for_status()?
            .text()
            .await?;
        // Parse output
        let doc = select::document::Document::from(&res[..]);

        for table in doc.find(Name("tbody")) {
            for row in table.find(Name("tr")) {
                let cols: Vec<Node> = row.find(Name("td")).collect();
                // Skip input changes
                if cols.is_empty() {
                    continue;
                }
                // Skip removed jobs
                if cols.len() == 2 {
                    continue;
                }
                // Skip inputs
                if cols.len() == 5 {
                    continue;
                }
                // Skip invalid rows
                if cols.len() != 6 {
                    log::warn!("Skipping invalid row with {} columns: {:?}", cols.len(), row);
                    continue;
                }
                if cols[0].find(Name("img")).next().is_none() {
                    continue;
                }
                // Name
                let attr_name = if let Some(attr_name) = cols[2].find(Name("a")).next() { attr_name.text() } else {
                    log::warn!("Job has no attr name: {:?}", row);
                    continue;
                };
                // Status
                let status = if let Some(status) = cols[0].find(Name("img")).next() { status } else {
                    log::warn!("Job has no status: {:?}", row);
                    continue;
                };
                let status = if let Some(status) = status.attr("title") { status } else {
                    log::warn!("Job has no status: {:?}", row);
                    continue;
                };
                // Build ID
                let build_id = if let Some(build_id) = cols[1].find(Name("a")).next() { build_id.text() } else {
                    log::warn!("Job has no build ID: {:?}", row);
                    continue;
                };
                // Package name
                let pkg_name = cols[4].text();
                // Architecture
                let arch = if let Some(arch) = cols[5].find(Name("tt")).next() { arch.text() } else {
                    log::warn!("Job has no architecture: {:?}", row);
                    continue;
                };

                if eval_nixos || allowed_arch_nixpkgs.contains(&arch.as_str()) {
                    builds.insert(attr_name, format!("{build_id} {pkg_name} {arch} {status}"));
                }
            }
        }
        let mut out = File::create(cache_file)?;

        let mut attrs: Vec<_> = builds.keys().into_iter().collect();
        attrs.sort();
        for attr in attrs {
            let build = builds.get(attr).unwrap();
            out.write_fmt(format_args!("{attr} {build}\n"))?;
        }
    }
    Ok(())
}
