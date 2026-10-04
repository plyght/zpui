//! Dumps zeron's compact-transcript row split, the streaming veil and the
//! message-badge split for a deterministic corpus as JSON, for
//! apps/zeron/src/ui/transcript/testdata/transcript_parity.json (compared by
//! apps/zeron/src/ui/transcript/parity_test.zig).
//!
//! Build against the zeron workspace's prebuilt rlibs (no Cargo project needed):
//!   D=$ZERON/target/debug/deps
//!   rustc --edition 2024 transcript_parity.rs -o /tmp/transcript_parity -L $D \
//!     --extern zeron_ui=$(ls $D/libzeron_ui-*.rlib) --extern zeron_doc=$(ls $D/libzeron_doc-*.rlib) \
//!     --extern zeron_markdown=$(ls $D/libzeron_markdown-*.rlib) --extern gpui=$(ls $D/libgpui-*.rlib) \
//!     --extern serde_json=<the libserde_json-*.rlib zeron_doc links; rustc names the
//!       other one in a "multiple different versions of crate" error>
//!   /tmp/transcript_parity > apps/zeron/src/ui/transcript/testdata/transcript_parity.json
//!
//! Entries are emitted as the doc JSON serde produced, so the Zig side decodes
//! exactly what was split here.

use serde_json::{Value, json};
use std::sync::Arc;
use std::time::{Duration, Instant};
use zeron_doc::SessionMessageEntry;
use zeron_ui::markdown::veil::{ElemVeil, RowVeil};
use zeron_ui::transcript::{RowKind, ToolItemKind, rows_for_entry, tool_group_summary};

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
    fn chance(&mut self, pct: u64) -> bool {
        self.below(100) < pct
    }
}

const WORDS: &[&str] = &["alpha", "beta", "gamma", "**bold**", "`code`", "[x](https://x.dev)", "delta", "\n\n", "- item\n", "# Head\n\n"];

fn text(rng: &mut Rng) -> String {
    if rng.chance(10) {
        return "  \n".into();
    }
    let n = 1 + rng.below(8);
    (0..n).map(|_| WORDS[rng.below(WORDS.len() as u64) as usize]).collect::<Vec<_>>().join(" ")
}

fn part(rng: &mut Rng, ix: usize) -> Value {
    let id = format!("p{ix}");
    match rng.below(10) {
        0..=3 => json!({"kind": "text", "id": id, "text": text(rng)}),
        4..=6 => {
            let call = match rng.below(4) {
                0 => json!({"kind": "exec", "command": "ls -la"}),
                1 => json!({"kind": "readFile", "path": "src/main.rs"}),
                2 => json!({"kind": "search", "pattern": "fn main"}),
                _ => json!({"kind": "unknown", "name": "spawn_agent", "input": {"prompt": "go"}}),
            };
            let mut t = json!({"kind": "tool", "id": id, "call": call, "isError": rng.chance(15), "resolved": rng.chance(80)});
            if rng.chance(50) {
                t["output"] = json!("line one\nline two\n");
            }
            t
        }
        7 | 8 => json!({"kind": "reasoning", "id": id, "text": text(rng)}),
        _ => {
            if rng.chance(50) {
                json!({"kind": "error", "id": id, "message": "boom"})
            } else {
                json!({"kind": "input", "id": id, "requestId": id, "questions": [{"id": "q", "header": "Pick one", "question": "?", "options": []}], "resolved": rng.chance(50)})
            }
        }
    }
}

fn kind_tag(kind: &RowKind) -> &'static str {
    match kind {
        RowKind::User { .. } => "user",
        RowKind::Markdown { .. } | RowKind::LiveMarkdown { .. } => "markdown",
        RowKind::ToolGroup { .. } => "tool_group",
        RowKind::InputChip { .. } => "input_chip",
        RowKind::ErrorChip { .. } => "error_chip",
        RowKind::ForkMarker { .. } => "fork_marker",
        RowKind::GeneratedImage { .. } => "generated_image",
    }
}

fn item_kind(k: ToolItemKind) -> &'static str {
    match k {
        ToolItemKind::Call => "call",
        ToolItemKind::Thought => "thought",
        ToolItemKind::Note => "note",
    }
}

fn rows_case(entry: &SessionMessageEntry) -> Value {
    let rows = rows_for_entry(entry, false, true, &mut |_, text| {
        Arc::new(zeron_markdown::parser::parse_full(text))
    });
    let rows: Vec<Value> = rows
        .iter()
        .map(|r| {
            let mut v = json!({
                "id": r.id.to_string(),
                "kind": kind_tag(&r.kind),
                "fold": r.compact_fold.as_ref().map(|s| s.to_string()),
                "turn_start": r.turn_start,
                "timestamp": r.timestamp.is_some(),
            });
            if let RowKind::ToolGroup { summary, tools, auto_open, worked_secs, compact_shell } = &r.kind {
                v["summary"] = json!(summary.to_string());
                v["auto_open"] = json!(auto_open);
                v["worked_secs"] = json!(worked_secs);
                v["shell"] = json!(compact_shell);
                v["tools"] = json!(tools.iter().map(|t| item_kind(t.kind)).collect::<Vec<_>>());
                assert_eq!(summary.to_string(), tool_group_summary(tools));
            }
            v
        })
        .collect();
    json!({"entry": serde_json::to_value(entry).unwrap(), "rows": rows})
}

fn veil_case(rng: &mut Rng, seeded: bool) -> Value {
    let t0 = Instant::now();
    let mut row = if seeded { RowVeil::seeded() } else { RowVeil::default() };
    let mut texts = vec![String::new(); 2];
    let mut ms = 0u64;
    let mut steps = Vec::new();
    for step in 0..12 {
        ms += rng.below(160);
        let elem = rng.below(2) as usize;
        let t = &mut texts[elem];
        match rng.below(6) {
            0 => {}
            1 => {
                // Rewrite the tail (a marker collapsing).
                let keep = t.len() / 2;
                let mut k = keep;
                while !t.is_char_boundary(k) {
                    k -= 1;
                }
                t.truncate(k);
                t.push_str("é rewritten");
            }
            _ => t.push_str(["one ", "two ", "ünï ", "x", "longer chunk "][rng.below(5) as usize]),
        }
        let spans = row.advance(elem, t, t0 + Duration::from_millis(ms));
        if step == 0 && seeded {
            row.finish_seeding();
        }
        steps.push(json!({
            "elem": elem,
            "ms": ms,
            "text": t.clone(),
            "spans": spans.iter().map(|(r, a)| json!([r.start, r.end, a])).collect::<Vec<_>>(),
            "fading": row.is_fading(),
        }));
    }
    let _ = ElemVeil::default();
    json!({"seeded": seeded, "steps": steps})
}

fn badge_case(text: &str) -> Value {
    let (rest, badges) = zeron_ui::badges::split(text);
    json!({
        "text": text,
        "rest": rest,
        "badges": badges.iter().map(|b| json!({
            "label": b.label.to_string(),
            "details": b.details.iter().map(|d| json!([d.location.to_string(), d.tag.as_ref().map(|t| t.to_string()), d.body.to_string()])).collect::<Vec<_>>(),
        })).collect::<Vec<_>>(),
    })
}

fn main() {
    let mut rng = Rng(0x5eed_cafe);
    let mut rows = Vec::new();
    for i in 0..60 {
        let n = 1 + rng.below(7) as usize;
        let parts: Vec<Value> = (0..n).map(|ix| part(&mut rng, ix)).collect();
        let mut e = json!({
            "id": format!("a{i}"),
            "role": "assistant",
            "parts": parts,
            "createdAt": 1_782_920_700_000i64 + i as i64,
            "deviceId": "d",
            "status": if rng.chance(25) { "streaming" } else { "complete" },
        });
        match rng.below(4) {
            0 => {}
            1 => e["durationMs"] = json!(0),
            2 => e["durationMs"] = json!(rng.below(400_000)),
            _ => e["durationMs"] = json!(400),
        }
        let entry: SessionMessageEntry = serde_json::from_value(e).unwrap();
        rows.push(rows_case(&entry));
    }
    let mut veils = Vec::new();
    for i in 0..24 {
        veils.push(veil_case(&mut rng, i % 3 == 0));
    }
    let header = "Comments on the diff (each cites the file and line it belongs to; L = line number in the original file, R = in the changed file):";
    let file_header = "Review comments (each cites the workspace file and line it belongs to):";
    let badges: Vec<Value> = [
        "just a prompt".to_string(),
        format!("look\n\n{header}\n- src/main.rs:42 (R): early-return here\n- src/lib.rs:7 (L): why?"),
        format!("x\n\n{header}\n- a.rs:3 (R): first\n  second"),
        format!("x\n\n{header}\n- odd:name.rs:5 (R): hm (L): inner"),
        format!("x\n\n{file_header}\n- notes.md:9: file note\n- b.md:1: other: colon"),
        format!("quote {header} mid-body\nnot a block"),
        format!("x\n\n{header}\nnot a bullet"),
        format!("x\n\n{header}\n"),
        format!("first\n\n{header}\n- a.rs:1 (R): one\n\n{file_header}\n- b.md:2: two"),
    ]
    .iter()
    .map(|t| badge_case(t))
    .collect();
    let out = json!({"rows": rows, "veils": veils, "badges": badges});
    println!("{}", serde_json::to_string_pretty(&out).unwrap());
}
