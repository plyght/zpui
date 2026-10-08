//! zeron markdown: block-level model + append-incremental reparse + streaming
//! display mending, ported from `zeron_markdown` (crates/markdown).
//!
//! - `parseFull` builds a `BlockTree` of top-level blocks with source ranges.
//! - `IncrementalParser` reparses only from the last stable top-level block
//!   boundary; `displayTree()` swaps in a mended last block while inline
//!   markers hang (`**bold` streams as bold).
//! - `cmark` is a faithful Zig port of pulldown-cmark 0.12.2 (tables,
//!   strikethrough, task lists — zeron's option set) and exposes the raw
//!   offset event stream.

const std = @import("std");

pub const model = @import("model.zig");
pub const parser = @import("parser.zig");
pub const mend = @import("mend.zig");
pub const json = @import("json.zig");
pub const cmark = @import("cmark/parse.zig");
pub const inline_code_links = @import("inline_code_links.zig");
pub const attachment_mentions = @import("attachment_mentions.zig");

pub const Range = model.Range;
pub const Block = model.Block;
pub const BlockTree = model.BlockTree;
pub const TopBlock = model.TopBlock;
pub const InlineRun = model.InlineRun;
pub const InlineStyle = model.InlineStyle;
pub const InlineImage = model.InlineImage;
pub const TaskMarker = model.TaskMarker;
pub const TableAlign = model.TableAlign;
pub const IncrementalParser = parser.IncrementalParser;
pub const parseFull = parser.parseFull;
pub const closeHanging = mend.closeHanging;
pub const PENDING_LINK_URL = mend.PENDING_LINK_URL;

/// Whether a fenced code block should render as a mermaid diagram (the
/// renderer's check: language equals "mermaid", ASCII case-insensitive).
pub fn isMermaid(language: ?[]const u8) bool {
    const l = language orelse return false;
    return std.ascii.eqlIgnoreCase(l, "mermaid");
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("cmark/scanners.zig");
    _ = @import("cmark/linklabel.zig");
    _ = @import("parser_test.zig");
    _ = @import("parity_test.zig");
}
