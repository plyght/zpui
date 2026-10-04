//! Dumps `zeron_proto::view` outputs for a deterministic corpus as JSON, for
//! apps/zeron/src/model/testdata/view_parity.json (compared by
//! apps/zeron/src/model/view_parity_test.zig).
//!
//! Build against the zeron workspace's prebuilt rlibs (no Cargo project needed):
//!   D=$ZERON/target/debug/deps
//!   rustc --edition 2024 view_parity.rs -o /tmp/view_parity -L $D \
//!     --extern zeron_proto=$(ls $D/libzeron_proto-*.rlib) \
//!     --extern chrono=$(ls $D/libchrono-*.rlib) \
//!     --extern serde_json=<the libserde_json-*.rlib zeron_proto links; rustc names the
//!       other one in a "multiple different versions of crate" error>
//!   /tmp/view_parity > apps/zeron/src/model/testdata/view_parity.json
//!
//! Every case carries its inputs as the JSON the engine would send, so the Zig
//! side decodes exactly what serde decoded here.

use chrono::{DateTime, Utc};
use serde_json::{Value, json};
use zeron_proto::view::{self, CheckoutKind, CheckoutPlan, ConnectionStatus, GatePhase, Indicator};
use zeron_proto::{AuthState, Chat, ChatIndicator, RepoRef, Session, Space, ToolCall, WorkspaceScope};

struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        // xorshift64*
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

const BASE: i64 = 1_767_225_600; // 2026-01-01T00:00:00Z

fn ts(rng: &mut Rng) -> String {
    // A handful of shared instants (to force ties) plus random ones, in
    // several encodings chrono accepts.
    let secs = if rng.chance(30) {
        BASE + *rng.pick(&[0i64, 60, 3600, 86_400])
    } else {
        BASE + rng.below(90 * 86_400) as i64 - 30 * 86_400
    };
    let nanos = if rng.chance(50) { 0 } else { rng.below(1_000_000_000) as u32 };
    let dt = DateTime::<Utc>::from_timestamp(secs, nanos).unwrap();
    match rng.below(6) {
        0 => dt.to_rfc3339_opts(chrono::SecondsFormat::AutoSi, true),
        1 => dt.to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
        2 => dt.to_rfc3339_opts(chrono::SecondsFormat::Nanos, false),
        3 => dt
            .with_timezone(&chrono::FixedOffset::east_opt(5 * 3600 + 1800).unwrap())
            .to_rfc3339_opts(chrono::SecondsFormat::Micros, false),
        4 => dt
            .with_timezone(&chrono::FixedOffset::west_opt(8 * 3600).unwrap())
            .to_rfc3339_opts(chrono::SecondsFormat::Secs, false),
        _ => dt.to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
    }
}

fn now_value(rng: &mut Rng) -> String {
    let secs = BASE + rng.below(90 * 86_400) as i64 - 30 * 86_400;
    DateTime::<Utc>::from_timestamp(secs, rng.below(1_000_000_000) as u32)
        .unwrap()
        .to_rfc3339_opts(chrono::SecondsFormat::Nanos, true)
}

fn parse_dt(s: &str) -> DateTime<Utc> {
    serde_json::from_value(Value::String(s.into())).unwrap()
}

const CWDS: &[Option<&str>] = &[
    None,
    Some(""),
    Some("   "),
    Some("~"),
    Some("~/"),
    Some("/"),
    Some("///"),
    Some("/home/u/zeron"),
    Some("/home/u/zeron/"),
    Some("/home/u/zeron//"),
    Some(" /home/u/zpui "),
    Some("/srv/app/."),
    Some("/srv/app/.."),
    Some("relative/dir"),
    Some("."),
    Some(".."),
    Some("./x"),
    Some("C:\\Users\\me\\proj"),
    Some("C:\\Users\\me\\proj\\"),
    Some("/tmp/émoji 🚀"),
    Some("~/code/zeron"),
    Some("\u{3000}/wide/space\u{2003}"),
];

const BRANCHES: &[Option<&str>] = &[None, Some(""), Some("  "), Some("main"), Some("zeron/fix-1"), Some(" feat ")];

fn chat(rng: &mut Rng, id: usize) -> Value {
    let created = ts(rng);
    let mut c = json!({
        "id": format!("chat-{:02}", rng.below(40)) + &format!("-{id}"),
        "deviceId": rng.pick(&["dev-a", "dev-b"]),
        "archived": rng.chance(15),
        "createdAt": created,
    });
    // Duplicate ids exercise the id tiebreak.
    if rng.chance(10) {
        c["id"] = json!("chat-dup");
    }
    if rng.chance(70) {
        c["lastMessageAt"] = json!(ts(rng));
    }
    if rng.chance(50) {
        c["lastSeenAt"] = json!(ts(rng));
    }
    if let Some(cwd) = rng.pick(CWDS) {
        c["cwd"] = json!(cwd);
    }
    if let Some(b) = rng.pick(BRANCHES) {
        c["branch"] = json!(b);
    }
    if rng.chance(30) {
        c["spaceId"] = json!(rng.pick(&["s1", "s2"]));
    }
    c
}

fn session(rng: &mut Rng, chat_id: &str, now: DateTime<Utc>) -> Value {
    let status = rng.pick(&["idle", "working", "awaitingInput", "errored"]);
    // Ages straddling the 45s staleness window, incl. future timestamps.
    let age_ms: i64 = *rng.pick(&[
        -5_000, 0, 1, 44_999, 45_000, 45_001, 46_000, 120_000, 44_999_999,
    ]) + if rng.chance(30) { rng.below(1000) as i64 } else { 0 };
    let updated = now - chrono::Duration::milliseconds(age_ms)
        - chrono::Duration::nanoseconds(rng.below(1_000_000) as i64);
    json!({
        "chatId": chat_id,
        "deviceId": "dev-a",
        "status": status,
        "updatedAt": updated.to_rfc3339_opts(chrono::SecondsFormat::Nanos, true),
    })
}

fn indicator_name(i: Indicator) -> &'static str {
    match i {
        Indicator::None => "none",
        Indicator::Working => "working",
        Indicator::AwaitingInput => "awaitingInput",
        Indicator::Errored => "errored",
    }
}

fn chat_indicator_name(i: ChatIndicator) -> Value {
    serde_json::to_value(i).unwrap()
}

fn gate_name(g: &GatePhase) -> Value {
    match g {
        GatePhase::Loading => json!("loading"),
        GatePhase::Failed(e) => json!({ "failed": e }),
        GatePhase::SignIn => json!("signIn"),
        GatePhase::OrgGate => json!("orgGate"),
        GatePhase::Ready => json!("ready"),
    }
}

fn tool_calls() -> Vec<Value> {
    vec![
        json!({"kind": "exec", "command": "cargo test\n  --all"}),
        json!({"kind": "exec", "command": "  ls\t-la  "}),
        json!({"kind": "readFile", "path": "src/main.rs"}),
        json!({"kind": "writeFile", "path": "a.txt", "content": "x"}),
        json!({"kind": "editFile", "path": "a.txt", "old_string": "a", "new_string": "b"}),
        json!({"kind": "editFile", "path": "b.txt"}),
        json!({"kind": "applyPatch"}),
        json!({"kind": "applyPatch", "path": "a.txt"}),
        json!({"kind": "applyPatch", "path": "patch"}),
        json!({"kind": "search", "pattern": "fn main"}),
        json!({"kind": "search", "pattern": "TODO", "path": "src/"}),
        json!({"kind": "glob", "pattern": "**/*.zig"}),
        json!({"kind": "webFetch", "url": "https://example.com", "prompt": "summarize"}),
        json!({"kind": "webSearch", "query": "zig 0.17\nrelease notes"}),
        json!({"kind": "todo", "items": []}),
        json!({"kind": "todo", "items": [{"text": "a", "done": true}, {"text": "b", "done": false}, {"text": "c", "done": true, "status": "weird"}]}),
        json!({"kind": "mcp", "server": "github", "tool": "create_issue", "input": {"a": 1}}),
        json!({"kind": "unknown", "name": "Agent"}),
        json!({"kind": "unknown", "name": "Agent: scan repo\n for bugs"}),
        json!({"kind": "unknown", "name": "Agent:nospace"}),
        json!({"kind": "unknown", "name": "CustomTool"}),
        json!({"kind": "unknown", "name": " \u{a0}spaced\u{2028}name "}),
    ]
}

fn auth_values() -> Vec<Value> {
    vec![
        json!({"state": "signedOut"}),
        json!({"state": "signedIn", "user": {"id": "u1", "email": "a@b.c"}}),
        json!({"state": "signedIn", "user": {"id": "u1", "email": "a@b.c", "name": "Ann"}, "orgId": "org-1"}),
        json!({"state": "needsOrganization", "user": {"id": "u2", "email": "x@y.z", "name": null}}),
        json!({"state": "signedIn"}),
        json!({"state": "bogus"}),
        json!({"_tag": "SignedOut"}),
        json!({"_tag": "SignedIn", "user": {"id": "u3", "email": "e@f.g", "name": "Eve"}, "orgId": "o"}),
        json!({"_tag": "SignedIn", "user": {"id": "u3", "email": "e@f.g"}, "orgId": 5}),
        json!({"_tag": "SignedIn", "user": {"id": "u3"}}),
        json!({"_tag": "NeedsOrganization", "user": {"id": "u4", "email": "h@i.j", "name": 7}}),
        json!({"_tag": "Other"}),
        json!({"_tag": 1}),
        json!({}),
        json!("signedOut"),
        json!(null),
    ]
}

fn main() {
    let mut rng = Rng(0x9E3779B97F4A7C15);
    let mut out = serde_json::Map::new();

    // Timestamp parsing: chrono's serde `DateTime<Utc>` decode.
    let mut stamps: Vec<String> = (0..60).map(|_| ts(&mut rng)).collect();
    stamps.extend(
        [
            "2026-01-01T00:00:00Z",
            "2026-01-01t00:00:00z",
            "2026-01-01 00:00:00Z",
            "2026-01-01T00:00:00.5Z",
            "2026-01-01T00:00:00.123456789123Z",
            "2026-01-01T00:00:00+00:00",
            "2026-01-01T00:00:00-00:00",
            "2026-01-01T23:59:60Z",
            "2026-02-29T00:00:00Z",
            "2024-02-29T12:00:00+14:00",
            "1970-01-01T00:00:00Z",
            "1969-12-31T23:59:59.999Z",
            "2026-01-01T00:00Z",
            "2026-01-01",
            "2026-13-01T00:00:00Z",
            "2026-01-01T24:00:00Z",
            "2026-01-01T00:00:00",
            "2026-01-01T00:00:00+0530",
            "2026-01-01T00:00:00+05",
            "not a date",
            "",
        ]
        .map(String::from),
    );
    out.insert(
        "timestamps".into(),
        Value::Array(
            stamps
                .iter()
                .map(|s| {
                    let parsed: Option<DateTime<Utc>> = serde_json::from_value(Value::String(s.clone())).ok();
                    json!({
                        "input": s,
                        "unixSeconds": parsed.map(|d| d.timestamp()),
                        "nanos": parsed.map(|d| d.timestamp_subsec_nanos()),
                    })
                })
                .collect(),
        ),
    );

    // effective_indicator + display_status
    let mut status_cases = Vec::new();
    for i in 0..400 {
        let now_s = now_value(&mut rng);
        let now = parse_dt(&now_s);
        let c = chat(&mut rng, i);
        let chat_v: Chat = serde_json::from_value(c.clone()).unwrap();
        let s = if rng.chance(85) { Some(session(&mut rng, &chat_v.id, now)) } else { None };
        let sess: Option<Session> = s.clone().map(|s| serde_json::from_value(s).unwrap());
        status_cases.push(json!({
            "now": now_s,
            "chat": c,
            "session": s,
            "indicator": indicator_name(view::effective_indicator(sess.as_ref(), now)),
            "displayStatus": chat_indicator_name(view::display_status(&chat_v, sess.as_ref(), now)),
            "unseen": chat_v.unseen(),
        }));
    }
    out.insert("status".into(), Value::Array(status_cases));

    out.insert(
        "attentionRank".into(),
        Value::Array(
            [
                ChatIndicator::Working,
                ChatIndicator::AwaitingInput,
                ChatIndicator::Errored,
                ChatIndicator::Completed,
                ChatIndicator::Idle,
            ]
            .iter()
            .map(|i| json!({"status": chat_indicator_name(*i), "rank": view::attention_rank(*i)}))
            .collect(),
        ),
    );

    // Sort orders
    let mut sorts = Vec::new();
    for _ in 0..60 {
        let n = 1 + rng.below(14) as usize;
        let chats_v: Vec<Value> = (0..n).map(|i| chat(&mut rng, i)).collect();
        let chats: Vec<Chat> = chats_v.iter().map(|c| serde_json::from_value(c.clone()).unwrap()).collect();
        let mut by_chats = chats.clone();
        view::sort_chats(&mut by_chats);
        let mut tabs: Vec<&Chat> = chats.iter().collect();
        view::sort_tabs(&mut tabs);
        let statuses = [
            ChatIndicator::Working,
            ChatIndicator::Idle,
            ChatIndicator::Completed,
        ];
        let mut active: Vec<(ChatIndicator, &Chat)> =
            chats.iter().enumerate().map(|(i, c)| (statuses[i % 3], c)).collect();
        view::sort_active(&mut active);
        let groups = view::group_chats(by_chats.iter());
        // Index-based outputs: duplicate ids make id lists ambiguous.
        let index_of = |c: &Chat| chats.iter().position(|x| std::ptr::eq(x, c)).unwrap();
        let by_chats_idx: Vec<usize> = {
            // sort_chats sorts owned clones; recover indices with a stable
            // pairing (clone order is preserved for equal elements).
            let mut idx: Vec<usize> = (0..chats.len()).collect();
            idx.sort_by(|&a, &b| {
                let (a, b) = (&chats[a], &chats[b]);
                let ka = a.last_message_at.unwrap_or(a.created_at);
                let kb = b.last_message_at.unwrap_or(b.created_at);
                kb.cmp(&ka).then_with(|| b.created_at.cmp(&a.created_at)).then_with(|| a.id.cmp(&b.id))
            });
            for (i, c) in idx.iter().zip(by_chats.iter()) {
                assert_eq!(chats[*i], *c);
            }
            idx
        };
        sorts.push(json!({
            "chats": chats_v,
            "sortChats": by_chats_idx,
            "sortTabs": tabs.iter().map(|c| index_of(c)).collect::<Vec<_>>(),
            "sortActive": active.iter().map(|(_, c)| index_of(c)).collect::<Vec<_>>(),
            "groups": groups.iter().map(|g| json!({
                "label": g.label,
                "ids": g.chats.iter().map(|c| c.id.clone()).collect::<Vec<_>>(),
            })).collect::<Vec<_>>(),
        }));
    }
    out.insert("sorts".into(), Value::Array(sorts));

    let mut space_sorts = Vec::new();
    for _ in 0..30 {
        let n = 1 + rng.below(8) as usize;
        let spaces_v: Vec<Value> = (0..n)
            .map(|i| {
                json!({
                    "id": if rng.chance(20) { "sp-dup".to_string() } else { format!("sp-{}", rng.below(20)) + &format!("-{i}") },
                    "deviceId": "dev-a",
                    "path": "/p",
                    "createdAt": ts(&mut rng),
                })
            })
            .collect();
        let spaces: Vec<Space> = spaces_v.iter().map(|s| serde_json::from_value(s.clone()).unwrap()).collect();
        let mut idx: Vec<usize> = (0..spaces.len()).collect();
        idx.sort_by(|&a, &b| {
            spaces[a].created_at.cmp(&spaces[b].created_at).then_with(|| spaces[a].id.cmp(&spaces[b].id))
        });
        let mut sorted = spaces.clone();
        view::sort_spaces(&mut sorted);
        for (i, s) in idx.iter().zip(sorted.iter()) {
            assert_eq!(spaces[*i], *s);
        }
        space_sorts.push(json!({ "spaces": spaces_v, "sorted": idx }));
    }
    out.insert("spaceSorts".into(), Value::Array(space_sorts));

    // Gate phase: every combination.
    let mut gates = Vec::new();
    let auths: Vec<Option<Value>> = vec![
        None,
        Some(json!({"state": "signedOut"})),
        Some(json!({"state": "needsOrganization", "user": {"id": "u", "email": "e"}})),
        Some(json!({"state": "signedIn", "user": {"id": "u", "email": "e"}, "orgId": "o"})),
        Some(json!({"state": "signedIn", "user": {"id": "u", "email": "e"}})),
    ];
    for conn in ["connecting", "ready", "failed"] {
        for scope in [None, Some("local"), Some("synced"), Some("development")] {
            for auth in &auths {
                let c = match conn {
                    "connecting" => ConnectionStatus::Connecting,
                    "ready" => ConnectionStatus::Ready,
                    _ => ConnectionStatus::Failed("boom: no engine".into()),
                };
                let s: Option<WorkspaceScope> = scope.map(|s| serde_json::from_value(json!(s)).unwrap());
                let a: Option<AuthState> = auth.clone().map(|a| serde_json::from_value(a).unwrap());
                gates.push(json!({
                    "connection": conn,
                    "scope": scope,
                    "auth": auth,
                    "gate": gate_name(&view::gate_phase(&c, s, a.as_ref())),
                }));
            }
        }
    }
    out.insert("gates".into(), Value::Array(gates));

    out.insert(
        "parseAuth".into(),
        Value::Array(
            auth_values()
                .into_iter()
                .map(|v| {
                    let parsed = view::parse_auth_state(&v);
                    json!({ "input": v, "output": parsed.map(|a| serde_json::to_value(a).unwrap()) })
                })
                .collect(),
        ),
    );

    out.insert(
        "projectLabel".into(),
        Value::Array(
            CWDS.iter()
                .map(|c| json!({ "cwd": c, "label": view::project_label(*c) }))
                .collect(),
        ),
    );

    let mut locations = Vec::new();
    for cwd in CWDS {
        for branch in BRANCHES {
            let mut c = json!({"id": "c", "deviceId": "d", "archived": false, "createdAt": "2026-01-01T00:00:00Z"});
            if let Some(cwd) = cwd {
                c["cwd"] = json!(cwd);
            }
            if let Some(b) = branch {
                c["branch"] = json!(b);
            }
            let chat: Chat = serde_json::from_value(c.clone()).unwrap();
            locations.push(json!({ "chat": c, "location": view::chat_location(&chat) }));
        }
    }
    out.insert("chatLocation".into(), Value::Array(locations));

    let mut ago = Vec::new();
    let deltas: Vec<i64> = vec![
        -10, 0, 1, 44, 45, 59, 60, 61, 119, 120, 3599, 3600, 3601, 86_399, 86_400, 86_401,
        6 * 86_400, 7 * 86_400, 8 * 86_400, 34 * 86_400, 35 * 86_400, 36 * 86_400, 59 * 86_400,
        60 * 86_400, 364 * 86_400, 365 * 86_400, 400 * 86_400, 3 * 365 * 86_400, 800 * 86_400,
    ];
    for d in deltas {
        for extra_ms in [0i64, 999, -1] {
            let now_s = now_value(&mut rng);
            let now = parse_dt(&now_s);
            let then = now - chrono::Duration::seconds(d) - chrono::Duration::milliseconds(extra_ms);
            let then_s = then.to_rfc3339_opts(chrono::SecondsFormat::Nanos, true);
            ago.push(json!({ "then": then_s, "now": now_s, "ago": view::format_time_ago(then, now) }));
        }
    }
    out.insert("timeAgo".into(), Value::Array(ago));

    out.insert(
        "singleLine".into(),
        Value::Array(
            [
                "",
                "   ",
                "plain",
                "  lead and trail  ",
                "multi\nline\r\ntext",
                "tabs\tand\u{0b}vt\u{0c}ff",
                "nbsp\u{a0}here",
                "ideo\u{3000}space",
                "nel\u{85}x",
                "zwsp\u{200b}stays",
                "en\u{2002}quad\u{2028}ls\u{2029}ps",
                "ogham\u{1680}mark",
                "émoji 🚀  rocket",
                "\u{feff}bom",
            ]
            .iter()
            .map(|s| json!({ "input": s, "output": view::single_line(s) }))
            .collect(),
        ),
    );

    let calls = tool_calls();
    out.insert(
        "toolChip".into(),
        Value::Array(
            calls
                .iter()
                .map(|c| {
                    let call: ToolCall = serde_json::from_value(c.clone()).unwrap();
                    let (label, detail) = view::tool_chip_content(&call);
                    json!({ "call": c, "label": label, "detail": detail })
                })
                .collect(),
        ),
    );

    let mut groups = vec![json!({"tools": [], "summary": view::tool_group_summary(&[])})];
    for _ in 0..80 {
        let n = rng.below(9) as usize;
        let tools: Vec<(Value, bool)> = (0..n).map(|_| (rng.pick(&calls).clone(), rng.chance(20))).collect();
        let typed: Vec<(ToolCall, bool)> =
            tools.iter().map(|(c, e)| (serde_json::from_value(c.clone()).unwrap(), *e)).collect();
        groups.push(json!({
            "tools": tools.iter().map(|(c, e)| json!({"call": c, "isError": e})).collect::<Vec<_>>(),
            "summary": view::tool_group_summary(&typed),
        }));
    }
    out.insert("toolGroup".into(), Value::Array(groups));

    let refs: Vec<Option<Value>> = vec![
        None,
        Some(json!({"name": "main"})),
        Some(json!({"name": "main", "current": true})),
        Some(json!({"name": "feat", "worktreePath": "/wt/feat"})),
        Some(json!({"name": "", "worktreePath": "/wt/empty"})),
    ];
    let mut checkouts = Vec::new();
    for kind in [CheckoutKind::Local, CheckoutKind::NewWorktree] {
        for r in &refs {
            let rr: Option<RepoRef> = r.clone().map(|r| serde_json::from_value(r).unwrap());
            let plan = match view::checkout_plan(kind, rr.as_ref()) {
                CheckoutPlan::CurrentCheckout { branch } => json!({"currentCheckout": {"branch": branch}}),
                CheckoutPlan::ReuseWorktree { path, branch } => {
                    json!({"reuseWorktree": {"path": path, "branch": branch}})
                }
                CheckoutPlan::NewWorktree { base } => json!({"newWorktree": {"base": base}}),
            };
            checkouts.push(json!({
                "kind": match kind { CheckoutKind::Local => "local", CheckoutKind::NewWorktree => "newWorktree" },
                "ref": r,
                "plan": plan,
                "label": view::checkout_label(kind, rr.as_ref()),
            }));
        }
    }
    out.insert("checkout".into(), Value::Array(checkouts));

    out.insert(
        "versionTriple".into(),
        Value::Array(
            [
                "0.2.12", "0.2.12-beta.1", "1.0.0+build", " 3.4.5 ", "1.2", "1.2.x", "a.b.c", "1.2.3.4",
                "", "18446744073709551615.0.0", "18446744073709551616.0.0", "+1.2.3", "1.2.-3", "1.2.3-",
            ]
            .iter()
            .map(|v| json!({ "input": v, "output": zeron_proto::version_triple(v).map(|(a, b, c)| vec![a, b, c]) }))
            .collect(),
        ),
    );

    out.insert("sessionStaleMs".into(), json!(view::SESSION_STALE_MS));
    out.insert(
        "dots".into(),
        json!({
            "working": [view::dot::WORKING.0, view::dot::WORKING.1, view::dot::WORKING.2],
            "awaiting": [view::dot::AWAITING.0, view::dot::AWAITING.1, view::dot::AWAITING.2],
            "errored": [view::dot::ERRORED.0, view::dot::ERRORED.1, view::dot::ERRORED.2],
            "completed": [view::dot::COMPLETED.0, view::dot::COMPLETED.1, view::dot::COMPLETED.2],
        }),
    );

    println!("{}", serde_json::to_string_pretty(&Value::Object(out)).unwrap());
}
