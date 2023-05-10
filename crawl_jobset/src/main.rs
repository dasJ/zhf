//! Crawl some data about the latest finished evaluation from the Hydra web interface directly.
//! We need to do this because the API doesn't offer this data.

use anyhow::{anyhow, Result};
use reqwest_middleware::ClientBuilder;
use reqwest_retry::{policies::ExponentialBackoff, RetryTransientMiddleware};
use select::predicate::{Class, Name};

#[tokio::main(worker_threads = 4)]
async fn main() -> Result<()> {
    env_logger::builder().format_timestamp(None).init();
    let argv: Vec<String> = std::env::args().collect();
    let project = &argv[1];
    let jobset = &argv[2];

    let retry_policy = ExponentialBackoff::builder().build_with_max_retries(10);
    let http_client = ClientBuilder::new(reqwest::Client::new())
        .with(RetryTransientMiddleware::new_with_policy(retry_policy))
        .build();

    let res = http_client
        .get(format!(
            "https://hydra.nixos.org/jobset/{project}/{jobset}/evals"
        ))
        .send()
        .await?
        .error_for_status()?
        .text()
        .await?;
    // Parse output
    let doc = select::document::Document::from(&res[..]);
    let eval_table = doc
        .find(Name("tbody"))
        .next()
        .ok_or_else(|| anyhow!("No evaluation table found"))?;
    let eval_rows = eval_table.find(Name("tr"));
    for row in eval_rows {
        // Skip evals with unfinished builds
        if row.find(Class("badge-secondary")).next().is_some() {
            continue;
        }
        // Skip fully failed evals (no builds)
        if row.find(Class("badge-success")).next().is_none() {
            continue;
        }

        println!(
            "{} {}",
            row.find(Name("a"))
                .next()
                .ok_or_else(|| anyhow!("No link found in row"))?
                .text(),
            row.find(Name("time"))
                .next()
                .ok_or_else(|| anyhow!("No time found"))?
                .attr("title")
                .ok_or_else(|| anyhow!("No time found"))?
        );
        return Ok(());
    }

    log::error!("No finished eval found");
    Err(anyhow!("No finished eval found"))
}
