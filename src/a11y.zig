//! Accessibility tree (zui `window/a11y.rs` + the AccessKit node model it feeds).
//!
//! Every frame in which accessibility is active, the window builds a `Tree` while it
//! prepaints: each element that has an id and a role (`div().id(..).role(.button)`)
//! pushes a node, its descendants become child nodes, and text elements contribute their
//! string to the nearest node so a button reads "Save" without an explicit label. Nodes
//! are stored in pre-order, so a cached view's subtree is one contiguous range that the
//! next frame copies (`reuseRange`) when the view is reused — the tree stays complete
//! without re-rendering cached views (zui drops their nodes instead).
//!
//! At the end of the frame the tree is finalized (children lists, the focused node with
//! the `aria-activedescendant` override) and diffed against the previous frame (`diff`).
//! The platform bridge (`platform.Window.VTable.a11yUpdate`) gets the new tree plus the
//! change set so it only posts notifications for what changed:
//!
//!     macOS  src/platform/mac/a11y.zig    NSAccessibilityElement hierarchy under the content view
//!     Linux  src/platform/linux/atspi.zig AT-SPI2 objects on the accessibility bus
//!
//! Requests from assistive technology come back as `ActionRequest`s through
//! `WindowCallbacks.a11y_action`; the window runs `onA11yAction` listeners or the
//! built-in behaviour (click = synthesized mouse click at the node's center, focus =
//! focus the node's focus handle, blur).
//!
//! Node ids derive from the element's `GlobalElementId`, so they are stable across frames
//! as long as the element's id path is. Strings are copied into the tree, so a finalized
//! tree stays valid after the frame arena is cleared, until the next frame replaces it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const geometry = @import("geometry.zig");

pub const Bounds = geometry.Bounds(f32);
pub const Point = geometry.Point(f32);

/// Stable node identity (AccessKit `NodeId`). `root` is the window.
pub const NodeId = enum(u64) {
    root = 0,
    _,

    /// The node id of an element with global id `gid` (never `root`).
    pub fn fromGlobal(gid: u64) NodeId {
        return @enumFromInt(if (gid == 0) 1 else gid);
    }

    /// A child id derived from `parent` and `key` (zui `synthetic_node_id`).
    pub fn synthetic(parent: NodeId, key: u64) NodeId {
        var h = std.hash.Wyhash.init(@intFromEnum(parent));
        h.update(std.mem.asBytes(&key));
        return fromGlobal(h.final());
    }
};

/// Node roles: the AccessKit roles zeron and gpui-component use (names follow
/// `accesskit::Role` in snake case). Platform bridges map them to NSAccessibility roles
/// and AT-SPI roles.
pub const Role = enum(u8) {
    unknown,
    window,
    group,
    generic_container,
    /// Static text (AccessKit `Label`).
    label,
    paragraph,
    heading,
    button,
    default_button,
    link,
    check_box,
    radio_button,
    @"switch",
    toggle_button,
    text_input,
    multiline_text_input,
    search_input,
    password_input,
    combo_box,
    spin_button,
    slider,
    progress_indicator,
    image,
    list,
    list_item,
    list_box,
    list_box_option,
    menu,
    menu_bar,
    menu_item,
    menu_item_check_box,
    menu_item_radio,
    tab_list,
    tab,
    tab_panel,
    tree,
    tree_item,
    table,
    grid,
    row,
    cell,
    column_header,
    row_header,
    dialog,
    alert_dialog,
    alert,
    status,
    tooltip,
    toolbar,
    scroll_view,
    separator,
    navigation,
    region,
    document,
    article,
    code,
    disclosure_triangle,
    pane,
    terminal,

    /// Roles whose accessible name comes from their text content when no label is set
    /// (ARIA "name from content").
    pub fn nameFromContents(r: Role) bool {
        return switch (r) {
            .button, .default_button, .link, .check_box, .radio_button, .@"switch", .toggle_button, .heading, .label, .paragraph, .list_item, .list_box_option, .menu_item, .menu_item_check_box, .menu_item_radio, .tab, .tree_item, .cell, .column_header, .row_header, .tooltip, .status, .alert, .disclosure_triangle => true,
            else => false,
        };
    }

    pub fn isTextInput(r: Role) bool {
        return switch (r) {
            .text_input, .multiline_text_input, .search_input, .password_input, .combo_box, .spin_button => true,
            else => false,
        };
    }

    /// Roles a `toggled` state applies to (check boxes, switches, toggle buttons).
    pub fn isToggle(r: Role) bool {
        return switch (r) {
            .check_box, .@"switch", .toggle_button, .menu_item_check_box, .menu_item_radio, .radio_button => true,
            else => false,
        };
    }

    pub fn isRange(r: Role) bool {
        return switch (r) {
            .slider, .progress_indicator, .spin_button => true,
            else => false,
        };
    }
};

/// AccessKit `Toggled`.
pub const Toggled = enum(u2) { off, on, mixed };

pub const Orientation = enum(u1) { horizontal, vertical };

/// A text field's selection (AccessKit `TextSelection`), as UTF-8 byte offsets into the
/// node's value. `anchor == focus` is a caret; `focus` is the moving end (the caret).
pub const TextSelection = struct {
    anchor: u32,
    focus: u32,

    pub fn start(s: TextSelection) u32 {
        return @min(s.anchor, s.focus);
    }

    pub fn end(s: TextSelection) u32 {
        return @max(s.anchor, s.focus);
    }

    pub fn isCaret(s: TextSelection) bool {
        return s.anchor == s.focus;
    }
};

/// Offset conversions for text values (bridges speak characters (AT-SPI) or UTF-16 code
/// units (NSAccessibility); the tree stores UTF-8 byte offsets).
pub const text_offsets = struct {
    /// Number of code points in `s` (bytes when it is not valid UTF-8).
    pub fn charCount(s: []const u8) usize {
        return std.unicode.utf8CountCodepoints(s) catch s.len;
    }

    /// Code-point index of byte offset `byte` (clamped, snapped back to a boundary).
    pub fn byteToChar(s: []const u8, byte: usize) usize {
        const b = snap(s, byte);
        return charCount(s[0..b]);
    }

    /// Byte offset of code point `ch` (clamped to the end).
    pub fn charToByte(s: []const u8, ch: usize) usize {
        var i: usize = 0;
        var k: usize = 0;
        while (i < s.len and k < ch) : (k += 1) i += seqLen(s, i);
        return @min(i, s.len);
    }

    /// Length of `s` in UTF-16 code units.
    pub fn utf16Len(s: []const u8) usize {
        return byteToUtf16(s, s.len);
    }

    /// UTF-16 offset of byte offset `byte`.
    pub fn byteToUtf16(s: []const u8, byte: usize) usize {
        const b = snap(s, byte);
        var i: usize = 0;
        var n: usize = 0;
        while (i < b) {
            const l = seqLen(s, i);
            n += if (l == 4) 2 else 1;
            i += l;
        }
        return n;
    }

    /// Byte offset of UTF-16 offset `u` (clamped; a split surrogate pair rounds down).
    pub fn utf16ToByte(s: []const u8, u: usize) usize {
        var i: usize = 0;
        var n: usize = 0;
        while (i < s.len) {
            const l = seqLen(s, i);
            const w: usize = if (l == 4) 2 else 1;
            if (n + w > u) break;
            n += w;
            i += l;
        }
        return @min(i, s.len);
    }

    /// Zero-based line (split on `\n`) holding byte offset `byte`.
    pub fn lineOf(s: []const u8, byte: usize) usize {
        const b = @min(byte, s.len);
        return std.mem.count(u8, s[0..b], "\n");
    }

    /// Byte range `[start, end)` of line `line`, including its trailing newline; null
    /// past the last line.
    pub fn lineRange(s: []const u8, line: usize) ?[2]usize {
        var start: usize = 0;
        var k: usize = 0;
        while (k < line) : (k += 1) {
            const nl = std.mem.indexOfScalarPos(u8, s, start, '\n') orelse return null;
            start = nl + 1;
        }
        const end = if (std.mem.indexOfScalarPos(u8, s, start, '\n')) |nl| nl + 1 else s.len;
        return .{ start, end };
    }

    fn seqLen(s: []const u8, i: usize) usize {
        const l = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        return @min(l, s.len - i);
    }

    fn snap(s: []const u8, byte: usize) usize {
        var b = @min(byte, s.len);
        while (b > 0 and b < s.len and (s[b] & 0xC0) == 0x80) b -= 1;
        return b;
    }
};

/// Requests assistive technology can make (AccessKit `Action`, the subset zpui handles).
pub const Action = enum(u4) {
    /// Press / activate (AXPress, AT-SPI "click").
    click,
    focus,
    blur,
    /// Replace the value (text field contents; `ActionRequest.value` / `.numeric`).
    set_value,
    increment,
    decrement,
    expand,
    collapse,
    scroll_into_view,
    show_context_menu,
    /// Move the caret / selection of a text field (`ActionRequest.selection`).
    set_text_selection,
};

pub const ActionSet = std.EnumSet(Action);

/// A request from assistive technology, delivered to the window.
pub const ActionRequest = struct {
    target: NodeId,
    action: Action,
    /// `set_value` with a string (text fields).
    value: ?[]const u8 = null,
    /// `set_value` with a number (sliders).
    numeric: ?f64 = null,
    /// `set_text_selection`: the new selection (UTF-8 byte offsets into the value).
    selection: ?TextSelection = null,
};

/// What an element declares about itself (gpui `aria_*` builder calls). Strings are
/// borrowed; the tree copies them.
pub const Info = struct {
    label: ?[]const u8 = null,
    description: ?[]const u8 = null,
    value: ?[]const u8 = null,
    placeholder: ?[]const u8 = null,
    keyshortcuts: ?[]const u8 = null,
    /// A link's target (AT-SPI Hyperlink `GetURI`, AXURL).
    url: ?[]const u8 = null,
    /// A text field's caret / selection in its value.
    text_selection: ?TextSelection = null,
    selected: ?bool = null,
    expanded: ?bool = null,
    toggled: ?Toggled = null,
    disabled: bool = false,
    read_only: bool = false,
    numeric_value: ?f64 = null,
    min_numeric_value: ?f64 = null,
    max_numeric_value: ?f64 = null,
    numeric_value_step: ?f64 = null,
    orientation: ?Orientation = null,
    level: ?u32 = null,
    position_in_set: ?u32 = null,
    size_of_set: ?u32 = null,
    row_index: ?u32 = null,
    column_index: ?u32 = null,
    row_count: ?u32 = null,
    column_count: ?u32 = null,
    /// Actions beyond the implied ones (`click` from click listeners, `focus` from focus
    /// handles, `onA11yAction` registrations).
    actions: ActionSet = .empty,
    /// Report this node as focused while one of its ancestors holds focus (zui
    /// `aria_active_descendant`).
    active_descendant: bool = false,
};

/// One node pushed by an element.
pub const NodeSpec = struct {
    id: NodeId,
    role: Role,
    bounds: Bounds,
    info: Info = .{},
    /// The focus handle that focuses this element (`FocusId` as an integer).
    focus_id: ?u64 = null,
};

/// A string stored in the tree's buffer.
pub const Str = struct {
    off: u32 = 0,
    len: u32 = 0,
    present: bool = false,
};

const no_parent = std.math.maxInt(u32);

/// A node in a `Tree`. Strings are `Str` handles: read them with `Tree.str`.
pub const Node = struct {
    id: NodeId,
    role: Role,
    /// Index of the parent node (`no_parent` for the root).
    parent: u32 = no_parent,
    /// Window coordinates, logical pixels, top-left origin.
    bounds: Bounds = .{ .origin = .zero, .size = .zero },
    focus_id: ?u64 = null,
    label: Str = .{},
    description: Str = .{},
    value: Str = .{},
    placeholder: Str = .{},
    keyshortcuts: Str = .{},
    url: Str = .{},
    text_selection: ?TextSelection = null,
    /// Text gathered from descendant text elements (name from content).
    content: Str = .{},
    selected: ?bool = null,
    expanded: ?bool = null,
    toggled: ?Toggled = null,
    disabled: bool = false,
    read_only: bool = false,
    numeric_value: ?f64 = null,
    min_numeric_value: ?f64 = null,
    max_numeric_value: ?f64 = null,
    numeric_value_step: ?f64 = null,
    orientation: ?Orientation = null,
    level: ?u32 = null,
    position_in_set: ?u32 = null,
    size_of_set: ?u32 = null,
    row_index: ?u32 = null,
    column_index: ?u32 = null,
    row_count: ?u32 = null,
    column_count: ?u32 = null,
    actions: ActionSet = .empty,
    active_descendant: bool = false,
    /// Static text generated from a text element (not pushed by an element).
    synthetic: bool = false,
    /// Document-order key among siblings.
    order: u32 = 0,
    // Filled by `finalize`.
    first_child: u32 = 0,
    child_count: u32 = 0,
    index_in_parent: u32 = 0,

    pub fn isFocusable(n: *const Node) bool {
        return n.focus_id != null or n.actions.contains(.focus);
    }
};

/// Text contributed by a text element to the node on top of the stack.
const Piece = struct {
    node: u32,
    str: Str,
    bounds: Bounds,
    /// Number of nodes when the text was added (document order among siblings).
    at: u32,

    fn len(p: Piece) usize {
        return p.str.len;
    }
};

/// The accessibility tree of one frame (gpui `A11yNodeBuilder` + the finalized
/// `TreeUpdate`). Owned by the window's `Frame`.
pub const Tree = struct {
    gpa: Allocator,
    nodes: std.ArrayList(Node) = .empty,
    strings: std.ArrayList(u8) = .empty,
    /// Children indices, grouped per parent (`Node.first_child`/`child_count`).
    child_list: std.ArrayList(u32) = .empty,
    index: std.AutoHashMapUnmanaged(NodeId, u32) = .empty,
    stack: std.ArrayList(u32) = .empty,
    /// Text pieces in prepaint order (kept after `finalize` so cached views can copy them).
    pieces: std.ArrayList(Piece) = .empty,
    /// Number of nodes pushed during the frame; synthetic text nodes follow them.
    element_nodes: u32 = 0,
    /// The node holding keyboard focus (index), before the active-descendant override.
    focus_node: ?u32 = null,
    /// What assistive technology is told is focused (index; 0 = the window).
    reported_focus: u32 = 0,
    /// Built this frame (accessibility was active while drawing).
    built: bool = false,
    finalized: bool = false,
    /// Duplicate ids seen this frame (dropped, as in zui release builds).
    duplicates: u32 = 0,
    /// Interactive elements (click listeners or a tab-stop focus handle) that pushed no
    /// node because they have no role: an audit for apps (`unroled`).
    unroled: std.ArrayList(Unroled) = .empty,

    /// An interactive element without a role (see `noteUnroled`).
    pub const Unroled = struct {
        gid: u64,
        /// The enclosing node (index) when the element was prepainted.
        parent: u32,
        bounds: Bounds,
        /// The element's own id, formatted (`name`, `name#3`, `#7`).
        element: Str,
        clickable: bool,
        focusable: bool,
    };

    pub fn init(gpa: Allocator) Tree {
        return .{ .gpa = gpa };
    }

    pub fn deinit(t: *Tree) void {
        t.nodes.deinit(t.gpa);
        t.strings.deinit(t.gpa);
        t.child_list.deinit(t.gpa);
        t.index.deinit(t.gpa);
        t.stack.deinit(t.gpa);
        t.pieces.deinit(t.gpa);
        t.unroled.deinit(t.gpa);
    }

    pub fn clear(t: *Tree) void {
        t.nodes.clearRetainingCapacity();
        t.strings.clearRetainingCapacity();
        t.child_list.clearRetainingCapacity();
        t.index.clearRetainingCapacity();
        t.stack.clearRetainingCapacity();
        t.pieces.clearRetainingCapacity();
        t.unroled.clearRetainingCapacity();
        t.element_nodes = 0;
        t.focus_node = null;
        t.reported_focus = 0;
        t.built = false;
        t.finalized = false;
        t.duplicates = 0;
    }

    // ---- building ------------------------------------------------------------------------

    /// Start a frame: clear and push the window node (`Role.window`, labelled `title`).
    pub fn begin(t: *Tree, title: ?[]const u8, viewport: Bounds) void {
        t.clear();
        t.built = true;
        var root_node: Node = .{ .id = .root, .role = .window, .bounds = viewport, .order = 1 };
        if (title) |s| root_node.label = t.intern(s);
        t.nodes.append(t.gpa, root_node) catch @panic("OOM");
        t.index.put(t.gpa, .root, 0) catch @panic("OOM");
        t.stack.append(t.gpa, 0) catch @panic("OOM");
    }

    pub fn isBuilding(t: *const Tree) bool {
        return t.built and !t.finalized;
    }

    /// Number of nodes so far (a prepaint index).
    pub fn len(t: *const Tree) usize {
        return t.nodes.items.len;
    }

    pub fn piecesLen(t: *const Tree) usize {
        return t.pieces.items.len;
    }

    fn intern(t: *Tree, s: []const u8) Str {
        const off: u32 = @intCast(t.strings.items.len);
        t.strings.appendSlice(t.gpa, s) catch @panic("OOM");
        return .{ .off = off, .len = @intCast(s.len), .present = true };
    }

    fn internOpt(t: *Tree, s: ?[]const u8) Str {
        return if (s) |v| t.intern(v) else .{};
    }

    /// Push a node as a child of the current node and make it current. Returns false
    /// (and pushes nothing) when the id is already in the tree.
    pub fn push(t: *Tree, spec_: NodeSpec) bool {
        std.debug.assert(t.isBuilding());
        const parent = t.stack.getLast();
        const ix: u32 = @intCast(t.nodes.items.len);
        const gop = t.index.getOrPut(t.gpa, spec_.id) catch @panic("OOM");
        if (gop.found_existing) {
            t.duplicates += 1;
            return false;
        }
        gop.value_ptr.* = ix;
        const i = spec_.info;
        t.nodes.append(t.gpa, .{
            .id = spec_.id,
            .role = spec_.role,
            .parent = parent,
            .bounds = spec_.bounds,
            .focus_id = spec_.focus_id,
            .label = t.internOpt(i.label),
            .description = t.internOpt(i.description),
            .value = t.internOpt(i.value),
            .placeholder = t.internOpt(i.placeholder),
            .keyshortcuts = t.internOpt(i.keyshortcuts),
            .url = t.internOpt(i.url),
            .text_selection = i.text_selection,
            .selected = i.selected,
            .expanded = i.expanded,
            .toggled = i.toggled,
            .disabled = i.disabled,
            .read_only = i.read_only,
            .numeric_value = i.numeric_value,
            .min_numeric_value = i.min_numeric_value,
            .max_numeric_value = i.max_numeric_value,
            .numeric_value_step = i.numeric_value_step,
            .orientation = i.orientation,
            .level = i.level,
            .position_in_set = i.position_in_set,
            .size_of_set = i.size_of_set,
            .row_index = i.row_index,
            .column_index = i.column_index,
            .row_count = i.row_count,
            .column_count = i.column_count,
            .actions = blk: {
                var a = i.actions;
                if (spec_.focus_id != null) a.insert(.focus);
                break :blk a;
            },
            .active_descendant = i.active_descendant,
            .order = ix * 2 + 1,
        }) catch @panic("OOM");
        t.stack.append(t.gpa, ix) catch @panic("OOM");
        return true;
    }

    /// Pop the current node (must pair with a successful `push`).
    pub fn pop(t: *Tree) void {
        std.debug.assert(t.stack.items.len > 1);
        _ = t.stack.pop();
    }

    /// Stack depth (1 = only the window node).
    pub fn depth(t: *const Tree) usize {
        return t.stack.items.len;
    }

    /// Index of the current (top-of-stack) node.
    pub fn current(t: *const Tree) u32 {
        return t.stack.getLast();
    }

    /// Add the text of a text element (at `bounds`) to the current node: it names a
    /// button-like node ("name from content"), becomes the value of a text field, or a
    /// static-text child of any other node. Ignored for nodes with an explicit label.
    pub fn appendText(t: *Tree, text: []const u8, bounds: Bounds) void {
        if (!t.isBuilding()) return;
        const cur = t.current();
        const n = &t.nodes.items[cur];
        if (n.label.present and n.role.nameFromContents()) return;
        if (n.value.present and n.role.isTextInput()) return;
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) return;
        const s = t.intern(trimmed);
        t.pieces.append(t.gpa, .{ .node = cur, .str = s, .bounds = bounds, .at = @intCast(t.nodes.items.len) }) catch @panic("OOM");
    }

    /// Record an interactive element that has no role (and so no node). Deduplicated by
    /// global id (speculative prepaints may visit an element twice).
    pub fn noteUnroled(t: *Tree, gid: u64, bounds: Bounds, element: []const u8, clickable: bool, focusable: bool) void {
        if (!t.isBuilding()) return;
        for (t.unroled.items) |u| if (u.gid == gid) return;
        t.unroled.append(t.gpa, .{ .gid = gid, .parent = t.current(), .bounds = bounds, .element = t.intern(element), .clickable = clickable, .focusable = focusable }) catch @panic("OOM");
    }

    /// Mutable access to the current node (zui `A11ySubtreeBuilder::parent_node`).
    pub fn currentNode(t: *Tree) *Node {
        return &t.nodes.items[t.current()];
    }

    /// Roll back to `n` nodes / `p` text pieces (speculative prepaint, `truncatePrepaint`).
    pub fn truncate(t: *Tree, n: usize, p: usize) void {
        if (n >= t.nodes.items.len and p >= t.pieces.items.len) return;
        for (t.nodes.items[@min(n, t.nodes.items.len)..]) |node| _ = t.index.remove(node.id);
        if (n < t.nodes.items.len) t.nodes.shrinkRetainingCapacity(n);
        if (p < t.pieces.items.len) t.pieces.shrinkRetainingCapacity(p);
        var k: usize = 0;
        while (k < t.unroled.items.len) {
            if (t.unroled.items[k].parent >= n) _ = t.unroled.orderedRemove(k) else k += 1;
        }
        // Defensive: drop stack entries past the end (balanced callers never have any).
        while (t.stack.items.len > 1 and t.stack.getLast() >= n) _ = t.stack.pop();
    }

    /// Copy nodes `[start, end)` and text pieces `[pstart, pend)` of `src` (a cached
    /// view's prepaint output from the previous frame) under the current node. Nodes whose
    /// ids already exist are dropped together with their subtrees.
    pub fn reuseRange(t: *Tree, src: *const Tree, start: usize, end: usize, pstart: usize, pend: usize) void {
        if (!t.isBuilding() or !src.built) return;
        const base: u32 = @intCast(t.nodes.items.len);
        const parent = t.current();
        const e = @min(end, src.element_nodes);
        const map = t.gpa.alloc(u32, if (e > start) e - start else 0) catch @panic("OOM");
        defer t.gpa.free(map);
        var next = base;
        if (e > start) for (src.nodes.items[start..e], 0..) |sn, k| {
            const new_parent: u32 = if (sn.parent < start or sn.parent >= e) parent else blk: {
                const m = map[sn.parent - start];
                if (m == no_parent) {
                    map[k] = no_parent;
                    continue;
                }
                break :blk m;
            };
            const gop = t.index.getOrPut(t.gpa, sn.id) catch @panic("OOM");
            if (gop.found_existing) {
                t.duplicates += 1;
                map[k] = no_parent;
                continue;
            }
            gop.value_ptr.* = next;
            var n = sn;
            n.parent = new_parent;
            n.label = t.copyStr(src, sn.label);
            n.description = t.copyStr(src, sn.description);
            n.value = t.copyStr(src, sn.value);
            n.placeholder = t.copyStr(src, sn.placeholder);
            n.keyshortcuts = t.copyStr(src, sn.keyshortcuts);
            n.url = t.copyStr(src, sn.url);
            n.content = .{};
            n.first_child = 0;
            n.child_count = 0;
            n.order = next * 2 + 1;
            t.nodes.append(t.gpa, n) catch @panic("OOM");
            map[k] = next;
            next += 1;
        };
        if (pend > pstart and pend <= src.pieces.items.len) for (src.pieces.items[pstart..pend]) |p| {
            const node: u32 = if (p.node >= start and p.node < e) map[p.node - start] else parent;
            if (node == no_parent) continue;
            const at_: u32 = if (p.at >= start and p.at < e) base + (p.at - @as(u32, @intCast(start))) else next;
            t.pieces.append(t.gpa, .{ .node = node, .str = t.copyStr(src, p.str), .bounds = p.bounds, .at = @min(at_, next) }) catch @panic("OOM");
        };
    }

    fn copyStr(t: *Tree, src: *const Tree, s: Str) Str {
        if (!s.present) return .{};
        return t.intern(src.str(s).?);
    }

    /// Close the frame: gathered text (names, text-field values, static-text children),
    /// children lists, and the reported focus (`focused` = the window's focused
    /// `FocusId` as an integer).
    pub fn finalize(t: *Tree, focused: ?u64) void {
        if (!t.built or t.finalized) return;
        if (t.stack.items.len != 1) std.log.scoped(.a11y).warn("a11y: stack imbalance at end of frame ({d})", .{t.stack.items.len});
        t.stack.shrinkRetainingCapacity(@min(t.stack.items.len, 1));
        t.element_nodes = @intCast(t.nodes.items.len);
        t.applyPieces();
        const nodes = t.nodes.items;

        // Children: count, prefix-sum, fill, then order siblings by document position.
        for (nodes) |*n| n.child_count = 0;
        for (nodes[1..]) |n| nodes[n.parent].child_count += 1;
        var acc: u32 = 0;
        for (nodes) |*n| {
            n.first_child = acc;
            acc += n.child_count;
            n.child_count = 0;
        }
        t.child_list.resize(t.gpa, acc) catch @panic("OOM");
        for (nodes[1..], 1..) |*n, ix| {
            const p = &nodes[n.parent];
            t.child_list.items[p.first_child + p.child_count] = @intCast(ix);
            p.child_count += 1;
        }
        if (nodes.len > t.element_nodes) for (nodes) |n| {
            const kids = t.child_list.items[n.first_child..][0..n.child_count];
            std.mem.sort(u32, kids, nodes, struct {
                fn lt(ns: []const Node, a: u32, b: u32) bool {
                    return ns[a].order < ns[b].order;
                }
            }.lt);
        };
        for (nodes) |n| for (t.child_list.items[n.first_child..][0..n.child_count], 0..) |c, k| {
            nodes[c].index_in_parent = @intCast(k);
        };

        // Focus: the (first) node bound to the focused handle; then the active descendant
        // claimed below it, if any (zui `set_active_descendant` gating).
        t.focus_node = null;
        if (focused) |f| for (nodes, 0..) |n, ix| {
            if (n.focus_id == f) {
                t.focus_node = @intCast(ix);
                break;
            }
        };
        t.reported_focus = t.focus_node orelse 0;
        if (t.focus_node) |fnode| for (nodes, 0..) |n, ix| {
            if (!n.active_descendant or ix == fnode) continue;
            if (t.isAncestor(fnode, @intCast(ix))) {
                t.reported_focus = @intCast(ix);
                break;
            }
        };
        t.finalized = true;
    }

    fn applyPieces(t: *Tree) void {
        const np = t.pieces.items.len;
        if (np == 0) return;
        const order = t.gpa.alloc(u32, np) catch @panic("OOM");
        defer t.gpa.free(order);
        for (order, 0..) |*o, i| o.* = @intCast(i);
        std.mem.sort(u32, order, t.pieces.items, struct {
            fn lt(ps: []const Piece, a: u32, b: u32) bool {
                return if (ps[a].node != ps[b].node) ps[a].node < ps[b].node else a < b;
            }
        }.lt);
        var total: usize = 0;
        for (t.pieces.items) |p| total += p.len() + 1;
        t.strings.ensureUnusedCapacity(t.gpa, total) catch @panic("OOM");
        var i: usize = 0;
        while (i < np) {
            const node_ix = t.pieces.items[order[i]].node;
            var j = i;
            while (j < np and t.pieces.items[order[j]].node == node_ix) j += 1;
            const role = t.nodes.items[node_ix].role;
            if (role.nameFromContents() or role.isTextInput()) {
                // Joined text: the name (buttons, tabs, ...) or the value (text fields).
                const off: u32 = @intCast(t.strings.items.len);
                for (order[i..j], 0..) |pi, k| {
                    const p = t.pieces.items[pi].str;
                    if (k > 0) t.strings.appendAssumeCapacity(' ');
                    t.strings.appendSliceAssumeCapacity(t.strings.items[p.off..][0..p.len]);
                }
                const joined: Str = .{ .off = off, .len = @intCast(t.strings.items.len - off), .present = true };
                const n = &t.nodes.items[node_ix];
                if (role.isTextInput()) {
                    if (!n.value.present) n.value = joined;
                } else n.content = joined;
            } else {
                // Static text children (zui exposes text with an id as `Label` nodes).
                const parent_id = t.nodes.items[node_ix].id;
                for (order[i..j], 0..) |pi, k| {
                    const p = t.pieces.items[pi];
                    const id = NodeId.synthetic(parent_id, k);
                    const gop = t.index.getOrPut(t.gpa, id) catch @panic("OOM");
                    if (gop.found_existing) continue;
                    gop.value_ptr.* = @intCast(t.nodes.items.len);
                    t.nodes.append(t.gpa, .{
                        .id = id,
                        .role = .label,
                        .parent = node_ix,
                        .bounds = p.bounds,
                        .value = p.str,
                        .read_only = true,
                        .order = p.at * 2,
                        .synthetic = true,
                    }) catch @panic("OOM");
                }
            }
            i = j;
        }
    }

    /// `a` is a strict ancestor of `b`.
    pub fn isAncestor(t: *const Tree, a: u32, b: u32) bool {
        var cur = t.nodes.items[b].parent;
        while (cur != no_parent) : (cur = t.nodes.items[cur].parent) {
            if (cur == a) return true;
        }
        return false;
    }

    // ---- reading ------------------------------------------------------------------------

    pub fn str(t: *const Tree, s: Str) ?[]const u8 {
        if (!s.present) return null;
        return t.strings.items[s.off..][0..s.len];
    }

    pub fn indexOf(t: *const Tree, id: NodeId) ?u32 {
        return t.index.get(id);
    }

    pub fn get(t: *const Tree, id: NodeId) ?*const Node {
        const ix = t.index.get(id) orelse return null;
        return &t.nodes.items[ix];
    }

    pub fn at(t: *const Tree, ix: u32) *const Node {
        return &t.nodes.items[ix];
    }

    pub fn root(t: *const Tree) ?*const Node {
        if (t.nodes.items.len == 0) return null;
        return &t.nodes.items[0];
    }

    /// Children indices of node `ix` (after `finalize`).
    pub fn children(t: *const Tree, ix: u32) []const u32 {
        const n = &t.nodes.items[ix];
        return t.child_list.items[n.first_child..][0..n.child_count];
    }

    pub fn parentOf(t: *const Tree, ix: u32) ?u32 {
        const p = t.nodes.items[ix].parent;
        return if (p == no_parent) null else p;
    }

    /// The id assistive technology should treat as focused.
    pub fn focusId(t: *const Tree) NodeId {
        if (t.nodes.items.len == 0) return .root;
        return t.nodes.items[t.reported_focus].id;
    }

    /// The accessible name: the label, else the text gathered from content (buttons,
    /// tabs, ...), else for static text its value.
    pub fn name(t: *const Tree, n: *const Node) ?[]const u8 {
        if (t.str(n.label)) |l| return l;
        if (t.str(n.content)) |c| return c;
        if (n.role == .label) return t.str(n.value);
        return null;
    }

    /// The deepest node whose bounds contain `p` (window coordinates), for hit testing.
    pub fn hitTest(t: *const Tree, p: Point) ?u32 {
        if (t.nodes.items.len == 0) return null;
        var best: ?u32 = null;
        // Later nodes in pre-order are deeper or painted later; take the last match.
        for (t.nodes.items, 0..) |n, ix| {
            if (ix == 0) continue;
            if (n.bounds.contains(p)) best = @intCast(ix);
        }
        return best orelse 0;
    }

    /// Debug dump: one line per node, indented by depth (`role "name" [states]`).
    pub fn dump(t: *const Tree, w: *std.Io.Writer) !void {
        if (t.nodes.items.len == 0) return;
        try t.dumpNode(w, 0, 0);
    }

    fn dumpNode(t: *const Tree, w: *std.Io.Writer, ix: u32, d: usize) !void {
        const n = t.at(ix);
        for (0..d) |_| try w.writeAll("  ");
        try w.print("{t}", .{n.role});
        if (t.name(n)) |s| try w.print(" \"{s}\"", .{s});
        if (n.role != .label) if (t.str(n.value)) |s| try w.print(" value=\"{s}\"", .{s});
        if (t.str(n.placeholder)) |s| try w.print(" placeholder=\"{s}\"", .{s});
        if (n.selected) |v| if (v) try w.writeAll(" selected");
        if (n.expanded) |v| try w.writeAll(if (v) " expanded" else " collapsed");
        if (n.toggled) |v| try w.print(" toggled={t}", .{v});
        if (n.disabled) try w.writeAll(" disabled");
        if (n.text_selection) |sel| try w.print(" selection={d}..{d}", .{ sel.anchor, sel.focus });
        if (t.finalized and ix == t.reported_focus and ix != 0) try w.writeAll(" focused");
        try w.writeAll("\n");
        if (t.finalized) for (t.children(ix)) |c| try t.dumpNode(w, c, d + 1);
    }
};

// ---------------------------------------------------------------------------------------
// Incremental updates
// ---------------------------------------------------------------------------------------

/// What changed on a node between two frames.
pub const ChangeMask = packed struct(u16) {
    added: bool = false,
    removed: bool = false,
    name: bool = false,
    description: bool = false,
    value: bool = false,
    /// selected / expanded / toggled / disabled / read-only
    state: bool = false,
    bounds: bool = false,
    children: bool = false,
    role: bool = false,
    actions: bool = false,
    placeholder: bool = false,
    numeric: bool = false,
    /// The caret or selection of a text field moved.
    text_selection: bool = false,
    _pad: u3 = 0,

    pub fn any(m: ChangeMask) bool {
        return @as(u16, @bitCast(m)) != 0;
    }
};

pub const Change = struct {
    id: NodeId,
    what: ChangeMask,
    /// For added nodes the new parent, for removed nodes the old one.
    parent: ?NodeId = null,
    was_disabled: bool = false,
    /// For state changes: the previous selected/expanded/toggled values.
    was_selected: ?bool = null,
    was_expanded: ?bool = null,
    was_toggled: ?Toggled = null,
    was_text_selection: ?TextSelection = null,
};

/// The change set from one frame to the next (`diff`), handed to platform bridges.
pub const Changes = struct {
    entries: std.ArrayList(Change) = .empty,
    focus_changed: bool = false,
    old_focus: NodeId = .root,
    new_focus: NodeId = .root,
    /// The whole tree is new (first update after activation): bridges should treat it as
    /// a reset rather than per-node notifications.
    full: bool = false,

    pub fn deinit(c: *Changes, gpa: Allocator) void {
        c.entries.deinit(gpa);
    }

    pub fn clear(c: *Changes) void {
        c.entries.clearRetainingCapacity();
        c.focus_changed = false;
        c.full = false;
        c.old_focus = .root;
        c.new_focus = .root;
    }

    pub fn find(c: *const Changes, id: NodeId) ?ChangeMask {
        for (c.entries.items) |e| if (e.id == id) return e.what;
        return null;
    }

    pub fn isEmpty(c: *const Changes) bool {
        return c.entries.items.len == 0 and !c.focus_changed and !c.full;
    }
};

fn strEql(a: *const Tree, sa: Str, b: *const Tree, sb: Str) bool {
    if (sa.present != sb.present) return false;
    if (!sa.present) return true;
    return std.mem.eql(u8, a.str(sa).?, b.str(sb).?);
}

fn optEql(comptime T: type, a: ?T, b: ?T) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.? == b.?;
}

/// Compare `prev` (last frame's finalized tree, possibly empty) with `next`.
pub fn diff(gpa: Allocator, prev: *const Tree, next: *const Tree, out: *Changes) void {
    out.clear();
    out.new_focus = next.focusId();
    out.old_focus = if (prev.finalized) prev.focusId() else .root;
    if (!prev.finalized or prev.nodes.items.len == 0) {
        out.full = true;
        out.focus_changed = out.new_focus != .root;
        return;
    }
    out.focus_changed = out.old_focus != out.new_focus;
    for (next.nodes.items, 0..) |*n, ix| {
        const pix = prev.indexOf(n.id) orelse {
            const parent: ?NodeId = if (next.parentOf(@intCast(ix))) |p| next.at(p).id else null;
            out.entries.append(gpa, .{ .id = n.id, .what = .{ .added = true }, .parent = parent }) catch @panic("OOM");
            continue;
        };
        const p = prev.at(pix);
        var m: ChangeMask = .{};
        if (p.role != n.role) m.role = true;
        const pn = prev.name(p);
        const nn = next.name(n);
        if ((pn == null) != (nn == null) or (pn != null and !std.mem.eql(u8, pn.?, nn.?))) m.name = true;
        if (!strEql(prev, p.description, next, n.description)) m.description = true;
        if (!strEql(prev, p.value, next, n.value)) m.value = true;
        if (!strEql(prev, p.placeholder, next, n.placeholder)) m.placeholder = true;
        if (!optEql(bool, p.selected, n.selected) or !optEql(bool, p.expanded, n.expanded) or !optEql(Toggled, p.toggled, n.toggled) or p.disabled != n.disabled or p.read_only != n.read_only) m.state = true;
        if (!optEql(f64, p.numeric_value, n.numeric_value) or !optEql(f64, p.min_numeric_value, n.min_numeric_value) or !optEql(f64, p.max_numeric_value, n.max_numeric_value)) m.numeric = true;
        if (!std.meta.eql(p.bounds, n.bounds)) m.bounds = true;
        if (!std.meta.eql(p.text_selection, n.text_selection)) m.text_selection = true;
        if (p.actions.bits.mask != n.actions.bits.mask) m.actions = true;
        const pc = prev.children(pix);
        const nc = next.children(@intCast(ix));
        if (pc.len != nc.len) m.children = true else for (pc, nc) |a, b| {
            if (prev.at(a).id != next.at(b).id) {
                m.children = true;
                break;
            }
        }
        if (m.any()) out.entries.append(gpa, .{
            .id = n.id,
            .what = m,
            .was_disabled = p.disabled,
            .was_selected = p.selected,
            .was_expanded = p.expanded,
            .was_toggled = p.toggled,
            .was_text_selection = p.text_selection,
        }) catch @panic("OOM");
    }
    for (prev.nodes.items) |n| {
        if (next.indexOf(n.id) != null) continue;
        const parent: ?NodeId = if (n.parent != no_parent) prev.at(n.parent).id else null;
        out.entries.append(gpa, .{ .id = n.id, .what = .{ .removed = true }, .parent = parent }) catch @panic("OOM");
    }
}

/// What a platform bridge receives after a frame: the new tree (valid until the next
/// update) and what changed since the previous one.
pub const Update = struct {
    tree: *const Tree,
    changes: *const Changes,
};

// ---------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------

const testing = std.testing;

fn spec(id: u64, role: Role) NodeSpec {
    return .{ .id = @enumFromInt(id), .role = role, .bounds = .{ .origin = .zero, .size = .{ .width = 10, .height = 10 } } };
}

test "tree builds pre-order with children and text content" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    t.begin("Main", .{ .origin = .zero, .size = .{ .width = 100, .height = 100 } });
    try testing.expect(t.push(spec(1, .group)));
    try testing.expect(t.push(spec(2, .button)));
    t.appendText("Save", .{ .origin = .zero, .size = .zero });
    t.appendText(" all ", .{ .origin = .zero, .size = .zero });
    t.pop();
    var s3 = spec(3, .button);
    s3.info.label = "Close";
    try testing.expect(t.push(s3));
    t.appendText("x", .{ .origin = .zero, .size = .zero });
    t.pop();
    t.pop();
    t.finalize(null);
    try testing.expectEqual(@as(usize, 4), t.len());
    try testing.expectEqualStrings("Main", t.name(t.at(0)).?);
    try testing.expectEqual(@as(usize, 1), t.children(0).len);
    try testing.expectEqual(@as(usize, 2), t.children(1).len);
    try testing.expectEqualStrings("Save all", t.name(t.get(@enumFromInt(2)).?).?);
    try testing.expectEqualStrings("Close", t.name(t.get(@enumFromInt(3)).?).?);
    try testing.expectEqual(@as(u32, 1), t.get(@enumFromInt(3)).?.index_in_parent);
}

test "duplicate ids are dropped" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    t.begin(null, .{ .origin = .zero, .size = .zero });
    try testing.expect(t.push(spec(1, .button)));
    t.pop();
    try testing.expect(!t.push(spec(1, .button)));
    try testing.expectEqual(@as(u32, 1), t.duplicates);
}

test "focus and active descendant (zui gating)" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    t.begin(null, .{ .origin = .zero, .size = .zero });
    var list = spec(1, .list_box);
    list.focus_id = 77;
    try testing.expect(t.push(list));
    var item = spec(2, .list_box_option);
    item.info.active_descendant = true;
    try testing.expect(t.push(item));
    t.pop();
    t.pop();
    var other = spec(3, .list_box_option);
    other.info.active_descendant = true;
    try testing.expect(t.push(other));
    t.pop();
    t.finalize(77);
    try testing.expectEqual(@as(NodeId, @enumFromInt(2)), t.focusId());

    // Focus elsewhere: active-descendant claims are ignored.
    t.finalized = false;
    t.finalize(5);
    try testing.expectEqual(NodeId.root, t.focusId());
}

test "reuseRange copies a cached subtree under the current node" {
    var a = Tree.init(testing.allocator);
    defer a.deinit();
    a.begin(null, .{ .origin = .zero, .size = .zero });
    try testing.expect(a.push(spec(1, .group)));
    const start = a.len();
    try testing.expect(a.push(spec(2, .list)));
    var it = spec(3, .list_item);
    it.info.label = "Row";
    try testing.expect(a.push(it));
    a.pop();
    a.pop();
    const end = a.len();
    a.pop();
    a.finalize(null);

    var b = Tree.init(testing.allocator);
    defer b.deinit();
    b.begin(null, .{ .origin = .zero, .size = .zero });
    try testing.expect(b.push(spec(9, .group)));
    b.reuseRange(&a, start, end, 0, 0);
    b.pop();
    b.finalize(null);
    const list = b.indexOf(@enumFromInt(2)).?;
    try testing.expectEqual(b.indexOf(@enumFromInt(9)).?, b.parentOf(list).?);
    try testing.expectEqualStrings("Row", b.name(b.get(@enumFromInt(3)).?).?);
    try testing.expectEqual(list, b.parentOf(b.indexOf(@enumFromInt(3)).?).?);
}

test "diff reports added, removed, changed and focus" {
    const gpa = testing.allocator;
    var a = Tree.init(gpa);
    defer a.deinit();
    a.begin(null, .{ .origin = .zero, .size = .zero });
    var b1 = spec(1, .button);
    b1.info.label = "One";
    b1.focus_id = 4;
    _ = a.push(b1);
    a.pop();
    _ = a.push(spec(2, .button));
    a.pop();
    a.finalize(null);

    var b = Tree.init(gpa);
    defer b.deinit();
    b.begin(null, .{ .origin = .zero, .size = .zero });
    b1.info.label = "Uno";
    _ = b.push(b1);
    b.pop();
    var sw = spec(3, .@"switch");
    sw.info.toggled = .on;
    _ = b.push(sw);
    b.pop();
    b.finalize(4);

    var ch: Changes = .{};
    defer ch.deinit(gpa);
    diff(gpa, &a, &b, &ch);
    try testing.expect(ch.focus_changed);
    try testing.expectEqual(@as(NodeId, @enumFromInt(1)), ch.new_focus);
    try testing.expect(ch.find(@enumFromInt(1)).?.name);
    try testing.expect(ch.find(@enumFromInt(3)).?.added);
    try testing.expect(ch.find(@enumFromInt(2)).?.removed);
    try testing.expect(ch.find(.root).?.children);

    // First frame: a full update.
    var empty = Tree.init(gpa);
    defer empty.deinit();
    diff(gpa, &empty, &b, &ch);
    try testing.expect(ch.full);
}

test "truncate rolls back speculative nodes" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    t.begin(null, .{ .origin = .zero, .size = .zero });
    const n0 = t.len();
    const p0 = t.piecesLen();
    _ = t.push(spec(1, .button));
    t.appendText("a", .{ .origin = .zero, .size = .zero });
    t.pop();
    t.truncate(n0, p0);
    try testing.expectEqual(n0, t.len());
    try testing.expect(t.push(spec(1, .button)));
}

test "text offset conversions" {
    const t = text_offsets;
    const s = "a\u{e9}\u{1F600}b\nc";
    // bytes: a(0) é(1,2) 😀(3..7) b(7) \n(8) c(9)
    try testing.expectEqual(@as(usize, 6), t.charCount(s));
    try testing.expectEqual(@as(usize, 3), t.byteToChar(s, 7));
    try testing.expectEqual(@as(usize, 7), t.charToByte(s, 3));
    try testing.expectEqual(@as(usize, 7), t.utf16Len(s));
    try testing.expectEqual(@as(usize, 4), t.byteToUtf16(s, 7));
    try testing.expectEqual(@as(usize, 7), t.utf16ToByte(s, 4));
    try testing.expectEqual(@as(usize, 3), t.utf16ToByte(s, 3)); // inside the surrogate pair
    try testing.expectEqual(@as(usize, 1), t.byteToChar(s, 2)); // inside é snaps back
    try testing.expectEqual(@as(usize, 1), t.lineOf(s, 9));
    try testing.expectEqual([2]usize{ 0, 9 }, t.lineRange(s, 0).?);
    try testing.expectEqual([2]usize{ 9, 10 }, t.lineRange(s, 1).?);
    try testing.expect(t.lineRange(s, 2) == null);
}

test "diff reports text selection moves" {
    var a = Tree.init(testing.allocator);
    defer a.deinit();
    var b = Tree.init(testing.allocator);
    defer b.deinit();
    const vp: Bounds = .{ .origin = .zero, .size = .{ .width = 100, .height = 100 } };
    a.begin(null, vp);
    var sp = spec(5, .text_input);
    sp.info = .{ .value = "hello", .text_selection = .{ .anchor = 0, .focus = 0 } };
    _ = a.push(sp);
    a.pop();
    a.finalize(null);
    b.begin(null, vp);
    sp.info.text_selection = .{ .anchor = 1, .focus = 3 };
    _ = b.push(sp);
    b.pop();
    b.finalize(null);
    var ch: Changes = .{};
    defer ch.deinit(testing.allocator);
    diff(testing.allocator, &a, &b, &ch);
    const m = ch.find(@enumFromInt(5)).?;
    try testing.expect(m.text_selection);
    try testing.expect(!m.value);
}
