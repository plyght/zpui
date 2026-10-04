//! BlockTree → zpui elements — port of zeron `crates/ui/src/markdown/render.rs`.
//!
//! Numbers drive layout (font sizes, line heights, paddings — all constants
//! here, from zeron's md theme); colors are paint. Code blocks render per line
//! so their height is exactly `lines × line_height`, and syntax highlighting
//! only recolors runs of the identical mono font (layout never changes).
//!
//! ```zig
//! const md = @import("zeron_ui_markdown");
//! div().child(md.render(tree, .{ .theme = &theme, .key = row_hash }, window));
//! ```
//! Reusable outside the transcript (previews, PR descriptions): pass
//! `.copy = false` / `.fit_toggle = false` / `.tasks = .checkbox` as needed.

const std = @import("std");
const zpui = @import("zpui");
const zt = @import("zeron_theme");
const mdm = @import("zeron_markdown");
const syntax = @import("zeron_syntax");
const assets = @import("zeron_assets");

pub const rich_text = @import("rich_text.zig");
pub const file_icons = @import("file_icons.zig");
pub const RichText = rich_text.RichText;
pub const registry = rich_text.registry;

const App = zpui.App;
const Window = zpui.Window;
const Hsla = zpui.Hsla;
const AnyElement = zpui.AnyElement;
const Div = zpui.Div;
const div = zpui.div;
const px = zpui.px;
const sb = zpui.StyleBuilder.init;
const TextRun = zpui.text.TextRun;
const Font = zpui.text.Font;
const Theme = zt.Theme;
const Block = mdm.Block;
const BlockTree = mdm.BlockTree;
const InlineRun = mdm.InlineRun;
const Range = rich_text.Range;

// ---------------------------------------------------------------------------
// Metrics (render.rs constants)
// ---------------------------------------------------------------------------

/// Gap between markdown blocks inside one message (zeron mdBlockGap).
pub const block_gap: f32 = 12.0;
pub const text_size: f32 = 14.0;
pub const line_height: f32 = 22.0;
pub const code_text_size: f32 = 12.5;
pub const code_line_height: f32 = 18.0;
pub const code_line_height_ratio: f32 = code_line_height / code_text_size;
pub const code_padding_x: f32 = 12.0;
pub const code_padding_y: f32 = 10.0;
pub const code_header_height: f32 = 28.0;
pub const code_action_size: f32 = 22.0;
pub const table_cell_padding: f32 = 12.0;
pub const table_divider: f32 = 1.0;
pub const table_min_column_content: f32 = 48.0;
pub const table_min_column_width: f32 = 96.0;
pub const inline_code_radius: f32 = 4.5;
pub const inline_code_pad_x: f32 = 2.0;
pub const inline_code_inset_y: f32 = 2.0;

/// Tight monochrome heading scale (19/27, 16/24, 15/22, 14/22).
pub fn headingMetrics(level: u8) struct { f32, f32 } {
    return switch (level) {
        1 => .{ 19, 27 },
        2 => .{ 16, 24 },
        3 => .{ 15, 22 },
        else => .{ 14, 22 },
    };
}

pub const TaskMode = enum {
    /// Task markers stay in the text ("[x] done") — the transcript's choice
    /// (zeron passes no `TaskUi` there).
    text,
    /// Read-only 16px checkboxes (gpui-base `Checkbox` styling).
    checkbox,
};

pub const Options = struct {
    theme: *const Theme,
    /// Stable row/document key: prefixes element ids and selection keys.
    key: u64,
    /// Code-block copy button (transcript: on).
    copy: bool = true,
    /// Transcript-only "Fit content" (wrap) toggle in the code header.
    fit_toggle: bool = false,
    tasks: TaskMode = .text,
    /// Render inline images as images (local paths); off = alt text.
    images: bool = false,
    /// Syntax-highlight code blocks.
    highlight: bool = true,
    /// Drag-selectable text.
    selectable: bool = true,
    /// Resolved `file://` links get the trailing open glyph, and a paragraph
    /// that is a single file link gets the file-icon tile (transcript).
    file_links: bool = false,
};

// ---------------------------------------------------------------------------
// Process-wide UI state for code blocks (copy feedback, fit toggles,
// highlight cache) — main thread only.
// ---------------------------------------------------------------------------

pub const code_state = struct {
    const gpa = std.heap.smp_allocator;
    var codes: std.AutoHashMapUnmanaged(u64, []u8) = .empty;
    var fit: std.AutoHashMapUnmanaged(u64, void) = .empty;
    pub var copied_key: u64 = 0;
    pub var copied_at_ns: u64 = 0;
    pub const copied_feedback_ns: u64 = 1600 * std.time.ns_per_ms;

    var highlights: std.AutoHashMapUnmanaged(u64, ?syntax.HighlightedDocument) = .empty;

    fn putCode(key: u64, code: []const u8) void {
        if (codes.get(key)) |old| {
            if (std.mem.eql(u8, old, code)) return;
            gpa.free(old);
            _ = codes.remove(key);
        }
        if (codes.count() > 4096) {
            var it = codes.valueIterator();
            while (it.next()) |v| gpa.free(v.*);
            codes.clearRetainingCapacity();
        }
        const owned = gpa.dupe(u8, code) catch return;
        codes.put(gpa, key, owned) catch gpa.free(owned);
    }

    pub fn isFit(key: u64) bool {
        return fit.contains(key);
    }

    pub fn toggleFit(key: u64) void {
        if (fit.contains(key)) _ = fit.remove(key) else fit.put(gpa, key, {}) catch {};
    }

    /// Highlighted lines for `code` (cached by content + fence language).
    pub fn highlight(code: []const u8, language: []const u8) ?*const syntax.HighlightedDocument {
        return highlightRequest(.{ .source = code, .fence_tag = language });
    }

    /// Highlighted lines for a file's text, language from its path.
    pub fn highlightPath(code: []const u8, path: []const u8) ?*const syntax.HighlightedDocument {
        return highlightRequest(.{ .source = code, .path = path });
    }

    pub fn highlightRequest(req: syntax.HighlightRequest) ?*const syntax.HighlightedDocument {
        var h = std.hash.Wyhash.init(0x5eed);
        h.update(req.fence_tag orelse "");
        h.update(&.{0});
        h.update(req.path orelse "");
        h.update(&.{0});
        h.update(req.source);
        const k = h.final();
        if (highlights.getPtr(k)) |d| return if (d.*) |*doc| doc else null;
        const doc: ?syntax.HighlightedDocument = syntax.highlight(gpa, req) catch null;
        highlights.put(gpa, k, doc) catch {
            if (doc) |d| {
                var dd = d;
                dd.deinit(gpa);
            }
            return null;
        };
        return if (highlights.getPtr(k).?.*) |*d| d else null;
    }

    /// Bound the highlight cache; call between frames (never while spans
    /// from it are being read).
    pub fn trim() void {
        if (highlights.count() <= 384) return;
        var it = highlights.valueIterator();
        while (it.next()) |v| if (v.*) |*d| d.deinit(gpa);
        highlights.clearRetainingCapacity();
    }

    pub fn isCopied(key: u64, now_ns: u64) bool {
        return copied_key == key and now_ns -% copied_at_ns < copied_feedback_ns;
    }
};

fn copyListener(key: u64) zpui.Listener(zpui.ClickEvent) {
    var l: zpui.Listener(zpui.ClickEvent) = .{ .func = struct {
        fn f(data: *const zpui.core.context.ListenerData, _: *const zpui.ClickEvent, window: ?*Window, app: *App) void {
            const k = data.get(u64);
            app.propagate_event = false;
            const code = code_state.codes.get(k) orelse return;
            copyToClipboard(app, code);
            code_state.copied_key = k;
            code_state.copied_at_ns = app.executor.now();
            if (window) |w| w.refresh();
            scheduleRefresh(app, code_state.copied_feedback_ns + 16 * std.time.ns_per_ms);
        }
    }.f };
    l.data.set(key);
    return l;
}

fn fitListener(key: u64) zpui.Listener(zpui.ClickEvent) {
    var l: zpui.Listener(zpui.ClickEvent) = .{ .func = struct {
        fn f(data: *const zpui.core.context.ListenerData, _: *const zpui.ClickEvent, window: ?*Window, app: *App) void {
            app.propagate_event = false;
            code_state.toggleFit(data.get(u64));
            if (window) |w| w.refresh();
        }
    }.f };
    l.data.set(key);
    return l;
}

/// Write `text` to the system clipboard.
pub fn copyToClipboard(app: *App, text: []const u8) void {
    app.platform.vtable.writeClipboard(app.platform.ptr, text);
}

/// Redraw every window after `delay_ns` (transient feedback expiry).
pub fn scheduleRefresh(app: *App, delay_ns: u64) void {
    const Job = struct {
        app: *App,
        pub fn finish(self: *@This()) void {
            self.app.refreshWindows();
        }
    };
    var task = app.foregroundExecutor().timer(delay_ns, Job{ .app = app }) catch return;
    task.detach();
}

// ---------------------------------------------------------------------------
// Public builders
// ---------------------------------------------------------------------------

/// Render a whole tree: blocks stacked with the 12px block gap.
pub fn render(tree: BlockTree, opts: Options, window: *Window) Div {
    const o = frameOpts(opts);
    var col = div().flex().flexCol().gap(px(block_gap)).minW0();
    for (tree.blocks, 0..) |top, ix| col = col.child(renderBlock(top.block, ix, o, window));
    return col;
}

/// Render one top-level block (a transcript row renders exactly one).
pub fn renderTopBlock(tree: BlockTree, block_ix: usize, opts: Options, window: *Window) AnyElement {
    if (block_ix >= tree.blocks.len) return zpui.empty();
    return renderBlock(tree.blocks[block_ix].block, block_ix, frameOpts(opts), window);
}

fn frameOpts(opts: Options) Options {
    var o = opts;
    // The theme pointer must outlive the frame: copy it into the arena.
    o.theme = zpui.window.arena_mod.current().create(Theme, opts.theme.*);
    return o;
}

fn mix(a: u64, b: u64) u64 {
    var h = std.hash.Wyhash.init(a);
    h.update(std.mem.asBytes(&b));
    return h.final();
}

fn quoteChildIx(ix: usize, child_ix: usize) usize {
    return ix * 100 + child_ix;
}

fn listChildIx(ix: usize, item_ix: usize, child_ix: usize) usize {
    return ix * 100 + item_ix * 10 + child_ix;
}

fn tableCellIx(ix: usize, r: usize, c: usize) usize {
    return ix * 100_000 + r * 100 + c;
}

/// Render one block (top-level or nested). `ix` is the per-element discriminator.
pub fn renderBlock(block: Block, ix: usize, opts: Options, window: *Window) AnyElement {
    const theme = opts.theme;
    switch (block) {
        .paragraph => |runs| return textElement(runs, text_size, line_height, false, ix, opts),
        .heading => |h| {
            const m = headingMetrics(h.level);
            return textElement(h.runs, m[0], m[1], true, ix, opts);
        },
        .code_block => |c| return codeBlock(c.language, c.code, ix, opts),
        .block_quote => |children| {
            // Accent-tinted quote: indigo rail + a whisper of the same hue.
            var q = div().borderL2().borderColor(theme.accent.opacity(0.6)).bg(theme.accent.opacity(0.05))
                .roundedTr(px(6)).roundedBr(px(6)).pl(px(12)).pr(px(10)).py(px(6))
                .flex().flexCol().gap(px(8)).textColor(theme.text_muted).minW0();
            for (children, 0..) |child, ci| q = q.child(renderBlock(child, quoteChildIx(ix, ci), opts, window));
            return zpui.intoAnyElement(q);
        },
        .list => |l| {
            var list = div().flex().flexCol().gap(px(4)).minW0();
            for (l.items, 0..) |item, item_ix| list = list.child(listItem(l.ordered_start, item, item_ix, ix, opts, window));
            return zpui.intoAnyElement(list);
        },
        .table => |t| return table(t.header, t.rows, t.alignment, ix, opts, window),
        .rule => return zpui.intoAnyElement(div().h(px(1)).wFull().bg(theme.border)),
    }
}

fn listItem(ordered_start: ?u64, item: []const Block, item_ix: usize, ix: usize, opts: Options, window: *Window) Div {
    const theme = opts.theme;
    const task: ?mdm.TaskMarker = blk: {
        if (opts.tasks != .checkbox or item.len == 0) break :blk null;
        switch (item[0]) {
            .paragraph => |runs| break :blk if (runs.len > 0) runs[0].style.task else null,
            else => break :blk null,
        }
    };
    const marker: AnyElement = if (task) |t| zpui.intoAnyElement(
        div().flexNone().minW(px(18)).h(px(line_height)).flex().itemsCenter().child(
            div().size(px(16)).border1().rounded(px(3)).flex().itemsCenter().justifyCenter()
                .borderColor(if (t.checked) theme.accent else theme.border)
                .bg(if (t.checked) theme.accent else zpui.color.transparent_black)
                .opacity(0.5)
                .child(if (t.checked) icon(.check, 12, theme.bg) else null),
        ),
    ) else if (ordered_start) |start| zpui.intoAnyElement(
        div().flexNone().minW(px(18)).textSize(px(text_size)).lineHeight(px(line_height))
            .textColor(theme.accent).child(zpui.fmt("{d}.", .{start + item_ix})),
    ) else zpui.intoAnyElement(
        // A real 5px disc centered on the first text line.
        div().flexNone().minW(px(18)).h(px(line_height)).flex().itemsCenter()
            .child(div().ml(px(1)).w(px(5)).h(px(5)).roundedFull().bg(theme.accent)),
    );
    var body = div().flex1().minW0().flex().flexCol().gap(px(4));
    for (item, 0..) |child, ci| {
        const cix = listChildIx(ix, item_ix, ci);
        if (ci == 0 and task != null) {
            const runs = child.paragraph;
            body = body.child(textElement(runs[1..], text_size, line_height, false, cix, opts));
        } else body = body.child(renderBlock(child, cix, opts, window));
    }
    return div().flex().flexRow().gap(px(8)).child(marker).child(body);
}

/// A monochrome icon tinted with the inherited text color.
pub fn iconInherit(which: assets.Icon, size: f32) zpui.elements.Svg {
    return zpui.svg().source(which.path(), which.svg()).size(px(size)).flexNone();
}

/// A monochrome control icon tinted with `color`.
pub fn icon(which: assets.Icon, size: f32, color: Hsla) zpui.elements.Svg {
    return zpui.svg().source(which.path(), which.svg()).size(px(size)).flexNone().textColor(color);
}

// ---------------------------------------------------------------------------
// Inline text
// ---------------------------------------------------------------------------

/// Flattened inline runs: one string + `TextRun`s + link and inline-code
/// ranges (frame-arena memory).
pub const FlatText = struct {
    text: []const u8,
    runs: []TextRun,
    links: []Range,
    urls: [][]const u8,
    code_ranges: []Range,
    /// Reserved NBSP slots after file links (painted with the open glyph).
    glyphs: []Range = &.{},
};

/// The reserved slot after a resolved file link: four NBSPs of advance.
pub const file_glyph_slot = "\u{00A0}\u{00A0}\u{00A0}\u{00A0}";

fn isFileUrl(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "file://");
}

/// The paragraph is nothing but one file link (whitespace aside).
pub fn soleFileLink(runs: []const InlineRun) ?[]const u8 {
    var target: ?[]const u8 = null;
    for (runs) |r| {
        if (std.mem.trim(u8, r.text, " \t\n").len == 0) continue;
        const url = r.style.link orelse return null;
        if (!isFileUrl(url)) return null;
        if (target) |t| {
            if (!std.mem.eql(u8, t, url)) return null;
        } else target = url;
    }
    return target;
}

/// Flatten inline runs into shaped-text inputs (`flatten_runs_weighted`).
pub fn flatten(runs: []const InlineRun, theme: *const Theme, base_weight: f32, plain_color: Hsla) FlatText {
    return flattenEx(runs, theme, base_weight, plain_color, false);
}

/// `flatten` plus file-link glyph slots when `glyphs` is set.
pub fn flattenEx(runs_in: []const InlineRun, theme: *const Theme, base_weight: f32, plain_color: Hsla, glyphs_on: bool) FlatText {
    const runs = runs_in;
    const glyph_links = glyphs_on and soleFileLink(runs) == null;
    var glyphs: std.ArrayList(Range) = .empty;
    const a = zpui.window.arena_mod.frameAllocator();
    var text: std.ArrayList(u8) = .empty;
    var out: std.ArrayList(TextRun) = .empty;
    var links: std.ArrayList(Range) = .empty;
    var urls: std.ArrayList([]const u8) = .empty;
    var codes: std.ArrayList(Range) = .empty;
    for (runs, 0..) |run, run_ix| {
        if (run.text.len == 0) continue;
        const shown = run.style.file_label orelse run.text;
        const start = text.items.len;
        text.appendSlice(a, shown) catch @panic("OOM");
        const end = text.items.len;
        var f: Font = .{ .family = if (run.style.code) theme.font_mono else theme.font_sans };
        f.weight = if (run.style.bold and base_weight < 600) 600 else base_weight;
        f.style = if (run.style.italic) .italic else .normal;
        if (run.style.code) {
            if (codes.items.len > 0 and codes.items[codes.items.len - 1].end == start)
                codes.items[codes.items.len - 1].end = end
            else
                codes.append(a, .{ .start = start, .end = end }) catch @panic("OOM");
        }
        if (run.style.link) |url| {
            if (!std.mem.eql(u8, url, mdm.PENDING_LINK_URL)) {
                if (links.items.len > 0 and links.items[links.items.len - 1].end == start and
                    std.mem.eql(u8, urls.items[urls.items.len - 1], url))
                {
                    links.items[links.items.len - 1].end = end;
                } else {
                    links.append(a, .{ .start = start, .end = end }) catch @panic("OOM");
                    urls.append(a, url) catch @panic("OOM");
                }
            }
        }
        out.append(a, .{
            .len = shown.len,
            .font = f,
            .color = if (run.style.code) theme.code_text else plain_color,
            .underline = if (run.style.link != null) .{ .color = theme.text_muted, .thickness = 1 } else null,
            .strikethrough = if (run.style.strikethrough) .{ .color = theme.text_muted, .thickness = 1 } else null,
        }) catch @panic("OOM");
        // A file link ends here (next run is not the same link): reserve the slot.
        if (glyph_links) if (run.style.link) |url| if (isFileUrl(url)) {
            var k = run_ix + 1;
            while (k < runs.len and runs[k].text.len == 0) k += 1;
            const next_same = k < runs.len and runs[k].style.link != null and std.mem.eql(u8, runs[k].style.link.?, url);
            if (!next_same) {
                const gs = text.items.len;
                text.appendSlice(a, file_glyph_slot) catch @panic("OOM");
                out.append(a, .{ .len = file_glyph_slot.len, .font = f, .color = plain_color }) catch @panic("OOM");
                glyphs.append(a, .{ .start = gs, .end = text.items.len }) catch @panic("OOM");
                // The glyph activates the link too.
                if (links.items.len > 0) links.items[links.items.len - 1].end = text.items.len;
            }
        };
    }
    return .{
        .glyphs = glyphs.items,
        .text = text.items,
        .runs = out.items,
        .links = links.items,
        .urls = urls.items,
        .code_ranges = codes.items,
    };
}

/// A `RichText` for a flattened block (no sizing wrapper).
pub fn flatElement(flat: FlatText, key: u64, opts: Options) AnyElement {
    if (flat.links.len > 0) registry.putLinks(key, flat.urls);
    return zpui.intoAnyElement(RichText{
        .id = .{ .hash = key },
        .key = key,
        .text = zpui.StyledText.init(flat.text).withRuns(flat.runs),
        .code_ranges = flat.code_ranges,
        .code_wash = opts.theme.code_wash,
        .code_radius = inline_code_radius,
        .code_pad_x = inline_code_pad_x,
        .code_inset_y = inline_code_inset_y,
        .links = flat.links,
        .glyphs = flat.glyphs,
        .glyph_color = opts.theme.text_faint,
        .selection_wash = opts.theme.selection,
        .selectable = opts.selectable,
    });
}

fn textElement(runs: []const InlineRun, size: f32, lh: f32, bold: bool, ix: usize, opts: Options) AnyElement {
    if (opts.images) {
        for (runs) |r| if (r.style.image != null) return imageText(runs, size, lh, bold, ix, opts);
    }
    const flat = flattenEx(runs, opts.theme, if (bold) 600 else 400, opts.theme.text, opts.file_links);
    const inner = flatElement(flat, mix(opts.key, ix), opts);
    if (opts.file_links) if (soleFileLink(runs)) |url| {
        const path = url["file://".len..];
        return zpui.intoAnyElement(div().textSize(px(size)).lineHeight(px(lh)).minW0().flex().itemsCenter().gap(px(4))
            .child(div().size(px(20)).flexNone().flex().itemsCenter().justifyCenter().rounded(px(4))
                .bg(file_icons.wellBg(opts.theme)).child(file_icons.icon(path, opts.theme, 14)))
            .child(div().minW0().flex1().child(inner)));
    };
    return zpui.intoAnyElement(div().textSize(px(size)).lineHeight(px(lh)).minW0().child(inner));
}

fn imageText(runs: []const InlineRun, size: f32, lh: f32, bold: bool, ix: usize, opts: Options) AnyElement {
    var col = div().flex().flexCol().gap(px(8)).minW0();
    var start: usize = 0;
    var no_images = opts;
    no_images.images = false;
    for (runs, 0..) |r, i| {
        const image = r.style.image orelse continue;
        if (start < i) col = col.child(textElement(runs[start..i], size, lh, bold, ix *% 4099 +% start + 1000, no_images));
        col = col.child(div().maxWFull().roundedLg().overflowHidden()
            .child(zpui.img(zpui.window.arena_mod.dupe(image.source)).maxWFull()));
        start = i + 1;
    }
    if (start < runs.len) col = col.child(textElement(runs[start..], size, lh, bold, ix *% 4099 +% start + 1000, no_images));
    return zpui.intoAnyElement(col);
}

// ---------------------------------------------------------------------------
// Code blocks
// ---------------------------------------------------------------------------

/// The exact-cover run list for one code line from its highlight spans.
pub fn runsForSyntaxLine(line: []const u8, spans: []const syntax.HighlightSpan, mono: Font, plain: Hsla, theme: *const Theme) []TextRun {
    const a = zpui.window.arena_mod.frameAllocator();
    var runs: std.ArrayList(TextRun) = .empty;
    var at: usize = 0;
    for (spans) |s| {
        if (s.start >= line.len) break;
        const end = @min(s.end, line.len);
        if (s.start > at) runs.append(a, .{ .len = s.start - at, .font = mono, .color = plain }) catch @panic("OOM");
        if (end > @max(s.start, at)) runs.append(a, .{
            .len = end - @max(s.start, at),
            .font = mono,
            .color = theme.syntax.color(s.kind.themeKey(zt.theme.HighlightKind)),
        }) catch @panic("OOM");
        at = @max(at, end);
    }
    if (at < line.len) runs.append(a, .{ .len = line.len - at, .font = mono, .color = plain }) catch @panic("OOM");
    return runs.items;
}

/// A vertical wheel over a horizontal scroller keeps bubbling to the
/// transcript; only a true horizontal gesture moves it.
pub fn restrictAxis(d: anytype) @TypeOf(d) {
    var x = d;
    x.style().restrict_scroll_to_axis = true;
    return x;
}

fn codeKey(opts: Options, ix: usize) u64 {
    return mix(opts.key ^ 0xC0DE, ix);
}

/// A fenced/indented code block (`render_code_block_source_with_actions`).
/// Mermaid fences render as their source (zeron's pending-diagram state).
pub fn codeBlock(language: ?[]const u8, code: []const u8, ix: usize, opts: Options) AnyElement {
    const theme = opts.theme;
    const key = codeKey(opts, ix);
    const fit = opts.fit_toggle and code_state.isFit(key);
    const mono: Font = .{ .family = theme.font_mono };
    const size = theme.code_font_size;
    const lh = size * code_line_height_ratio;
    const doc: ?*const syntax.HighlightedDocument = if (opts.highlight and language != null and language.?.len > 0)
        code_state.highlight(code, language.?)
    else
        null;

    // Strip one trailing newline (fences end with one).
    const body_code = if (std.mem.endsWith(u8, code, "\n")) code[0 .. code.len - 1] else code;
    var lines = div().px(px(code_padding_x)).py(px(code_padding_y))
        .fontFamily(theme.font_mono).textSize(px(size)).lineHeight(px(lh)).flex().flexCol();
    lines = if (fit) lines.wFull().minW0().whitespaceNormal() else lines.minWFull().flexNone().whitespaceNowrap();
    var it = std.mem.splitScalar(u8, body_code, '\n');
    var li: usize = 0;
    while (it.next()) |line| : (li += 1) {
        const spans: []const syntax.HighlightSpan = if (doc) |d| (if (li < d.lineCount()) d.line(li) else &.{}) else &.{};
        const runs = runsForSyntaxLine(line, spans, mono, theme.text, theme);
        var row = div();
        row = if (fit) row.wFull().minW0().minH(px(lh)) else row.h(px(lh)).flexNone();
        const line_text = if (line.len == 0) " " else line;
        const line_runs = if (line.len == 0) &[_]TextRun{.{ .len = 1, .font = mono, .color = theme.text }} else runs;
        row = row.child(zpui.intoAnyElement(RichText{
            .id = .{ .hash = mix(key, li) },
            .key = mix(key, li),
            .text = zpui.StyledText.init(line_text).withRuns(line_runs),
            .selection_wash = theme.selection,
            .selectable = opts.selectable,
        }));
        lines = lines.child(row);
    }

    const body: AnyElement = if (fit)
        zpui.intoAnyElement(div().wFull().minW0().overflowHidden().child(lines))
    else
        zpui.intoAnyElement(restrictAxis(div().id(.{ "code-scroll", key }).wFull().minW0().flex().overflowXScroll()
            .child(lines)));

    // Header actions: fit toggle, then copy.
    var actions = div().flexNone().flex().flexRow().itemsCenter().gap(px(2));
    if (opts.fit_toggle) {
        const base = if (fit) theme.ink(0.09) else zpui.color.transparent_black;
        actions = actions.child(div().id(.{ "code-fit", key }).size(px(code_action_size)).rounded(px(6))
            .flex().itemsCenter().justifyCenter().cursorPointer().bg(base)
            .hover(sb.bg(theme.ink(if (fit) 0.13 else 0.08)))
            .onClick(fitListener(key))
            .child(icon(.wrap_text, 13, theme.text_muted)));
    }
    if (opts.copy) {
        code_state.putCode(key, body_code);
        const app_now = currentNow();
        const copied = code_state.isCopied(key, app_now);
        actions = actions.child(div().id(.{ "code-copy", key }).h(px(code_action_size)).px(px(6)).rounded(px(5))
            .flex().flexRow().itemsCenter().gap(px(4)).cursorPointer()
            .hover(sb.bg(theme.ink(0.08)))
            .textSize(px(10.5)).textColor(theme.text_muted)
            .onClick(copyListener(key))
            .child(icon(if (copied) .check else .copy, 12, theme.text_muted))
            .child(if (copied) @as(?[]const u8, "Copied") else null));
    }
    const has_header = language != null or opts.copy or opts.fit_toggle;
    const header: ?Div = if (has_header) div().h(px(code_header_height)).flexNone().pl(px(code_padding_x)).pr(px(5))
        .borderB1().borderColor(theme.border).bg(theme.ink(0.02))
        .flex().flexRow().itemsCenter().justifyBetween()
        .child(div().minW0().textSize(px(11)).textColor(theme.text_muted)
            .child(if (language) |l| @as(?[]const u8, l) else null))
        .child(actions) else null;

    return zpui.intoAnyElement(div().wFull().minW0().flex().flexCol().rounded(px(10)).bg(theme.ink(0.035))
        .border1().borderColor(theme.border).overflowHidden().relative()
        .child(header)
        .child(div().wFull().relative().child(body)));
}

/// The current executor clock, when a window is drawing (for transient feedback).
threadlocal var now_source: ?*App = null;

/// Set by the owning view each frame so copy feedback can expire.
pub fn setClock(app: *App) void {
    now_source = app;
    code_state.trim();
}

fn currentNow() u64 {
    const app = now_source orelse return 0;
    return app.executor.now();
}

// ---------------------------------------------------------------------------
// Tables
// ---------------------------------------------------------------------------

/// A GFM table — mugen's frameless "flat hairline" table under zeron's md
/// theme: content-proportional flex columns with a 96px floor, hairlines
/// between rows, horizontal scroll once the floors exceed the viewport.
fn table(
    header: []const []const InlineRun,
    rows: []const []const []const InlineRun,
    alignment: []const mdm.TableAlign,
    ix: usize,
    opts: Options,
    window: *Window,
) AnyElement {
    const a = zpui.window.arena_mod.frameAllocator();
    const theme = opts.theme;
    var all: std.ArrayList([]const []const InlineRun) = .empty;
    if (header.len > 0) all.append(a, header) catch @panic("OOM");
    for (rows) |r| all.append(a, r) catch @panic("OOM");
    var cols: usize = 0;
    for (all.items) |r| cols = @max(cols, r.len);
    if (cols == 0) return zpui.empty();
    const has_header = header.len > 0;

    const flats = a.alloc([]?FlatText, all.items.len) catch @panic("OOM");
    const content = a.alloc(f32, cols) catch @panic("OOM");
    @memset(content, 0);
    for (all.items, 0..) |row, r| {
        const weight: f32 = if (has_header and r == 0) 700 else 400;
        flats[r] = a.alloc(?FlatText, cols) catch @panic("OOM");
        for (0..cols) |c| {
            if (c >= row.len) {
                flats[r][c] = null;
                continue;
            }
            const flat = flattenEx(row[c], theme, weight, theme.text, opts.file_links);
            if (flat.text.len > 0 and flat.runs.len > 0) {
                const line = std.mem.replaceOwned(u8, a, flat.text, "\n", " ") catch @panic("OOM");
                if (window.text_system.layoutLine(line, text_size, flat.runs, null)) |shared| {
                    content[c] = @max(content[c], shared.layout.width);
                    shared.release();
                } else |_| {}
            }
            flats[r][c] = flat;
        }
    }
    var naturals = a.alloc(f32, cols) catch @panic("OOM");
    var mins = a.alloc(f32, cols) catch @panic("OOM");
    var min_table: f32 = 0;
    for (0..cols) |c| {
        naturals[c] = @max(content[c], table_min_column_content) + 2 * table_cell_padding;
        mins[c] = @min(naturals[c], table_min_column_width);
        min_table += mins[c];
    }

    const hairline = theme.hairline(0.10);
    var inner = div().flex().flexCol().wFull().minW(px(min_table));
    for (flats, 0..) |row, r| {
        if (r > 0) inner = inner.child(div().flexNone().h(px(table_divider)).wFull().bg(hairline));
        var row_el = div().flex().flexRow();
        for (row, 0..) |cell_flat, c| {
            var cell = div().flexGrow(naturals[c]).flexShrink(naturals[c]).flexBasis(px(0)).minW(px(mins[c]))
                .p(px(table_cell_padding)).textSize(px(text_size)).lineHeight(px(line_height));
            const al = if (c < alignment.len) alignment[c] else .left;
            cell = switch (al) {
                .left => cell,
                .center => cell.textCenter(),
                .right => cell.textRight(),
            };
            if (cell_flat) |f| cell = cell.child(flatElement(f, mix(opts.key, tableCellIx(ix, r, c)), opts));
            row_el = row_el.child(cell);
        }
        inner = inner.child(row_el);
    }
    return zpui.intoAnyElement(restrictAxis(div().id(.{ "md-table", mix(opts.key, ix) }).wFull().overflowXScroll()
        .child(inner)));
}

test {
    std.testing.refAllDecls(@This());
}
