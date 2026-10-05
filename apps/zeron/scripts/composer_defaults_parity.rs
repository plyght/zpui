//! Rust side of the composer-defaults compatibility check (zeron
//! `crates/ui/src/settings/composer.rs` + `settings.rs`), for
//! apps/zeron/src/model/testdata/composer_defaults_rust.json (read by
//! apps/zeron/src/model/composer_store.zig's tests).
//!
//!   Z=$ZERON  D=$Z/target/debug/deps  S=/tmp/cd_parity
//!   rustc --edition 2024 composer_defaults_parity.rs -o $S/run -L $D \
//!     --extern zeron_ui=$(ls $D/libzeron_ui-*.rlib) \
//!     --extern zeron_proto=$(ls $D/libzeron_proto-*.rlib) \
//!     --extern serde_json=<the libserde_json-*.rlib zeron_ui links>
//!   $S/run > apps/zeron/src/model/testdata/composer_defaults_rust.json   # fixture
//!   $S/run <data_dir>        # load a Zig-written data dir; prints what Rust sees
//!
//! The second form checks the other direction: `composer-defaults.json`
//! written by the Zig client loads in Rust unchanged, and Rust's
//! `ui-settings.json` loader still accepts the data dir.

use zeron_proto::{HarnessId, ReasoningLevel};
use zeron_ui::settings::UiSettings;
use zeron_ui::settings::composer::ComposerDefaults;

fn main() {
    if let Some(dir) = std::env::args().nth(1) {
        let dir = std::path::Path::new(&dir);
        let d = ComposerDefaults::load(dir);
        let s = UiSettings::load(dir);
        let out = serde_json::json!({
            "composerDefaults": d,
            "uiSettingsSidebarWidth": s.sidebar_width,
        });
        println!("{}", serde_json::to_string_pretty(&out).unwrap());
        return;
    }
    let mut d = ComposerDefaults::default();
    d.remember_model(HarnessId::ClaudeCode, "claude-fable-5".into(), "Fable 5".into());
    d.remember_model(HarnessId::Codex, "gpt-5.2-codex".into(), "GPT-5.2 Codex".into());
    d.remember_reasoning(HarnessId::Codex, Some("gpt-5.2-codex"), ReasoningLevel::XHigh);
    d.model_options_mut(HarnessId::ClaudeCode, "claude-fable-5")
        .insert("contextWindow".into(), "1m".into());
    d.remember_labels([("claude-fable-5", "Fable 5"), ("gpt-5.2-codex", "GPT-5.2 Codex")].into_iter());
    d.toggle_favorite(HarnessId::ClaudeCode, "claude-fable-5");
    d.device = Some("dev-1".into());
    let dir = std::env::temp_dir().join(format!("cd-parity-{}", std::process::id()));
    d.save(&dir).unwrap();
    print!("{}", std::fs::read_to_string(ComposerDefaults::path(&dir)).unwrap());
    let _ = std::fs::remove_dir_all(&dir);
}
