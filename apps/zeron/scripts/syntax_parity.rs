//! Dumps zeron_syntax highlight spans and language detection results as JSON
//! for apps/zeron/src/syntax/testdata/parity.json (checked by the Zig port's
//! parity test in apps/zeron/src/syntax/parity_test.zig).
//!
//! Build against the zeron workspace's prebuilt rlibs (no Cargo project needed):
//!   D=$ZERON/target/debug/deps   # after `cargo build -p zeron-syntax` in $ZERON
//!   rustc --edition 2024 syntax_parity.rs -o /tmp/syntax_parity -L $D \
//!     --extern zeron_syntax=$(ls $D/libzeron_syntax-*.rlib)
//!   /tmp/syntax_parity apps/zeron/src/syntax/testdata/samples \
//!     > apps/zeron/src/syntax/testdata/parity.json
//!
//! Every file in the samples directory is highlighted with `path` = its file
//! name; a few extra cases exercise fence tags and shebang detection.

use std::fmt::Write as _;

use zeron_syntax::{
    HighlightKind as K, HighlightRequest, LanguageId, detect_language, highlight,
    language_for_alias, language_for_path,
};

fn kind_name(kind: K) -> &'static str {
    match kind {
        K::Comment => "comment",
        K::Keyword => "keyword",
        K::String => "string",
        K::StringSpecial => "string_special",
        K::Escape => "escape",
        K::Number => "number",
        K::Boolean => "boolean",
        K::Type => "type",
        K::TypeBuiltin => "type_builtin",
        K::Constructor => "constructor",
        K::Function => "function",
        K::FunctionBuiltin => "function_builtin",
        K::Macro => "macro",
        K::Property => "property",
        K::Constant => "constant",
        K::Variable => "variable",
        K::VariableSpecial => "variable_special",
        K::Parameter => "parameter",
        K::Operator => "operator",
        K::Punctuation => "punctuation",
        K::Tag => "tag",
        K::Attribute => "attribute",
        K::Label => "label",
        K::MarkupHeading => "markup_heading",
        K::MarkupRaw => "markup_raw",
        K::MarkupLink => "markup_link",
        K::MarkupReference => "markup_reference",
        K::MarkupEmphasis => "markup_emphasis",
        K::MarkupStrong => "markup_strong",
        K::Embedded => "embedded",
        K::Invalid => "invalid",
    }
}

fn lang(language: Option<LanguageId>) -> String {
    match language {
        Some(l) => format!("\"{l:?}\""),
        None => "null".into(),
    }
}

fn json_str(s: &str) -> String {
    let mut out = String::from("\"");
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => write!(out, "\\u{:04x}", c as u32).unwrap(),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

fn opt_str(s: Option<&str>) -> String {
    s.map_or_else(|| "null".into(), json_str)
}

fn case(out: &mut String, path: Option<&str>, fence: Option<&str>, source: &str) {
    let doc = highlight(HighlightRequest {
        source,
        path,
        fence_tag: fence,
    })
    .unwrap_or_else(|e| panic!("{path:?}/{fence:?}: {e}"));
    write!(
        out,
        "    {{\"path\": {}, \"fence\": {}, \"language\": \"{:?}\", \"source\": {},\n     \"lines\": [",
        opt_str(path),
        opt_str(fence),
        doc.language,
        json_str(source)
    )
    .unwrap();
    for (i, line) in doc.lines.iter().enumerate() {
        out.push_str(if i == 0 { "\n      [" } else { ",\n      [" });
        for (j, span) in line.iter().enumerate() {
            if j > 0 {
                out.push_str(", ");
            }
            write!(
                out,
                "[{}, {}, \"{}\"]",
                span.range.start,
                span.range.end,
                kind_name(span.kind)
            )
            .unwrap();
        }
        out.push(']');
    }
    out.push_str("]}");
}

fn main() {
    let dir = std::env::args().nth(1).expect("usage: syntax_parity <samples-dir>");
    let mut names: Vec<String> = std::fs::read_dir(&dir)
        .unwrap()
        .map(|e| e.unwrap().file_name().into_string().unwrap())
        .collect();
    names.sort();

    let mut out = String::from("{\n  \"cases\": [\n");
    let mut first = true;
    let mut sep = |out: &mut String| {
        if !first {
            out.push_str(",\n");
        }
        first = false;
    };
    for name in &names {
        let source = std::fs::read_to_string(format!("{dir}/{name}")).unwrap();
        sep(&mut out);
        case(&mut out, Some(name), None, &source);
    }
    // Fence tags win over paths; shebangs are the last resort.
    let py = std::fs::read_to_string(format!("{dir}/app.py")).unwrap();
    sep(&mut out);
    case(&mut out, None, Some("python3 {.numberLines}"), &py);
    sep(&mut out);
    case(&mut out, Some("notes.txt"), Some("TS"), "const x: number = 1;\n");
    sep(&mut out);
    case(&mut out, None, None, "#!/bin/sh\necho \"hi\" $HOME\n");
    sep(&mut out);
    case(&mut out, Some("empty.rs"), None, "");
    out.push_str("\n  ],\n");

    let paths = [
        "src/main.rs", "web/app.tsx", "Cargo.toml", "cargo.lock", "pyproject.toml",
        "Dockerfile", "Containerfile", "build/GNUmakefile", "Makefile", "config.jsonc",
        "README", "image.png", "a/b/c.MD", "x.yml", "x.yaml", "x.htm", "x.hpp", "x.cc",
        "x.kts", "x.mjs", "x.cts", "x.golang", "x.py", ".bashrc", "x.zsh", "dir.rs/", "x.",
        "noext", "x.tar.gz", "x.docker",
    ];
    out.push_str("  \"paths\": [\n");
    for (i, p) in paths.iter().enumerate() {
        let sep = if i + 1 < paths.len() { "," } else { "" };
        writeln!(out, "    [{}, {}]{sep}", json_str(p), lang(language_for_path(p))).unwrap();
    }
    out.push_str("  ],\n");

    let aliases = [
        "rust", "RS", "js", "jsx", "ts", "tsx", "mts", "python3", "golang", "json", "jsonc",
        "console", "shell", "zsh", "toml", "md", "htm", "css", "yml", "c", "c++", "C#", "cs",
        "java", "kt", "swift", "rb", "php", "sql", "lua", "docker", "nix", "makefile",
        "  rust  extra", "rust,ignore", "", "   ", "unknown-lang", "Python {.class}",
    ];
    out.push_str("  \"aliases\": [\n");
    for (i, a) in aliases.iter().enumerate() {
        let sep = if i + 1 < aliases.len() { "," } else { "" };
        writeln!(out, "    [{}, {}]{sep}", json_str(a), lang(language_for_alias(a))).unwrap();
    }
    out.push_str("  ],\n");

    let detect: [(Option<&str>, Option<&str>, Option<&str>); 9] = [
        (None, None, Some("#!/usr/bin/env python3")),
        (None, None, Some("#!/usr/bin/env node")),
        (None, None, Some("#!/usr/bin/ruby")),
        (None, None, Some("#!/bin/sh")),
        (None, None, Some("#! /usr/bin/env zsh")),
        (None, None, Some("let x = 1")),
        (Some("a.rs"), Some("py"), None),
        (Some("a.rs"), Some("nope"), Some("#!/bin/bash")),
        (Some("README"), None, Some("#!/usr/bin/env bash")),
    ];
    out.push_str("  \"detect\": [\n");
    for (i, (p, f, l)) in detect.iter().enumerate() {
        let sep = if i + 1 < detect.len() { "," } else { "" };
        writeln!(
            out,
            "    [{}, {}, {}, {}]{sep}",
            opt_str(*p),
            opt_str(*f),
            opt_str(*l),
            lang(detect_language(*p, *f, *l))
        )
        .unwrap();
    }
    out.push_str("  ]\n}\n");
    print!("{out}");
}
