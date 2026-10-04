//! Stable conversation links (port of zeron `crates/ui/src/links.rs`) and the inbound
//! deep-link router (`AppState::open_deep_link` / `apply_pending_deep_link`,
//! `state.rs`).
//!
//! `zeron://open/chat/<chat id>?workspace=<locator>`: the locator is the first 16 hex
//! digits of sha256(`"<Scope>\0<identity>"`) — enough to reject links from another
//! local or synced workspace without putting device, user or organization ids in the
//! URL. A link that arrives before the workspace identity / chat list is known stays
//! pending and is retried as they load (cold launch with a URL argument).

const std = @import("std");
const Allocator = std.mem.Allocator;
const zpui = @import("zpui");
const model = @import("zeron_model");
const engine_mod = @import("zeron_engine");
const protocol = engine_mod.protocol;

const App = zpui.App;
const Entity = zpui.Entity;
const Context = zpui.Context;

pub const ConversationDeepLink = struct {
    chat_id: []u8,
    workspace: []u8,

    pub fn deinit(self: ConversationDeepLink, gpa: Allocator) void {
        gpa.free(self.chat_id);
        gpa.free(self.workspace);
    }
};

pub const ParseError = error{
    NotAConversationLink,
    MissingWorkspace,
    InvalidConversationId,
    InvalidEscape,
    InvalidUtf8,
    OutOfMemory,
};

/// The user-facing reason (Rust's error strings).
pub fn errorMessage(err: ParseError) []const u8 {
    return switch (err) {
        error.NotAConversationLink => "not a Zeron conversation link",
        error.MissingWorkspace => "missing workspace locator",
        error.InvalidConversationId => "invalid conversation id",
        error.InvalidEscape => "invalid URL escape",
        error.InvalidUtf8 => "invalid UTF-8 in URL",
        error.OutOfMemory => "out of memory",
    };
}

/// `workspace_locator`: null until the identity it hashes is known.
pub fn workspaceLocator(out: *[16]u8, scope: ?protocol.WorkspaceScope, auth: ?*const protocol.AuthState, local_device_id: ?[]const u8) ?[]const u8 {
    const sc = scope orelse return null;
    var buf: [512]u8 = undefined;
    // `format!("{scope:?}\0{identity}")` — Rust's Debug names the variant.
    const scope_name = switch (sc) {
        .synced => "Synced",
        .development => "Development",
        .local => "Local",
    };
    const text = switch (sc) {
        .synced, .development => blk: {
            const a = auth orelse return null;
            const signed = switch (a.*) {
                .signedIn => |s| s,
                else => return null,
            };
            break :blk std.fmt.bufPrint(&buf, "{s}\x00user:{s}:org:{s}", .{ scope_name, signed.user.id, signed.orgId orelse "personal" }) catch return null;
        },
        .local => std.fmt.bufPrint(&buf, "{s}\x00device:{s}", .{ scope_name, local_device_id orelse return null }) catch return null,
    };
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    @memcpy(out, hex[0..16]);
    return out;
}

/// `zeron_conversation_link`.
pub fn conversationLink(gpa: Allocator, chat_id: []const u8, workspace: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "zeron://open/chat/");
    try encodeComponent(&out, gpa, chat_id);
    try out.appendSlice(gpa, "?workspace=");
    try encodeComponent(&out, gpa, workspace);
    return out.toOwnedSlice(gpa);
}

/// `parse_zeron_conversation_link` (owned result).
pub fn parse(gpa: Allocator, url: []const u8) ParseError!ConversationDeepLink {
    const prefix = "zeron://open/chat/";
    if (!std.mem.startsWith(u8, url, prefix)) return error.NotAConversationLink;
    const rest = url[prefix.len..];
    const q = std.mem.indexOfScalar(u8, rest, '?') orelse return error.MissingWorkspace;
    const chat_id = rest[0..q];
    if (chat_id.len == 0 or std.mem.indexOfScalar(u8, chat_id, '/') != null) return error.InvalidConversationId;
    var parts = std.mem.splitScalar(u8, rest[q + 1 ..], '&');
    const workspace = while (parts.next()) |part| {
        if (std.mem.startsWith(u8, part, "workspace=")) break part["workspace=".len..];
    } else return error.MissingWorkspace;
    const id = try decodeComponent(gpa, chat_id);
    errdefer gpa.free(id);
    return .{ .chat_id = id, .workspace = try decodeComponent(gpa, workspace) };
}

fn encodeComponent(out: *std.ArrayList(u8), gpa: Allocator, value: []const u8) Allocator.Error!void {
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            try out.append(gpa, byte);
        } else {
            var b: [3]u8 = undefined;
            _ = std.fmt.bufPrint(&b, "%{X:0>2}", .{byte}) catch unreachable;
            try out.appendSlice(gpa, &b);
        }
    }
}

fn decodeComponent(gpa: Allocator, value: []const u8) ParseError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < value.len) {
        if (value[i] == '%') {
            if (i + 3 > value.len) return error.InvalidEscape;
            const byte = std.fmt.parseInt(u8, value[i + 1 .. i + 3], 16) catch return error.InvalidEscape;
            try out.append(gpa, byte);
            i += 3;
        } else {
            try out.append(gpa, value[i]);
            i += 1;
        }
    }
    if (!std.unicode.utf8ValidateSlice(out.items)) return error.InvalidUtf8;
    return out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------------------
// Router
// ---------------------------------------------------------------------------------------

/// Shows a user-facing notice (the shell's sidebar notice).
pub const NoticeSink = struct {
    ctx: ?*anyopaque = null,
    func: ?*const fn (ctx: ?*anyopaque, app: *App, text: []const u8) void = null,
};

/// The inbound side: `open` parses and selects the chat when the workspace matches,
/// keeping the link pending until the identity and the chat list are known.
pub const DeepLinks = struct {
    gpa: Allocator,
    state: Entity(model.AppState),
    pending: ?ConversationDeepLink = null,
    /// Latest user-facing notice not yet shown (`deep_link_notice`), owned.
    notice: ?[]u8 = null,
    sink: NoticeSink = .{},
    subs: zpui.Subscriptions = .{},

    pub fn init(state: Entity(model.AppState), cx: *Context(DeepLinks)) !DeepLinks {
        var self: DeepLinks = .{ .gpa = cx.gpa(), .state = state.retain(cx) };
        errdefer self.state.release(cx);
        const s = state.read(cx);
        try self.subs.add(cx.gpa(), try cx.observe(s.workspace, onWorkspace));
        try self.subs.add(cx.gpa(), try cx.observe(s.auth, onAuth));
        try self.subs.add(cx.gpa(), try cx.observe(s.engine, onEngine));
        return self;
    }

    pub fn deinit(self: *DeepLinks, app: *App) void {
        self.subs.deinit(self.gpa);
        if (self.pending) |p| p.deinit(self.gpa);
        if (self.notice) |n| self.gpa.free(n);
        self.state.release(app);
    }

    fn onWorkspace(self: *DeepLinks, _: Entity(model.WorkspaceStore), cx: *Context(DeepLinks)) void {
        self.apply(cx);
    }
    fn onAuth(self: *DeepLinks, _: Entity(model.AuthStore), cx: *Context(DeepLinks)) void {
        self.apply(cx);
    }
    fn onEngine(self: *DeepLinks, _: Entity(model.EngineState), cx: *Context(DeepLinks)) void {
        self.apply(cx);
    }

    /// `AppState::open_deep_link`.
    pub fn open(self: *DeepLinks, url: []const u8, cx: *Context(DeepLinks)) void {
        const link = parse(self.gpa, url) catch |err| {
            self.setNotice(errorMessage(err), cx);
            return;
        };
        if (self.pending) |p| p.deinit(self.gpa);
        self.pending = link;
        self.apply(cx);
        cx.notify();
    }

    /// `apply_pending_deep_link`.
    pub fn apply(self: *DeepLinks, cx: *Context(DeepLinks)) void {
        const link = self.pending orelse return;
        const app_state = self.state.read(cx);
        const ws = app_state.workspace.read(cx);
        const scope = app_state.engine.read(cx).workspaceScope() orelse ws.workspace_scope;
        const auth_store = app_state.auth.read(cx);
        var buf: [16]u8 = undefined;
        const locator = workspaceLocator(&buf, scope, if (auth_store.auth) |*a| a else null, ws.local_device_id) orelse return;
        if (!std.mem.eql(u8, locator, link.workspace)) {
            self.clearPending();
            self.setNotice("This conversation link belongs to another workspace", cx);
            return;
        }
        if (ws.chat(link.chat_id) != null) {
            const id = self.gpa.dupe(u8, link.chat_id) catch return;
            defer self.gpa.free(id);
            self.clearPending();
            app_state.workspace.update(cx, model.WorkspaceStore.selectChat, .{@as(?[]const u8, id)});
        } else if (ws.chats_synced) {
            self.clearPending();
            self.setNotice("The linked conversation was not found", cx);
        }
    }

    fn clearPending(self: *DeepLinks) void {
        if (self.pending) |p| p.deinit(self.gpa);
        self.pending = null;
    }

    fn setNotice(self: *DeepLinks, text: []const u8, cx: *Context(DeepLinks)) void {
        if (self.sink.func) |f| {
            f(self.sink.ctx, cx.app, text);
            return;
        }
        if (self.notice) |n| self.gpa.free(n);
        self.notice = self.gpa.dupe(u8, text) catch null;
        cx.notify();
    }

    /// `take_deep_link_notice`.
    pub fn takeNotice(self: *DeepLinks) ?[]u8 {
        defer self.notice = null;
        return self.notice;
    }
};

// ---------------------------------------------------------------------------------------

const testing = std.testing;

test "zeron link round-trips reserved characters" {
    const gpa = testing.allocator;
    const link = try conversationLink(gpa, "chat/with space", "workspace:one");
    defer gpa.free(link);
    try testing.expectEqualStrings("zeron://open/chat/chat%2Fwith%20space?workspace=workspace%3Aone", link);
    const parsed = try parse(gpa, link);
    defer parsed.deinit(gpa);
    try testing.expectEqualStrings("chat/with space", parsed.chat_id);
    try testing.expectEqualStrings("workspace:one", parsed.workspace);
}

test "malformed or foreign links are rejected" {
    const gpa = testing.allocator;
    try testing.expectError(error.NotAConversationLink, parse(gpa, "https://example.com"));
    try testing.expectError(error.MissingWorkspace, parse(gpa, "zeron://open/chat/id"));
    try testing.expectError(error.InvalidEscape, parse(gpa, "zeron://open/chat/%GG?workspace=x"));
    try testing.expectError(error.InvalidConversationId, parse(gpa, "zeron://open/chat/a/b?workspace=x"));
    try testing.expectError(error.InvalidConversationId, parse(gpa, "zeron://open/chat/?workspace=x"));
}

test "workspace locators wait for identity and differ per device/user (Rust parity)" {
    var a: [16]u8 = undefined;
    var b: [16]u8 = undefined;
    try testing.expect(workspaceLocator(&a, .local, null, null) == null);
    const first = workspaceLocator(&a, .local, null, "device-a").?;
    const second = workspaceLocator(&b, .local, null, "device-b").?;
    try testing.expect(!std.mem.eql(u8, first, second));
    // sha256("Local\0device:device-a")[..16], computed with Rust's `format!("{scope:?}\0{identity}")`.
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("Local\x00device:device-a", &digest, .{});
    try testing.expectEqualStrings(std.fmt.bytesToHex(digest, .lower)[0..16], first);

    try testing.expect(workspaceLocator(&a, .synced, null, "device-a") == null);
    const signed_out: protocol.AuthState = .signedOut;
    try testing.expect(workspaceLocator(&a, .synced, &signed_out, "device-a") == null);
    const needs_org: protocol.AuthState = .{ .needsOrganization = .{ .user = .{ .id = "user-a", .email = "u@example.com" } } };
    try testing.expect(workspaceLocator(&a, .synced, &needs_org, "device-a") == null);
    const signed_in: protocol.AuthState = .{ .signedIn = .{ .user = .{ .id = "user-a", .email = "u@example.com" }, .orgId = "org-a" } };
    try testing.expect(workspaceLocator(&a, .synced, &signed_in, null) != null);
}
