//! Serves the dashboard over HTTP for packages/mcp/test/rust-web.test.ts,
//! which drives `@cronwatch/mcp` against it. Seeded like the MCP tests' own
//! end to end case: a `nightly` job with one good run and one failed one,
//! and a fixed clock. Nested in an axum `Router` at `/cronwatch`, so the
//! routes find their base path from the mount.
//!
//! ```text
//! cargo run -p cronwatch-webserver -- PORT    (in packages/rust)
//! ```
//!
//! Alerts are printed as `alert <job> <type>` lines.
#![forbid(unsafe_code)]

use std::sync::Arc;
use std::sync::atomic::{AtomicI64, Ordering};

use cronwatch::web::RoutesOptions;
use cronwatch::{Alert, Client, JobOptions, channel_fn};

/// 2026-01-05 02:00:00 UTC.
const START: i64 = 1_767_578_400_000;

#[tokio::main]
async fn main() {
    let port = match std::env::args().nth(1) {
        Some(port) if std::env::args().len() == 2 => port,
        _ => {
            eprintln!("usage: cronwatch-webserver PORT");
            std::process::exit(2);
        }
    };
    let now = Arc::new(AtomicI64::new(START));
    let clock = now.clone();
    let channel = channel_fn("test", |alert: Alert| {
        println!("alert {} {}", alert.job, alert.alert_type);
        async { Ok(()) }
    });
    let cw = Client::builder()
        .alert(channel)
        .no_cron_secret()
        .clock(move || clock.load(Ordering::SeqCst))
        .build()
        .unwrap_or_else(|err| fail(err));
    let nightly = cw
        .job("nightly", JobOptions::new().schedule("0 2 * * *").timezone("UTC").grace("15m"))
        .unwrap_or_else(|err| fail(err));
    nightly
        .run(|job| async move {
            job.log("step 1");
            Ok::<_, std::io::Error>(())
        })
        .await
        .unwrap_or_else(|err| fail(err));
    now.fetch_add(60_000, Ordering::SeqCst);
    let _ = nightly
        .run(|job| async move {
            job.log("step 2");
            Err::<(), _>(std::io::Error::other("db down"))
        })
        .await;

    let routes = cw.routes(RoutesOptions::new().token("tok")).unwrap_or_else(|err| fail(err));
    let app = axum::Router::new().nest_service("/cronwatch", routes);
    let listener = tokio::net::TcpListener::bind(format!("127.0.0.1:{port}")).await.unwrap_or_else(|err| fail(err));
    println!("serving on {port}");
    if let Err(err) = axum::serve(listener, app).await {
        fail(err);
    }
}

fn fail(err: impl std::fmt::Display) -> ! {
    eprintln!("{err}");
    std::process::exit(1);
}
