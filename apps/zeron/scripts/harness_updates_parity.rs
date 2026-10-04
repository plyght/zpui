//! Dumps the Home agent-update island's pure logic (zeron
//! `crates/ui/src/shell/harness_updates.rs`) for a deterministic corpus as
//! JSON, for apps/zeron/src/ui/shell/testdata/harness_updates_parity.json
//! (compared by apps/zeron/src/ui/shell/harness_updates_test.zig).
//!
//! The island's helpers are private to the gpui crate, so they are lifted
//! VERBATIM out of the Rust source into a generated include (only `pub(super)`
//! is relaxed and gpui's `Task` is stubbed), and the inline parts of
//! `render_harness_update_card` (title, activity glyph, geometry) are
//! transcribed below with their source lines cited. Build against the zeron
//! workspace's prebuilt rlibs (no Cargo project needed):
//!   Z=$ZERON  D=$Z/target/debug/deps  S=/tmp/hu_parity
//!   mkdir -p $S && sed -n '/^pub(super) fn versionless_notification_key/,/^fn mark_stack/p' \
//!     $Z/crates/ui/src/shell/harness_updates.rs | sed '$d' | sed 's/pub(super) //' > $S/lifted.rs
//!   HU_LIFTED=$S/lifted.rs rustc --edition 2024 harness_updates_parity.rs -o $S/run -L $D \
//!     --extern zeron_proto=$(ls $D/libzeron_proto-*.rlib) \
//!     --extern zeron_rpc=$(ls $D/libzeron_rpc-*.rlib) \
//!     --extern serde_json=<the libserde_json-*.rlib zeron_proto links; rustc names the
//!       other one in a "multiple different versions of crate" error>
//!   $S/run > apps/zeron/src/ui/shell/testdata/harness_updates_parity.json
//!
//! Every status carries its engine JSON, so the Zig side decodes exactly what
//! serde decoded here.

#![allow(dead_code)]

use serde_json::{Value, json};
use zeron_proto::{HarnessId, HarnessUpdatePhase as Phase, HarnessUpdateStatus};
use zeron_rpc::methods;

/// gpui's `Task` (only `is_none` / `Task::ready` are used by the lifted code).
pub struct Task<T>(T);
impl<T> Task<T> {
    pub fn ready(v: T) -> Self {
        Task(v)
    }
}

include!(env!("HU_LIFTED"));

// ---- transcribed from `render_harness_update_card` -------------------------

/// harness_updates.rs:385-424 (`title`).
fn title(statuses: &[UpdateRow]) -> Option<String> {
    let row = &statuses[0];
    let status = &row.status;
    let multiple = statuses.len() > 1;
    let name = agent_name(status.harness);
    let all_updated = statuses
        .iter()
        .all(|row| row.status.phase == Phase::Updated);
    let mut title = if multiple {
        if all_updated {
            format!("{} agents updated", statuses.len())
        } else {
            format!("{} agent updates", statuses.len())
        }
    } else {
        match status.phase {
            Phase::Available => status
                .latest_version
                .as_ref()
                .map(|v| format!("{name} {v} available"))
                .unwrap_or_else(|| format!("{name} update available")),
            Phase::WaitingForIdle => format!("{name} · waiting for idle"),
            Phase::Preparing => format!("Preparing {name}…"),
            Phase::Downloading => format!("Downloading {name}…"),
            Phase::Installing => format!("Updating {name}…"),
            Phase::Verifying => format!("Verifying {name}…"),
            Phase::Updated => format!("{name} updated"),
            Phase::Failed => format!("{name} update check failed"),
            _ => return None,
        }
    };
    let device_count = statuses
        .iter()
        .map(|row| &row.device_id)
        .collect::<std::collections::BTreeSet<_>>()
        .len();
    if device_count == 1 {
        title = format!("{title} · {}", row.device_name);
    } else {
        title = format!("{title} · {device_count} devices");
    }
    if statuses.iter().any(|row| !row.connected) {
        title = format!("{title} · disconnected");
    }
    Some(title)
}

/// harness_updates.rs:425-455 (which glyph trails the title).
fn activity(statuses: &[UpdateRow]) -> Option<&'static str> {
    let multiple = statuses.len() > 1;
    let all_updated = statuses
        .iter()
        .all(|row| row.status.phase == Phase::Updated);
    if statuses
        .iter()
        .any(|row| row.connected && active(&row.status))
    {
        Some("spinner")
    } else if all_updated {
        Some("check")
    } else if !multiple && statuses[0].status.phase == Phase::Failed {
        Some("danger")
    } else {
        None
    }
}

const TITLEBAR_HEIGHT: f32 = 38.0;

/// harness_updates.rs:457-493 with `text_width` supplied by the caller.
fn geometry(
    statuses: &[UpdateRow],
    title_width: f32,
    action_width: f32,
    main_width: f32,
    viewport_height: f32,
) -> Value {
    let status = &statuses[0].status;
    let multiple = statuses.len() > 1;
    let has_activity = activity(statuses).is_some();
    let action_label = (!multiple)
        .then(|| action(status))
        .flatten()
        .map(|(label, _)| label);
    let trailing = if multiple {
        8.0
    } else {
        right_inset(action_label.is_some())
    };
    let marks_width = MARK_SIZE + MARK_STEP * statuses.len().min(MAX_MARKS).saturating_sub(1) as f32;
    let controls_width = if multiple {
        24.0 + 8.0
    } else {
        action_label
            .map(|_| action_width + 20.0 + 8.0)
            .unwrap_or(0.0)
    };
    let max_width = (main_width - 32.0).max(0.0);
    let compact_width = (12.0
        + marks_width
        + 8.0
        + title_width
        + if has_activity { 22.0 } else { 0.0 }
        + controls_width
        + trailing
        + 2.0)
        .min(max_width);
    let list_width = LIST_WIDTH.min(max_width);
    let list_height = (CHIP_HEIGHT + ROW_HEIGHT * (statuses.len() as f32).min(MAX_VISIBLE_ROWS))
        .min((viewport_height - TITLEBAR_HEIGHT - 64.0).max(CHIP_HEIGHT));
    json!({
        "titleWidth": title_width,
        "actionWidth": action_width,
        "mainWidth": main_width,
        "viewportHeight": viewport_height,
        "trailing": trailing,
        "marksWidth": marks_width,
        "compactWidth": compact_width,
        "listWidth": list_width,
        "listHeight": list_height,
    })
}

// ---- corpus ---------------------------------------------------------------

struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545F4914F6CDD1D)
    }
    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }
    fn pick<'a, T>(&mut self, xs: &'a [T]) -> &'a T {
        &xs[self.below(xs.len() as u64) as usize]
    }
    fn chance(&mut self, pct: u64) -> bool {
        self.below(100) < pct
    }
}

const HARNESSES: [&str; 9] = [
    "claude-code", "codex", "cursor", "devin", "grok", "hermes", "pi", "opencode", "antigravity",
];
const PHASES: [&str; 12] = [
    "dormant", "checking", "current", "available", "waiting-for-idle", "preparing",
    "downloading", "installing", "verifying", "updated", "manual-action-required", "failed",
];
const DEVICES: [(&str, &str); 4] = [
    ("dev-mbp", "MacBook Pro (2)"),
    ("dev-studio", "Mac Studio"),
    ("dev-linux", "workstation"),
    ("dev-zz", "Build box"),
];

fn status_json(rng: &mut Rng, harness: &str) -> Value {
    // Bias toward notice phases so most cases render.
    let phase = if rng.chance(60) {
        *rng.pick(&["available", "available", "downloading", "installing", "updated", "failed", "waiting-for-idle", "preparing", "verifying"])
    } else {
        *rng.pick(&PHASES)
    };
    let mut s = serde_json::Map::new();
    s.insert("harness".into(), json!(harness));
    s.insert("phase".into(), json!(phase));
    if rng.chance(70) {
        s.insert("installedVersion".into(), json!(format!("1.{}.{}", rng.below(20), rng.below(10))));
    }
    if rng.chance(70) {
        s.insert("latestVersion".into(), json!(format!("2.{}.{}", rng.below(20), rng.below(10))));
    }
    if rng.chance(40) {
        s.insert("progress".into(), if rng.chance(50) {
            json!({"completedBytes": 10, "totalBytes": 100, "message": "Fetching 12 MB…"})
        } else {
            json!({"completedBytes": 10})
        });
    }
    if rng.chance(30) {
        s.insert("error".into(), json!({"message": *rng.pick(&["npm exited with 1", "network unreachable", "EACCES: permission denied"]), "retryable": rng.chance(50)}));
    }
    s.insert("canApply".into(), json!(rng.chance(70)));
    if rng.chance(25) {
        s.insert("manualCommand".into(), json!("brew upgrade codex"));
    }
    if rng.chance(30) {
        s.insert("policy".into(), json!(*rng.pick(&["notify", "auto-when-idle", "off"])));
    }
    Value::Object(s)
}

fn main() {
    let mut rng = Rng(0xA5A5_1234_DEAD_BEEF);
    let mut cases = Vec::new();
    for _ in 0..160 {
        let mut devices = std::collections::BTreeMap::<String, DeviceUpdates>::new();
        let mut names = std::collections::BTreeMap::<String, String>::new();
        let mut input = Vec::new();
        // A third of the cases are a single notice (the single-row summary).
        let single = rng.chance(35);
        let n_devices = if single { 1 } else { 1 + rng.below(3) as usize };
        let mut used = Vec::new();
        for _ in 0..n_devices {
            let (id, name) = *rng.pick(&DEVICES);
            if used.contains(&id) {
                continue;
            }
            used.push(id);
            let online = rng.chance(85);
            let connected = online && rng.chance(85);
            let mut hs: Vec<&str> = HARNESSES.to_vec();
            let n = if single { 1 } else { rng.below(5) as usize };
            let mut statuses_json = Vec::new();
            for _ in 0..n {
                let i = rng.below(hs.len() as u64) as usize;
                let h = hs.remove(i);
                statuses_json.push(status_json(&mut rng, h));
            }
            let statuses: Vec<HarnessUpdateStatus> =
                serde_json::from_value(Value::Array(statuses_json.clone())).unwrap();
            devices.insert(
                id.into(),
                DeviceUpdates { online, connected, statuses, watch: None },
            );
            names.insert(id.into(), name.into());
            input.push(json!({"id": id, "name": name, "online": online, "connected": connected, "statuses": statuses_json}));
        }
        let rows = visible_rows(&devices, |id| names.get(id).cloned().unwrap_or_else(|| id.to_owned()));
        let row_json: Vec<Value> = rows
            .iter()
            .map(|row| {
                let a = action(&row.status);
                json!({
                    "deviceId": row.device_id,
                    "deviceName": row.device_name,
                    "connected": row.connected,
                    "harness": row.status.harness,
                    "agentName": agent_name(row.status.harness),
                    "detail": detail(&row.status),
                    "active": active(&row.status),
                    "action": a.map(|(label, _)| label),
                    "method": a.and_then(|(_, m)| m),
                    "rightInset": right_inset(a.is_some()),
                    "notificationKey": notification_key(&row.device_id, &row.status),
                })
            })
            .collect();
        let mut case = json!({ "devices": input, "rows": row_json });
        if !rows.is_empty() {
            let t = title(&rows);
            case["title"] = json!(t);
            case["activity"] = json!(activity(&rows));
            let tw = t.as_ref().map(|t| t.chars().count() as f32 * 7.25).unwrap_or(0.0);
            let aw = action(&rows[0].status).map(|(l, _)| l.chars().count() as f32 * 6.5).unwrap_or(0.0);
            let main_width = *rng.pick(&[180.0f32, 520.0, 900.0, 1320.0]);
            let vh = *rng.pick(&[200.0f32, 420.0, 880.0]);
            case["geometry"] = geometry(&rows, tw, aw, main_width, vh);
        }
        cases.push(case);
    }

    // Presence reconciliation (`reconcile_devices`).
    let mut reconcile = Vec::new();
    let ids = ["a", "b", "c", "d"];
    for _ in 0..60 {
        let mut devices = std::collections::BTreeMap::<String, DeviceUpdates>::new();
        let mut before = Vec::new();
        for id in ids {
            if rng.chance(50) {
                let online = rng.chance(70);
                let connected = rng.chance(70);
                let watching = rng.chance(60);
                devices.insert(id.into(), DeviceUpdates {
                    online,
                    connected,
                    statuses: Vec::new(),
                    watch: watching.then(|| Task::ready(())),
                });
                before.push(json!({"id": id, "online": online, "connected": connected, "watching": watching}));
            }
        }
        let mut desired = std::collections::BTreeMap::<String, bool>::new();
        let mut desired_json = Vec::new();
        for id in ids {
            if rng.chance(60) {
                let online = rng.chance(70);
                desired.insert(id.into(), online);
                desired_json.push(json!({"id": id, "online": online}));
            }
        }
        let start = reconcile_devices(&mut devices, &desired);
        let after: Vec<Value> = devices
            .iter()
            .map(|(id, d)| json!({"id": id, "online": d.online, "connected": d.connected, "watching": d.watch.is_some()}))
            .collect();
        reconcile.push(json!({"before": before, "desired": desired_json, "start": start, "after": after}));
    }

    let out = json!({
        "constants": {
            "chipHeight": CHIP_HEIGHT, "rowHeight": ROW_HEIGHT, "maxVisibleRows": MAX_VISIBLE_ROWS,
            "listFadeBand": LIST_FADE_BAND, "listWidth": LIST_WIDTH, "markSize": MARK_SIZE,
            "markStep": MARK_STEP, "maxMarks": MAX_MARKS,
            "applyMethod": methods::APPLY_HARNESS_UPDATE, "cancelMethod": methods::CANCEL_HARNESS_UPDATE,
            "checkMethod": methods::CHECK_HARNESS_UPDATES,
        },
        "cases": cases,
        "reconcile": reconcile,
    });
    println!("{}", serde_json::to_string(&out).unwrap());
}
