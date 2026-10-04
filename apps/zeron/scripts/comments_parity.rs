//! Dumps zeron `crates/ui/src/comments.rs` outputs for a deterministic corpus
//! as JSON, for apps/zeron/src/model/testdata/comments_parity.json (compared
//! by apps/zeron/src/model/comments_parity_test.zig).
//!
//! comments.rs is compiled verbatim (`#[path]`), with stand-ins for the two
//! crate modules it names (`badges`, `icons`):
//!   D=$ZERON/target/debug/deps
//!   rustc --edition 2024 comments_parity.rs -o /tmp/comments_parity -L $D \
//!     --extern uuid=$(ls $D/libuuid-*.rlib | head -1)
//!   /tmp/comments_parity > apps/zeron/src/model/testdata/comments_parity.json

#![allow(dead_code)]

mod badges {
    pub struct MessageBadge {
        pub icon: &'static str,
        pub label: String,
        pub details: Vec<BadgeDetail>,
    }
    pub struct BadgeDetail {
        pub location: String,
        pub tag: Option<String>,
        pub body: String,
    }
}
mod icons {
    pub const CHAT_ROUND_LINE: &str = "chat-round-line";
}
#[path = "/home/user/zeron/crates/ui/src/comments.rs"]
mod comments;

use comments::{CommentSide, ReviewComment};

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
}

fn q(s: &str) -> String {
    let mut o = String::from("\"");
    for c in s.chars() {
        match c {
            '"' => o.push_str("\\\""),
            '\\' => o.push_str("\\\\"),
            '\n' => o.push_str("\\n"),
            '\r' => o.push_str("\\r"),
            '\t' => o.push_str("\\t"),
            c if (c as u32) < 0x20 => o.push_str(&format!("\\u{:04x}", c as u32)),
            c => o.push(c),
        }
    }
    o.push('"');
    o
}

fn opt(s: Option<&str>) -> String {
    s.map(q).unwrap_or_else(|| "null".into())
}

const PATHS: &[&str] = &["src/main.rs", "a.rs", "odd:path.rs", "dir/with space/ü.zig", "x:12", "lib.rs"];
const OLD: &[&str] = &["old_name.rs", "src/old/main.rs"];
const BODIES: &[&str] = &[
    "fix",
    "early-return here",
    "first\nsecond",
    "  padded body \n",
    "see (L): the other one",
    "compare with (R): new code",
    "change this: please",
    "a.rs:3: looks like a location",
    "multi\nline\n\nwith blank",
    "\u{3000}ideographic space\u{a0}",
    "emoji 🦀 and ünïcödé",
    "x: 1",
    "tab\there",
    "crlf\r\nline",
    "- looks like a bullet",
    "",
    "Revised\nMore detail",
];
const TEXTS: &[&str] = &["", "look at these", "ship it", "multi\nline prompt", "quote: Comments on the diff"];

fn comment_json(c: &ReviewComment) -> String {
    let (kind, side, old) = match &c.source {
        comments::CommentSource::Diff { side, old_path } => ("diff", Some(side.tag()), old_path.as_deref()),
        comments::CommentSource::File => ("file", None, None),
    };
    format!(
        "{{\"path\":{},\"line\":{},\"body\":{},\"kind\":{},\"side\":{},\"oldPath\":{}}}",
        q(&c.path),
        c.line,
        q(&c.body),
        q(kind),
        opt(side),
        opt(old)
    )
}

fn extract_json(text: &str) -> String {
    match comments::extract_badge(text) {
        None => "null".into(),
        Some((rest, badge)) => {
            let details: Vec<String> = badge
                .details
                .iter()
                .map(|d| format!("{{\"location\":{},\"tag\":{},\"body\":{}}}", q(&d.location), opt(d.tag.as_deref()), q(&d.body)))
                .collect();
            format!("{{\"text\":{},\"label\":{},\"details\":[{}]}}", q(&rest), q(&badge.label), details.join(","))
        }
    }
}

fn main() {
    let mut rng = Rng(0x5eed_c0de_1234_5678);
    let mut cases = Vec::new();
    for _ in 0..240 {
        let n = rng.below(4) as usize;
        let mut staged = Vec::new();
        for _ in 0..n {
            let path = *rng.pick(PATHS);
            let body = *rng.pick(BODIES);
            let line = *rng.pick(&[1u32, 3, 7, 42, 1494, 100000]);
            let c = match rng.below(3) {
                0 => ReviewComment::file(path, line, body),
                1 => ReviewComment::new(path, CommentSide::Old, line, body)
                    .renamed_from(if rng.below(2) == 0 { Some(*rng.pick(OLD)) } else { None }),
                _ => ReviewComment::new(path, CommentSide::New, line, body)
                    .renamed_from(if rng.below(3) == 0 { Some(*rng.pick(OLD)) } else { None }),
            };
            staged.push(c);
        }
        let text = *rng.pick(TEXTS);
        let out = comments::with_comments(text, &staged);
        let cs: Vec<String> = staged.iter().map(comment_json).collect();
        cases.push(format!(
            "{{\"text\":{},\"comments\":[{}],\"prompt\":{},\"extracted\":{}}}",
            q(text),
            cs.join(","),
            q(&out),
            extract_json(&out)
        ));
    }
    // Hand-written blocks: malformed tails, quoted headers, CRLF, mid-body headers.
    let h = comments::COMMENT_BLOCK_HEADER;
    let r = comments::REVIEW_COMMENT_BLOCK_HEADER;
    let raw = [
        format!("x\n\n{h}\n"),
        format!("x\n\n{h}\n- a.rs:1 (R): ok\nnot a bullet"),
        format!("x\n\n{h}\n- a.rs:1 (R): ok\n\n- b.rs:2 (L): blank line"),
        format!("x\n\n{h}\n- a.rs:1 (R): ok\r\n  more\r\n"),
        format!("x\n\n{h}\n- no location here"),
        format!("x\n\n{h}\n- a.rs:+5: plus sign"),
        format!("x\n\n{h}\n- a.rs:1_0: underscore"),
        format!("x\n\n{h}\n- a.rs:99999999999: overflow"),
        format!("x\n\n{h}\n  orphan continuation\n- a.rs:2 (L): then"),
        format!("x\n\n{r}\n- a.rs:3: one\n\n{h}\n- b.rs:4 (R): two"),
        format!("x\n\n{h}\n- a.rs:3 (R): one\n\n{r}\n- b.rs:4: two"),
        format!("quoting\n\n{h}\nmid body\n\nthen text"),
        format!("{h}\n- a.rs:1 (R): no leading blank line"),
        format!("x\n\n{r}\n- p:1: a (L): b"),
        format!("x\n\n{r}\n- p (L): a:1: b"),
        format!("x\n\n{r}\n- :1: empty path"),
        format!("x\n\n{h}\n- a.rs:1 (R): "),
    ];
    let raws: Vec<String> = raw.iter().map(|t| format!("{{\"text\":{},\"extracted\":{}}}", q(t), extract_json(t))).collect();
    let mut metrics = Vec::new();
    let mut bodies: Vec<String> = BODIES.iter().map(|s| s.to_string()).collect();
    bodies.push("x".repeat(64));
    bodies.push("x".repeat(65));
    bodies.push("ü".repeat(130));
    bodies.push("line\n".repeat(200));
    bodies.push(format!("{}\n{}", "y".repeat(200), "z".repeat(10)));
    for b in &bodies {
        metrics.push(format!(
            "{{\"body\":{},\"lines\":{},\"height\":{}}}",
            q(b),
            comments::card_body_lines(b),
            comments::card_height(b)
        ));
    }
    let chips: Vec<String> = [0usize, 1, 2, 11].iter().map(|n| q(&comments::chip_label(*n))).collect();
    println!(
        "{{\"cases\":[\n{}\n],\"raw\":[\n{}\n],\"metrics\":[\n{}\n],\"chips\":[{}]}}",
        cases.join(",\n"),
        raws.join(",\n"),
        metrics.join(",\n"),
        chips.join(",")
    );
}
