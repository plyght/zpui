//! Dumps the pure logic behind custom sidebar sections, the sync wizard,
//! project actions and the plan-usage ring as JSON, for
//! apps/zeron/src/ui/shell/testdata/sidebar_sync_parity.json (compared by
//! apps/zeron/src/ui/shell/sidebar_sync_parity_test.zig).
//!
//! `SidebarSectionChange::project` / `SidebarPinChange::project_sections` are
//! public in zeron_proto and called directly. The shell's helpers are private
//! to the gpui crate, so they are lifted VERBATIM into a generated include:
//!   Z=$ZERON  D=$Z/target/debug/deps  S=/tmp/sync_parity  U=$Z/crates/ui/src
//!   mkdir -p $S && { sed -n '1427,1503p' $U/shell.rs; sed -n '1536,1544p' $U/shell.rs;
//!     sed -n '1614,1754p' $U/shell.rs; sed -n '212,246p;257,260p' $U/project_actions.rs;
//!     sed -n '31,48p' $U/account_usage.rs; } > $S/lifted.rs
//!   SYNC_LIFTED=$S/lifted.rs rustc --edition 2024 sidebar_sync_parity.rs -o $S/run -L $D \
//!     --extern zeron_proto=$(ls $D/libzeron_proto-*.rlib) \
//!     --extern serde_json=<the libserde_json-*.rlib zeron_proto links>
//!   $S/run > apps/zeron/src/ui/shell/testdata/sidebar_sync_parity.json
//! (line ranges are for zeron 9e1a111; re-check them when the pin moves).

#![allow(dead_code)]

use serde_json::{Value, json};
use zeron_proto::{
    AgentAccount, AgentAccountsSnapshot, AuthState, HarnessId, ProjectAction, ProjectActionIcon,
    SidebarPinChange, SidebarSection, SidebarSectionChange, UserProfile, WorkspaceScope,
};

type SharedString = String;

/// `crate::icons` (only the action glyph names are referenced by the lift).
mod icons {
    pub const ACTION_PLAY: &str = "action-play";
    pub const ACTION_TEST: &str = "action-test";
    pub const ACTION_LINT: &str = "action-lint";
    pub const ACTION_CONFIGURE: &str = "action-configure";
    pub const ACTION_BUILD: &str = "action-build";
    pub const ACTION_DEBUG: &str = "action-debug";
}

include!(env!("SYNC_LIFTED"));

fn flow_json(f: SyncFlow) -> Value {
    match f {
        SyncFlow::Idle => json!({"kind":"idle"}),
        SyncFlow::Enabling => json!({"kind":"enabling"}),
        SyncFlow::Canceling => json!({"kind":"canceling"}),
        SyncFlow::SwitchOffer { notice_open } => json!({"kind":"switch_offer","b":notice_open}),
        SyncFlow::Switching { import } => json!({"kind":"switching","b":import}),
        SyncFlow::Importing { done, total } => json!({"kind":"importing","a":done,"c":total}),
        SyncFlow::ImportDone { imported, skipped } => json!({"kind":"import_done","a":imported,"c":skipped}),
        SyncFlow::ImportFailed { notice_open } => json!({"kind":"import_failed","b":notice_open}),
        SyncFlow::RestartPending { notice_open } => json!({"kind":"restart_pending","b":notice_open}),
        SyncFlow::SignOutConfirm => json!({"kind":"sign_out_confirm"}),
        SyncFlow::SigningOut => json!({"kind":"signing_out"}),
        SyncFlow::SignedOutRestartRequired => json!({"kind":"signed_out_restart_required"}),
    }
}

fn flows() -> Vec<SyncFlow> {
    let mut v = vec![SyncFlow::Idle, SyncFlow::Enabling, SyncFlow::Canceling];
    for b in [false, true] {
        v.push(SyncFlow::SwitchOffer { notice_open: b });
        v.push(SyncFlow::Switching { import: b });
        v.push(SyncFlow::ImportFailed { notice_open: b });
        v.push(SyncFlow::RestartPending { notice_open: b });
    }
    v.push(SyncFlow::Importing { done: 1, total: 3 });
    v.push(SyncFlow::ImportDone { imported: 2, skipped: 1 });
    v.extend([SyncFlow::SignOutConfirm, SyncFlow::SigningOut, SyncFlow::SignedOutRestartRequired]);
    v
}

fn menu_json(a: Option<AccountMenuAction>) -> Value {
    match a {
        None => Value::Null,
        Some(AccountMenuAction::EnableSync) => json!("enable_sync"),
        Some(AccountMenuAction::SyncInProgress) => json!("sync_in_progress"),
        Some(AccountMenuAction::RestartPending) => json!("restart_pending"),
        Some(AccountMenuAction::SignOut) => json!("sign_out"),
    }
}

fn main() {
    // ---- sections -----------------------------------------------------------------------
    let sec = |id: &str, name: &str, ids: &[&str], collapsed: bool| SidebarSection {
        id: id.into(),
        name: name.into(),
        session_ids: ids.iter().map(|s| s.to_string()).collect(),
        collapsed,
    };
    let start = vec![sec("a", "Focus", &["x", "y"], false), sec("b", "Later", &[], true)];
    let scripts: Vec<Vec<SidebarPinChange>> = vec![
        vec![
            SidebarPinChange::Section { change: SidebarSectionChange::Create { id: "c".into(), name: "New".into() } },
            SidebarPinChange::Section { change: SidebarSectionChange::Create { id: "a".into(), name: "Dup".into() } },
            SidebarPinChange::Section { change: SidebarSectionChange::Rename { id: "b".into(), name: "Today".into() } },
            SidebarPinChange::Section { change: SidebarSectionChange::Rename { id: "zz".into(), name: "Nope".into() } },
        ],
        vec![
            SidebarPinChange::Section { change: SidebarSectionChange::Assign { session_id: "x".into(), section_id: Some("b".into()) } },
            SidebarPinChange::Section { change: SidebarSectionChange::Assign { session_id: "y".into(), section_id: None } },
            SidebarPinChange::Section { change: SidebarSectionChange::Assign { session_id: "z".into(), section_id: Some("gone".into()) } },
            SidebarPinChange::Section { change: SidebarSectionChange::Collapse { id: "a".into(), collapsed: true } },
        ],
        vec![
            SidebarPinChange::Pin { session_id: "x".into(), after: None, before: None },
            SidebarPinChange::Move { session_id: "y".into(), after: None, before: None },
            SidebarPinChange::Unpin { session_id: "y".into() },
            SidebarPinChange::Section { change: SidebarSectionChange::Delete { id: "a".into() } },
            SidebarPinChange::Section { change: SidebarSectionChange::Import { sections: vec![sec("q", "Q", &[], false)] } },
        ],
    ];
    let mut sections_out = Vec::new();
    for script in scripts {
        let mut cur = start.clone();
        let mut steps = Vec::new();
        for change in script {
            change.project_sections(&mut cur);
            steps.push(json!({"change": change, "after": cur}));
        }
        sections_out.push(json!({"start": start, "steps": steps}));
    }

    // ---- sync flow ------------------------------------------------------------------------
    let user = UserProfile { id: "u1".into(), email: "ada@example.test".into(), name: Some("  Ada  ".into()) };
    let auths: Vec<Option<AuthState>> = vec![
        None,
        Some(AuthState::SignedOut),
        Some(AuthState::NeedsOrganization { user: user.clone() }),
        Some(AuthState::SignedIn { user: user.clone(), org_id: Some("org".into()) }),
    ];
    let scopes = [None, Some(WorkspaceScope::Local), Some(WorkspaceScope::Synced), Some(WorkspaceScope::Development)];
    let mut after_auth = Vec::new();
    let mut menus = Vec::new();
    let mut identities = Vec::new();
    for flow in flows() {
        for scope in scopes {
            menus.push(json!({"flow": flow_json(flow), "scope": scope, "action": menu_json(account_menu_action(scope, flow))}));
            for user in [None, Some(user.clone()), Some(UserProfile { id: "u2".into(), email: "b@x.test".into(), name: None })] {
                let (label, identity) = sidebar_account_identity(scope, flow, user.as_ref());
                identities.push(json!({"flow": flow_json(flow), "scope": scope, "user": user, "label": label, "identity": identity}));
            }
            for auth in &auths {
                after_auth.push(json!({"flow": flow_json(flow), "scope": scope, "auth": auth,
                    "next": flow_json(sync_flow_after_auth(flow, scope, auth.as_ref()))}));
            }
        }
    }
    let mut phrases = Vec::new();
    for chats in [0usize, 1, 2] {
        for spaces in [0usize, 1, 3] {
            phrases.push(json!({"chats": chats, "spaces": spaces, "phrase": local_work_phrase(chats, spaces)}));
        }
    }
    let summaries: Vec<Value> = [
        json!({"kind":"summary","importedChats":3,"skippedChats":1,"errors":[]}),
        json!({"kind":"summary","importedChats":0}),
        json!({"kind":"summary","importedChats":2,"errors":["disk full"]}),
        json!({"kind":"summary","importedChats":5,"skippedChats":2,"errors":["a","b","c"]}),
        json!({"kind":"summary","errors":[1, "only strings count"]}),
    ]
    .into_iter()
    .map(|item| {
        let out = match import_summary_outcome(&item) {
            Ok((imported, skipped)) => json!({"ok": [imported, skipped]}),
            Err(message) => json!({"err": message}),
        };
        json!({"item": item, "outcome": out})
    })
    .collect();

    // ---- project actions ---------------------------------------------------------------------
    let act = |id: &str, setup: bool| ProjectAction {
        id: id.into(),
        name: id.into(),
        command: id.into(),
        icon: ProjectActionIcon::Play,
        run_on_worktree_create: setup,
    };
    let lists = vec![vec![], vec![act("setup", true)], vec![act("setup", true), act("dev", false), act("test", false)]];
    let mut preferred = Vec::new();
    for actions in &lists {
        for pref in [None, Some("setup"), Some("test"), Some("gone")] {
            preferred.push(json!({"actions": actions, "preferred": pref,
                "chosen": preferred_action(actions, pref).map(|a| a.id.clone())}));
        }
    }
    let labels: Vec<Value> = [0.0f32, 419.0, 419.99, 420.0, 900.0]
        .iter()
        .map(|w| json!({"width": w, "show": show_action_label(*w)}))
        .collect();
    let unknown: Vec<Value> = ["Unknown method ListProjectActions", "UNKNOWNMETHOD", "offline", "unknown  method"]
        .iter()
        .map(|m| json!({"message": m, "unknown": unknown_method(m)}))
        .collect();

    // ---- plan usage ---------------------------------------------------------------------------
    let account = |h: HarnessId, id: &str, active: bool, used: &[f32]| -> AgentAccount {
        serde_json::from_value(json!({"id": id, "harness": h, "active": active, "switchable": true,
            "usageWindows": used.iter().map(|f| json!({"label":"5h","usedFraction":f})).collect::<Vec<_>>()}))
        .unwrap()
    };
    let snapshot = AgentAccountsSnapshot {
        accounts: vec![
            account(HarnessId::ClaudeCode, "c1", true, &[0.3, 0.91]),
            account(HarnessId::Codex, "x1", false, &[0.1]),
            account(HarnessId::Codex, "x2", true, &[1.4, -0.2]),
            account(HarnessId::Cursor, "k1", false, &[]),
        ],
        warnings: vec![],
    };
    let usage: Vec<Value> = [HarnessId::ClaudeCode, HarnessId::Codex, HarnessId::Cursor, HarnessId::Antigravity]
        .iter()
        .map(|h| {
            let active = active_account(&snapshot, *h);
            json!({"harness": h, "active": active.map(|a| a.id.clone()), "fraction": active.and_then(used_fraction)})
        })
        .collect();

    println!(
        "{}",
        serde_json::to_string_pretty(&json!({
            "sections": sections_out,
            "after_auth": after_auth,
            "menus": menus,
            "identities": identities,
            "phrases": phrases,
            "summaries": summaries,
            "preferred": preferred,
            "labels": labels,
            "unknown": unknown,
            "usage": {"snapshot": snapshot, "cases": usage},
        }))
        .unwrap()
    );
}
