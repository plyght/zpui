//! Dumps the Rust Mermaid pipeline's output for the Zig parity tests in
//! apps/zeron/src/mermaid/parity_test.zig.
//!
//! For every `<name>.mmd` in the testdata dir (apps/zeron/src/mermaid/testdata)
//! it writes, under `<dir>/rust/`:
//!   <name>.light.svg / <name>.dark.svg — `zeron_ui::markdown::mermaid::render`
//!       with `Palette::from_theme(Theme::light()/dark())` (engine + restyle),
//!       or `<name>.light.err` with the error text;
//!   <name>.raw.svg — `mermaid_rs_renderer::render_with_options` with zeron's
//!       light options, before zeron's restyle;
//!   <name>.layout.json — the engine's `LayoutDump` for the same options.
//!
//! Build against the zeron workspace's prebuilt rlibs (no Cargo project):
//!   D=$ZERON/target/debug/deps
//!   rustc --edition 2024 mermaid_parity.rs -o /tmp/mermaid_parity -L $D \
//!     --extern zeron_ui=$(ls $D/libzeron_ui-*.rlib) \
//!     --extern mermaid_rs_renderer=$(ls $D/libmermaid_rs_renderer-*.rlib) \
//!     --extern serde_json=<the libserde_json-*.rlib mermaid_rs_renderer links>
//!   /tmp/mermaid_parity apps/zeron/src/mermaid/testdata

use mermaid_rs_renderer as mmdr;
use zeron_ui::markdown::mermaid::{Palette, render};
use zeron_ui::theme::Theme;

/// zeron's `markdown::mermaid::render` options, minus the restyle.
fn zeron_options(theme: &Theme, source: &str) -> mmdr::RenderOptions {
    // Palette fields are private; reproduce them through the SVG the palette
    // produces is not possible, so rebuild the options the same way the
    // adapter does from public theme values.
    let dark = theme.appearance.is_dark();
    let mut options = mmdr::RenderOptions::default();
    options.theme = if dark { mmdr::Theme::dark() } else { mmdr::Theme::modern() };
    options.layout.node_spacing = 36.0;
    options.layout.rank_spacing = 40.0;
    options.layout.node_padding_x = 18.0;
    options.layout.node_padding_y = 10.0;
    let p = palette_strings(theme);
    let t = &mut options.theme;
    t.font_family = theme.font_sans.to_string();
    t.font_size = 14.0;
    t.background = p.canvas.clone();
    t.primary_color = p.node.clone();
    t.primary_text_color = p.text.clone();
    t.primary_border_color = p.border.clone();
    t.text_color = p.label.clone();
    t.line_color = p.line.clone();
    t.secondary_color = p.node.clone();
    t.tertiary_color = p.group.clone();
    t.edge_label_background = p.canvas.clone();
    t.cluster_background = p.group.clone();
    t.cluster_border = p.border.clone();
    t.sequence_actor_fill = p.node.clone();
    t.sequence_actor_border = p.border.clone();
    t.sequence_actor_line = p.border.clone();
    t.sequence_note_fill = p.accent_wash.clone();
    t.sequence_note_border = p.accent_line.clone();
    t.sequence_activation_fill = p.accent_wash.clone();
    t.sequence_activation_border = p.accent_line.clone();
    if source.lines().map(str::trim).find(|l| !l.is_empty() && !l.starts_with("%%")).and_then(|l| l.split_whitespace().next()) == Some("gantt") {
        t.primary_border_color = p.accent_line.clone();
    }
    options
}

struct P {
    canvas: String,
    node: String,
    group: String,
    text: String,
    label: String,
    line: String,
    border: String,
    accent_line: String,
    accent_wash: String,
}

fn color(color: gpui::Hsla, background: gpui::Hsla) -> String {
    let mut c = color.to_rgb();
    let bg = background.to_rgb();
    c.r = c.r * c.a + bg.r * (1.0 - c.a);
    c.g = c.g * c.a + bg.g * (1.0 - c.a);
    c.b = c.b * c.a + bg.b * (1.0 - c.a);
    format!(
        "#{:02x}{:02x}{:02x}",
        (c.r * 255.0).round() as u8,
        (c.g * 255.0).round() as u8,
        (c.b * 255.0).round() as u8
    )
}

fn palette_strings(theme: &Theme) -> P {
    let dark = theme.appearance.is_dark();
    let canvas = Palette::plate(theme);
    let node = if dark { canvas.blend(theme.ink(0.06)) } else { theme.bg };
    P {
        canvas: color(canvas, theme.bg),
        node: color(node, canvas),
        group: color(theme.ink(0.03), canvas),
        text: color(theme.text, node),
        label: color(theme.text_muted, canvas),
        line: color(theme.text_faint, canvas),
        border: color(theme.border_strong, canvas),
        accent_line: color(theme.accent.opacity(0.6), canvas),
        accent_wash: color(theme.accent.opacity(0.12), node),
    }
}

fn main() {
    let dir = std::env::args().nth(1).expect("usage: mermaid_parity <testdata dir>");
    let out = format!("{dir}/rust");
    std::fs::create_dir_all(&out).unwrap();
    let mut names: Vec<String> = std::fs::read_dir(&dir)
        .unwrap()
        .filter_map(|e| e.ok())
        .map(|e| e.file_name().to_string_lossy().to_string())
        .filter(|n| n.ends_with(".mmd"))
        .collect();
    names.sort();
    let light = Theme::light();
    let dark = Theme::dark();
    // The palette strings, for the Zig side's palette parity test.
    let mut pal = String::new();
    for (mode, theme) in [("light", &light), ("dark", &dark)] {
        let p = palette_strings(theme);
        pal.push_str(&format!(
            "{mode} font={} canvas={} node={} group={} text={} label={} line={} border={} accent_line={} accent_wash={}\n",
            theme.font_sans, p.canvas, p.node, p.group, p.text, p.label, p.line, p.border, p.accent_line, p.accent_wash
        ));
    }
    std::fs::write(format!("{out}/palette.txt"), pal).unwrap();
    for name in names {
        let stem = name.trim_end_matches(".mmd");
        let source = std::fs::read_to_string(format!("{dir}/{name}")).unwrap();
        for (mode, theme) in [("light", &light), ("dark", &dark)] {
            let palette = Palette::from_theme(theme);
            match render(&source, &palette) {
                Ok(svg) => std::fs::write(format!("{out}/{stem}.{mode}.svg"), svg).unwrap(),
                Err(e) => std::fs::write(format!("{out}/{stem}.{mode}.err"), e).unwrap(),
            }
        }
        let options = zeron_options(&light, &source);
        match mmdr::parse_mermaid_strict(&source) {
            Ok(parsed) => {
                let layout = mmdr::compute_layout(&parsed.graph, &options.theme, &options.layout);
                let dump = mmdr::layout_dump::LayoutDump::from_layout(&layout, &parsed.graph);
                std::fs::write(format!("{out}/{stem}.layout.json"), serde_json::to_string_pretty(&dump).unwrap()).unwrap();
                let svg = mmdr::render_svg(&layout, &options.theme, &options.layout);
                std::fs::write(format!("{out}/{stem}.raw.svg"), svg).unwrap();
            }
            Err(e) => std::fs::write(format!("{out}/{stem}.raw.err"), e.to_string()).unwrap(),
        }
        eprintln!("{stem}");
    }
}
