//! The benchmark fixture's long chat (docs/BENCHMARKS.md, bench/seed_fixture.py):
//! `turns` user prompts, each answered by the engine's mock script repeated
//! `repeat` times (ZERON_MOCK_REPEAT) plus the code, table and mend passages
//! (ZERON_MOCK_CODE / _TABLE / _MEND), as a WatchDocMessages reset array.

const std = @import("std");

const body_a = "## Streaming pipeline\n\nEvery turn flows through the same path:\n\n" ++
    "1. **Doc command** — the composer queues a durable `run` entry\n2. **Host executor** — the chat's host device marks it processed, then dispatches\n3. **Fold** — events fold into parts and diff into the Loro doc every 120ms\n\n";
const body_c = "The `SegmentWriter` appends into `LoroText` so the oplog stays RLE-merged:\n\n```rust\nfolded = fold_event_into_parts(&folded, &event);\nwriter.sync(&folded)?; // 120ms coalesced commits\n```\n\nSynced to every device through the session room. *Mock harness reporting in.*";
const code_ev = "\n### Code check\n\n" ++
    "The `fold_event_into_parts` helper feeds `writer.sync` on a `120ms` cadence:\n\n" ++
    "```rust\n// Fold one event into the accumulated parts.\npub fn fold(mut acc: Vec<Part>, event: &AgentEvent) -> Vec<Part> {\n    let label = \"delta\";\n    if acc.len() > 128 {\n        acc.truncate(64); // keep the tail hot\n    }\n    acc\n}\n```\n\n" ++
    "```ts\n// Subscribe and fold on the client.\nconst room = await connect(\"wss://mesh.local\", { retries: 3 });\nexport function fold(parts: Part[], event: AgentEvent): Part[] {\n    return event.kind === \"delta\" ? [...parts, event] : parts;\n}\n```\n\n";
const table_ev = "\n### Table check\n\n| Column A | Column B | Column C |\n|---|---|---|\n| a1 | b1 | c1 |\n| a2 | b2 | c2 |\n\nAnd a wide, uneven one:\n\n" ++
    "| Stage | What happens | p95 |\n|:--|:--|--:|\n| Fold | Events fold into parts and diff into the Loro doc on a 120ms coalesced commit cadence, keeping the oplog RLE-merged across devices | 4.2ms |\n| Sync | Session-room fan-out | 18ms |\n\n";
const mend_ev = "\n### Streaming mend check\n\nInline styles hold while text arrives: **bold stays bold**, *italic stays italic*, `code stays code`, and ~~this stays struck~~.\n\n" ++
    "- **Fold** — parts diff into the [Loro doc](https://loro.dev) on a 120ms cadence\n" ++
    "- **Relay** — commits fan out through the [session room](https://developers.cloudflare.com/durable-objects/) to every device\n" ++
    "- **Paint** — the [display tree](https://github.com/pulldown-cmark/pulldown-cmark) mends hanging markers in the last block only\n\n" ++
    "Links above never flash their URLs, and closing markers never reflow the paragraph.\n";

fn writeStr(w: *std.Io.Writer, s: []const u8) !void {
    try std.json.Stringify.value(s, .{}, w);
}

fn writeTool(w: *std.Io.Writer, turn: usize, id: usize, command: []const u8) !void {
    try w.print(",{{\"kind\":\"tool\",\"id\":\"t{d}-{d}\",\"call\":{{\"kind\":\"exec\",\"command\":", .{ turn, id });
    try writeStr(w, command);
    try w.writeAll("},\"resolved\":true}");
}

pub fn benchTranscript(gpa: std.mem.Allocator, turns: usize, repeat: usize) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("[");
    const t0: i64 = 1782920700000;
    for (0..turns) |t| {
        if (t > 0) try w.writeAll(",");
        const ts = t0 + @as(i64, @intCast(t)) * 60_000;
        try w.print("{{\"id\":\"u{d}\",\"role\":\"user\",\"createdAt\":{d},\"deviceId\":\"d\",\"status\":\"complete\",\"parts\":[{{\"kind\":\"text\",\"id\":\"ut{d}\",\"text\":\"Bench turn {d}: walk me through the pipeline\"}}]}},", .{ t, ts, t, t });
        try w.print("{{\"id\":\"a{d}\",\"role\":\"assistant\",\"createdAt\":{d},\"deviceId\":\"d\",\"status\":\"complete\",\"durationMs\":4000,\"parts\":[", .{ t, ts + 1000 });
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(gpa);
        var part: usize = 0;
        for (0..repeat) |r| {
            try text.appendSlice(gpa, body_a);
            try w.print("{s}{{\"kind\":\"text\",\"id\":\"p{d}-{d}\",\"text\":", .{ if (part == 0) "" else ",", t, part });
            try writeStr(w, text.items);
            try w.writeAll("}");
            text.clearRetainingCapacity();
            part += 1;
            try writeTool(w, t, 2 * r, "cargo test --workspace");
            try writeTool(w, t, 2 * r + 1, "git log -5 --oneline --decorate && git merge-base HEAD origin/main");
            try text.appendSlice(gpa, body_c);
        }
        try text.appendSlice(gpa, code_ev ++ table_ev ++ mend_ev);
        try w.print(",{{\"kind\":\"text\",\"id\":\"p{d}-{d}\",\"text\":", .{ t, part });
        try writeStr(w, text.items);
        try w.writeAll("}");
        try writeTool(w, t, 999, "set -e\nfixture_in_original=0\ngrep -rn \"veil\" crates/ui/src | wc -l");
        try w.writeAll("]}");
    }
    try w.writeAll("]");
    return out.toOwnedSlice();
}
