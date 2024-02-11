//! Renders the per-maintainer pages and overviews
use anyhow::Result;
use std::collections::HashMap;
use std::fs::{create_dir_all, read_to_string, File};
use std::io::Write as _;

struct Build {
    attr: String,
    build_id: u64,
    name: String,
    arch: String,
    status: String,
    maintainer: String,
}

fn main() -> Result<()> {
    env_logger::builder().format_timestamp(None).init();
    // Handle args
    let argv: Vec<u64> = std::env::args()
        .skip(1)
        .map(|x| x.parse::<u64>().unwrap())
        .collect();
    log::info!("Will generate evaluations: {:?}", argv);

    // Prepare directories
    let mut data_dir = std::env::current_dir()?;
    data_dir.push("data");
    let mut maintainers_cache = data_dir.clone();
    maintainers_cache.push("maintainerscache");
    let mut out_dir = std::env::current_dir()?;
    out_dir.push("public");
    out_dir.push("failed");
    out_dir.push("by-maintainer");
    create_dir_all(&out_dir)?;

    // Read the cache
    let mut maintainers: HashMap<String, Vec<Build>> = HashMap::new();
    for eval in argv {
        // Read maintainers cache
        let mut cache_loc = maintainers_cache.clone();
        cache_loc.push(format!("{eval}.cache"));
        let lines = read_to_string(cache_loc)?;
        let lines: Vec<&str> = lines.split('\n').collect();
        for line in lines {
            if line.is_empty() {
                continue;
            }
            let parts: Vec<&str> = line.splitn(6, ' ').collect();
            // Group by maintainer
            let maintainer = parts[0].to_string();
            let build = Build {
                attr: parts[1].to_string(),
                build_id: parts[2].parse::<u64>()?,
                name: parts[3].to_string(),
                arch: parts[4].to_string(),
                status: parts[5].to_string(),
                maintainer: maintainer.to_string(),
            };
            if let Some(entry) = maintainers.get_mut(&maintainer) {
                entry.push(build);
            } else {
                maintainers.insert(maintainer, vec![build]);
            }
        }
    }

    // Sort builds
    for builds in maintainers.values_mut() {
        builds.sort_by(|a, b| a.attr.partial_cmp(&b.attr).unwrap());
    }
    // Filter out successful builds
    for builds in maintainers.values_mut() {
        builds.retain(|x| x.status != "Succeeded");
    }
    // Filter out maintainers without failures
    maintainers.retain(|_, x| !x.is_empty());

    // For all.html
    let mut all_failed_builds = HashMap::new();

    // Render per-maintainer pages
    for (maintainer_name, builds) in &maintainers {
        // Pretty name for titles
        let pretty_name = if maintainer_name == "_" {
            "nobody".to_string()
        } else {
            maintainer_name.clone()
        };

        let mut out = out_dir.clone();
        out.push(format!("{maintainer_name}.html"));
        let mut out = File::create(out)?;
        // Write top part
        out.write_fmt(format_args!(r#"<!DOCTYPE html>
        <html lang="en">
          <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <meta http-equiv="X-UA-Compatible" content="ie=edge">
            <title>Hydra failures ({pretty_name})</title>
            <link rel="stylesheet" href="../../style.css">
            <link rel="icon" type="image/x-icon" href="../../favicon.ico">
            <meta property="og:title" content="Per-maintainer Hydra failures" />
            <meta property="og:description" content="Track Hydra failures that have {pretty_name} as their maintainer" />
            <meta property="og:type" content="website" />
            <meta property="og:url" content="https://zh.fail/failed/by-maintainer/{maintainer_name}.html" />
            <meta property="og:image" content="../../icon.png" />
          </head>
          <body id="maintainer-body">
            <h1><a href="../../index.html" title="Go Home"><img src="../../nix-snowflake.svg"></a>Hydra failures for packages maintained by {pretty_name}</h1>
            <p>Jump to: <a href='#direct'>Direct Failures</a>&nbsp;&bull;&nbsp;<a href='#indirect'>Indirect Failures</a></p>
            <h2 id="direct">Direct failures</h2>
            <p>These are packages fail to build themselves.</p>
            <table>
              <thead><tr><th>Attribute</th><th>Job name</th><th>Platform</th><th>Result</th></th></thead>
              <tbody>"#))?;
        // Table for direct failures
        let mut found = false;
        for build in builds {
            // Propagate list for all.html
            all_failed_builds.insert(build.attr.clone(), build);

            if build.status == "Dependency failed" {
                continue;
            }
            found = true;
            out.write_fmt(format_args!("<tr><td><a href=\"https://hydra.nixos.org/build/{}\">{}</a></td><td>{}</td><td>{}</td><td>{}</td></tr>", build.build_id, build.attr, build.name, build.arch, build.status))?;
        }
        if !found {
            out.write_fmt(format_args!(
                r#"<tr><td colspan="4" class="none">None 🎉</td></tr>"#
            ))?;
        }
        // Middle between the two tables
        out.write_fmt(format_args!(r#"</tbody>
        </table>
        <p>Jump to: <a href='#direct'>Direct Failures</a>&nbsp;&bull;&nbsp;<a href='#indirect'>Indirect Failures</a></p>
        <h2 id="indirect">Indirect failures</h2>
        <p>These are packages where a dependency failed to build.<br></p>
        <table>
          <thead><tr><th>Attribute</th><th>Job name</th><th>Platform</th><th>Result</th></th></thead>
          <tbody>"#))?;
        // Table for indirect failures
        let mut found = false;
        for build in builds {
            if build.status != "Dependency failed" {
                continue;
            }
            found = true;
            out.write_fmt(format_args!("<tr><td><a href=\"https://hydra.nixos.org/build/{}\">{}</a></td><td>{}</td><td>{}</td><td>{}</td></tr>", build.build_id, build.attr, build.name, build.arch, build.status))?;
        }
        if !found {
            out.write_fmt(format_args!(
                r#"<tr><td colspan="4" class="none">None 🎉</td></tr>"#
            ))?;
        }
        // Bottom
        out.write_fmt(format_args!(
            r#"</tbody>
            </table>
          </body>
        </html>"#
        ))?;
    }

    // Render overview over all maintainers
    let mut maintainer_names: Vec<_> = maintainers.keys().collect();
    maintainer_names.sort();
    let mut failed_dir = std::env::current_dir()?;
    failed_dir.push("public");
    failed_dir.push("failed");
    let mut out = failed_dir.clone();
    out.push("overview.html");
    let mut out = File::create(out)?;
    out.write_fmt(format_args!(r#"<!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <meta http-equiv="X-UA-Compatible" content="ie=edge">
        <title>Hydra failures by maintainer</title>
        <link rel="stylesheet" href="../style.css">
        <link rel="icon" type="image/x-icon" href="../favicon.ico">
        <meta property="og:title" content="Hydra failures by maintainer" />
        <meta property="og:description" content="Overview of maintainers of broken Hydra packages" />
        <meta property="og:type" content="website" />
        <meta property="og:url" content="https://zh.fail/failed/overview.html" />
        <meta property="og:image" content="../icon.png" />
      </head>
      <body id="maintainer-overview">
        <h1><a href="../index.html" title="Go Home"><img src="../nix-snowflake.svg"></a>Hydra failures by maintainer</h1>
        <p>If your name is not in this list, then you don't maintain any failed packages. Congratulations!</p>
        <ul>"#))?;
    for maintainer_name in maintainer_names {
        let num_failed = &maintainers.get(maintainer_name).unwrap().len();
        out.write_fmt(format_args!("<li><a href='by-maintainer/{maintainer_name}.html'>{maintainer_name}</a> ({num_failed})</li>"))?;
    }
    out.write_fmt(format_args!("</ul></body></html>"))?;

    // Render the overview over all failed builds
    let mut all_attrs: Vec<_> = all_failed_builds.keys().collect();
    all_attrs.sort();
    let mut out = failed_dir.clone();
    out.push("all.html");
    let mut out = File::create(out)?;
    out.write_fmt(format_args!(r#"<!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <meta http-equiv="X-UA-Compatible" content="ie=edge">
        <title>All Hydra failures</title>
        <link rel="stylesheet" href="../style.css">
        <link rel="icon" type="image/x-icon" href="../favicon.ico">
        <meta property="og:title" content="All Hydra failures" />
        <meta property="og:description" content="Overview of all Hydra failures of the most recent evaluations" />
        <meta property="og:type" content="website" />
        <meta property="og:url" content="https://zh.fail/failed/all.html" />
        <meta property="og:image" content="../icon.png" />
      </head>
      <body>
        <h1><a href="../index.html" title="Go Home"><img src="../nix-snowflake.svg"></a>All Hydra failures</h1>
        <p>Jump to: <a href='#direct'>Direct Failures</a>&nbsp;&bull;&nbsp;<a href='#indirect'>Indirect Failures</a></p>
        <h2 id="direct">Direct failures</h2>
        <p>These are packages fail to build themselves.</p>
        <table>
            <thead><tr><th>Attribute</th><th>Job name</th><th>Platform</th><th>Maintainer</th><th>Result</th></th></thead>
            <tbody>"#))?;
    // Direct failures
    let mut found = false;
    for attr in &all_attrs {
        let build = &all_failed_builds.get(*attr).unwrap();
        if build.status == "Dependency failed" {
            continue;
        }
        found = true;
        out.write_fmt(format_args!("<tr><td><a href=\"https://hydra.nixos.org/build/{}\">{}</a></td><td>{}</td><td>{}</td><td>{}</td><td>{}</td></tr>", build.build_id, build.attr, build.name, build.arch, build.maintainer, build.status))?;
    }
    if !found {
        out.write_fmt(format_args!(
            r#"<tr><td colspan="5" class="none">None 🎉</td></tr>"#
        ))?;
    }
    // Write middle
    out.write_fmt(format_args!(r#"</tbody>
    </table>
    <p>Jump to: <a href='#direct'>Direct Failures</a>&nbsp;&bull;&nbsp;<a href='#indirect'>Indirect Failures</a></p>
    <h2 id="indirect">Indirect failures</h2>
    <p>These are packages where a dependency failed to build.<br></p>
    <table>
      <thead><tr><th>Attribute</th><th>Job name</th><th>Platform</th><th>Result</th></th></thead>
      <tbody>"#))?;
    // Indirect failures
    let mut found = false;
    for attr in &all_attrs {
        let build = &all_failed_builds.get(*attr).unwrap();
        if build.status != "Dependency failed" {
            continue;
        }
        found = true;
        out.write_fmt(format_args!("<tr><td><a href=\"https://hydra.nixos.org/build/{}\">{}</a></td><td>{}</td><td>{}</td><td>{}</td><td>{}</td></tr>", build.build_id, build.attr, build.name, build.arch, build.maintainer, build.status))?;
    }
    if !found {
        out.write_fmt(format_args!(
            r#"<tr><td colspan="5" class="none">None 🎉</td></tr>"#
        ))?;
    }
    // Write bottom
    out.write_fmt(format_args!("</tbody></table></body></html>"))?;

    Ok(())
}
