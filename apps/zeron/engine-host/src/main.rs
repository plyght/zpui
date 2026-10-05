//! zeron-engine — the engine half of zeron's `apps/zeron/src/main.rs`, without the
//! gpui UI, bundled with the Zig desktop client so it needs no Rust Zeron install.
//!
//! The subcommands that matter run the upstream code unchanged:
//!   `zeron-engine headless`   `zeron_engine::Engine::new(config).run()` (the Zig client
//!                             spawns this when nothing answers on ZERON_IPC_PORT)
//!   `zeron-engine mcp`        `zeron_mcp::run` — the engine registers `<current_exe> mcp`
//!                             as the agents' MCP server, so the host must serve it
//!   `zeron-engine --noop-browser`  the ACP harnesses' BROWSER stand-in
//!   `zeron-engine login|logout|status`  upstream `auth_cli.rs` (copied in at build time)
//! `paths.rs` and `auth_cli.rs` are copied verbatim from the pinned checkout by
//! apps/zeron/scripts/build-engine.sh; the config resolution, logging, log file and
//! allocator setup below mirror upstream main.rs at the same pin.

mod auth_cli;
mod paths;

use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(
    name = "zeron-engine",
    version,
    about = "Zeron engine (headless) for the Zeron desktop client"
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Run the engine without a UI (local-only unless a saved session enables sync).
    Headless,
    /// Sign in and enable sync on the next engine start.
    Login,
    /// Remove the saved session and return to local-only on the next start.
    Logout,
    /// Show workspace mode, optional auth, and engine status.
    Status,
    /// Serve the Zeron MCP server on stdin/stdout, proxying to the running engine's IPC.
    Mcp,
}

/// Upstream `DEFAULT_EDGE_URL`.
const DEFAULT_EDGE_URL: &str = "https://edge.zeron.sh";
/// Upstream `DEFAULT_WORKOS_CLIENT_ID`.
const DEFAULT_WORKOS_CLIENT_ID: &str = "client_01KWD0EAKZKD50YCQJNYSRE4BY";

fn edge_url_from_env() -> String {
    std::env::var("ZERON_EDGE_URL")
        .ok()
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| DEFAULT_EDGE_URL.into())
}

fn workos_client_id_from_env(edge_token: &Option<String>) -> Option<String> {
    match std::env::var("ZERON_WORKOS_CLIENT_ID") {
        Ok(v) if v.trim().is_empty() => None,
        Ok(v) => Some(v),
        Err(_) if edge_token.is_some() => None,
        Err(_) => Some(DEFAULT_WORKOS_CLIENT_ID.into()),
    }
}

#[cfg(target_os = "macos")]
#[global_allocator]
static ALLOC: mimalloc::MiMalloc = mimalloc::MiMalloc;

#[cfg(all(target_os = "linux", target_env = "gnu"))]
fn spawn_malloc_trimmer() {
    const PERIOD: std::time::Duration = std::time::Duration::from_secs(60);
    let spawned = std::thread::Builder::new()
        .name("malloc-trim".into())
        .spawn(|| {
            loop {
                std::thread::sleep(PERIOD);
                // SAFETY: malloc_trim takes no pointers and locks each arena itself.
                let released = unsafe { libc::malloc_trim(0) } != 0;
                tracing::debug!(released, "malloc_trim");
            }
        });
    if let Err(error) = spawned {
        tracing::warn!(%error, "malloc trimmer not started");
    }
}

fn main() -> anyhow::Result<()> {
    if std::env::args_os().nth(1).as_deref() == Some(std::ffi::OsStr::new("--noop-browser")) {
        return Ok(());
    }
    let cli = Cli::parse();
    let long_running = matches!(cli.command, Command::Headless);
    let default_filter = if long_running {
        "info,loro_internal=warn,loro=warn"
    } else {
        "warn"
    };
    let filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| default_filter.into());
    let log_file = if long_running {
        open_log_file("headless")
    } else {
        None
    };
    {
        use tracing_subscriber::layer::SubscriberExt;
        use tracing_subscriber::util::SubscriberInitExt;
        if matches!(cli.command, Command::Mcp) {
            // stdout is the protocol.
            tracing_subscriber::registry()
                .with(filter)
                .with(
                    tracing_subscriber::fmt::layer()
                        .with_ansi(false)
                        .with_writer(std::io::stderr),
                )
                .init();
        } else {
            let registry = tracing_subscriber::registry()
                .with(filter)
                .with(tracing_subscriber::fmt::layer());
            match log_file {
                Some(file) => registry
                    .with(
                        tracing_subscriber::fmt::layer()
                            .with_ansi(false)
                            .with_writer(std::sync::Arc::new(file)),
                    )
                    .init(),
                None => registry.init(),
            }
        }
    }
    if long_running {
        let default_hook = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            tracing::error!(panic = %info,
                backtrace = %std::backtrace::Backtrace::force_capture(),
                "application panic");
            default_hook(info);
        }));
        #[cfg(all(target_os = "linux", target_env = "gnu"))]
        spawn_malloc_trimmer();
    }

    let runtime = tokio::runtime::Runtime::new()?;
    match cli.command {
        Command::Headless => runtime.block_on(async {
            let engine = zeron_engine::Engine::new(engine_config_from_env());
            engine.run().await
        }),
        Command::Login => runtime.block_on(auth_cli::login(engine_config_from_env())),
        Command::Logout => runtime.block_on(auth_cli::logout(engine_config_from_env())),
        Command::Status => runtime.block_on(auth_cli::status(engine_config_from_env())),
        Command::Mcp => runtime.block_on(zeron_mcp::run(zeron_mcp::McpConfig::from_env())),
    }
}

/// Upstream `engine_config_from_env`.
fn engine_config_from_env() -> zeron_engine::EngineConfig {
    let edge_token = std::env::var("ZERON_EDGE_TOKEN").ok();
    zeron_engine::EngineConfig {
        data_dir: paths::data_dir(),
        edge_url: edge_url_from_env(),
        ipc_port: std::env::var("ZERON_IPC_PORT")
            .ok()
            .and_then(|p| p.parse().ok())
            .unwrap_or(27654),
        default_harness: harness_from_env(),
        org_id: std::env::var("ZERON_ORG_ID").ok(),
        workos_client_id: workos_client_id_from_env(&edge_token),
        edge_token,
    }
}

/// Upstream `harness_from_env`.
fn harness_from_env() -> zeron_engine::HarnessId {
    match std::env::var("ZERON_HARNESS").as_deref().map(str::trim) {
        Ok("mock") => zeron_engine::HarnessId::Mock,
        Ok("codex") => zeron_engine::HarnessId::Codex,
        Ok("cursor") => zeron_engine::HarnessId::Cursor,
        Ok("devin") => zeron_engine::HarnessId::Devin,
        Ok("grok") => zeron_engine::HarnessId::Grok,
        Ok("hermes") => zeron_engine::HarnessId::Hermes,
        Ok("pi") => zeron_engine::HarnessId::Pi,
        Ok("antigravity") => zeron_engine::HarnessId::Antigravity,
        _ => zeron_engine::HarnessId::ClaudeCode,
    }
}

/// Upstream `open_log_file`: `{data_dir}/logs/zeron-{mode}.log`, previous launch kept as
/// `.old`; a live writer's file is never rotated (pid-suffixed overflow instead).
fn open_log_file(mode: &str) -> Option<std::fs::File> {
    let dir = paths::data_dir().join("logs");
    std::fs::create_dir_all(&dir).ok()?;
    let path = dir.join(format!("zeron-{mode}.log"));
    #[cfg(unix)]
    {
        use std::os::unix::io::AsRawFd;
        let preexisting = path.exists();
        let existing = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(&path)
            .ok()?;
        let rc = unsafe { libc::flock(existing.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
        if rc != 0 {
            return std::fs::File::create(
                dir.join(format!("zeron-{mode}.{}.log", std::process::id())),
            )
            .ok();
        }
        drop(existing);
        if preexisting {
            let _ = std::fs::rename(&path, dir.join(format!("zeron-{mode}.log.old")));
        }
        let file = std::fs::File::create(&path).ok()?;
        unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
        sweep_stale_pid_logs(&dir, mode);
        Some(file)
    }
    #[cfg(not(unix))]
    {
        let _ = std::fs::rename(&path, dir.join(format!("zeron-{mode}.log.old")));
        std::fs::File::create(&path).ok()
    }
}

/// Upstream `sweep_stale_pid_logs`.
#[cfg(unix)]
fn sweep_stale_pid_logs(dir: &std::path::Path, mode: &str) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    let prefix = format!("zeron-{mode}.");
    let week = std::time::Duration::from_secs(7 * 24 * 60 * 60);
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        let Some(middle) = name
            .strip_prefix(&prefix)
            .and_then(|rest| rest.strip_suffix(".log"))
        else {
            continue;
        };
        if !middle.chars().all(|c| c.is_ascii_digit()) {
            continue;
        }
        let stale = entry
            .metadata()
            .and_then(|m| m.modified())
            .ok()
            .and_then(|t| t.elapsed().ok())
            .is_some_and(|age| age > week);
        if stale {
            let _ = std::fs::remove_file(entry.path());
        }
    }
}
