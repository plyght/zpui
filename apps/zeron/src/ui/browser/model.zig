//! Browser state shared by the chrome and the platform hosts (zeron
//! `browser/model.rs`): page state, address normalization, navigation policy.
//! No native handles; pure and unit-tested against the Rust cases.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The page as the toolbar shows it (Rust `PageState`). Strings are owned.
pub const PageState = struct {
    url: ?[]u8 = null,
    title: []u8 = &.{},
    loading: bool = false,
    can_back: bool = false,
    can_forward: bool = false,
    @"error": ?[]u8 = null,
    /// 0..1 while loading (WKWebView `estimatedProgress`; null = unknown/indeterminate).
    progress: ?f32 = null,

    pub fn deinit(self: *PageState, gpa: Allocator) void {
        if (self.url) |u| gpa.free(u);
        gpa.free(self.title);
        if (self.@"error") |e| gpa.free(e);
        self.* = .{};
    }

    pub fn setUrl(self: *PageState, gpa: Allocator, url: ?[]const u8) void {
        if (optEql(self.url, url)) return;
        if (self.url) |u| gpa.free(u);
        self.url = if (url) |u| gpa.dupe(u8, u) catch null else null;
    }

    pub fn setTitle(self: *PageState, gpa: Allocator, title: []const u8) void {
        if (std.mem.eql(u8, self.title, title)) return;
        gpa.free(self.title);
        self.title = gpa.dupe(u8, title) catch &.{};
    }

    pub fn setError(self: *PageState, gpa: Allocator, msg: ?[]const u8) void {
        if (optEql(self.@"error", msg)) return;
        if (self.@"error") |e| gpa.free(e);
        self.@"error" = if (msg) |m| gpa.dupe(u8, m) catch null else null;
    }

    /// Copy `other` into `self` (owned). Returns whether anything changed.
    pub fn assign(self: *PageState, gpa: Allocator, other: PageState) bool {
        const changed = !self.eql(other);
        self.setUrl(gpa, other.url);
        self.setTitle(gpa, other.title);
        self.setError(gpa, other.@"error");
        self.loading = other.loading;
        self.can_back = other.can_back;
        self.can_forward = other.can_forward;
        self.progress = other.progress;
        return changed;
    }

    pub fn eql(a: PageState, b: PageState) bool {
        return optEql(a.url, b.url) and std.mem.eql(u8, a.title, b.title) and optEql(a.@"error", b.@"error") and
            a.loading == b.loading and a.can_back == b.can_back and a.can_forward == b.can_forward and
            std.meta.eql(a.progress, b.progress);
    }

    /// Tab label: the title, else the URL's host, else "Browser" (Rust `label`).
    pub fn label(self: *const PageState) []const u8 {
        const t = std.mem.trim(u8, self.title, " \t\r\n");
        if (t.len > 0) return self.title;
        if (self.url) |u| if (parse(u)) |p| return p.host_display else |_| {};
        return "Browser";
    }
};

fn optEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

/// Rust `Presentation`: hidden, live, or rendering while zpui owns drag input.
pub const Presentation = enum { hidden, live, passthrough };

pub fn presentation(active: bool, dragging: bool) Presentation {
    return if (!active) .hidden else if (dragging) .passthrough else .live;
}

// ---- URL handling -------------------------------------------------------------------

pub const Error = error{
    Empty,
    InvalidCharacters,
    Invalid,
    UnsupportedScheme,
    Credentials,
};

/// The user-facing message for a normalization error (Rust strings).
pub fn message(err: Error) []const u8 {
    return switch (err) {
        error.Empty => "Enter a website or localhost address.",
        error.InvalidCharacters => "This address contains invalid characters.",
        error.Invalid => "Enter a valid website or localhost address.",
        error.UnsupportedScheme => "Only http and https addresses are supported.",
        error.Credentials => "Use an address without an embedded username or password.",
    };
}

const Parsed = struct {
    scheme: []const u8,
    /// Host as written (lowercase not applied), IPv6 with brackets.
    host_display: []const u8,
    port: ?u16,
    /// Path + query + fragment ("" when absent).
    rest: []const u8,
};

/// Split `scheme://authority/rest` (http/https only, no credentials).
fn parse(text: []const u8) Error!Parsed {
    const sep = std.mem.indexOf(u8, text, "://") orelse {
        // `javascript:…`, `data:…`: a scheme without an authority.
        return error.UnsupportedScheme;
    };
    const scheme = text[0..sep];
    if (!std.ascii.eqlIgnoreCase(scheme, "http") and !std.ascii.eqlIgnoreCase(scheme, "https")) {
        for (scheme) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '+' or ch == '-' or ch == '.')) return error.Invalid;
        return error.UnsupportedScheme;
    }
    const after = text[sep + 3 ..];
    const auth_end = std.mem.indexOfAny(u8, after, "/?#\\") orelse after.len;
    const authority = after[0..auth_end];
    if (std.mem.indexOfScalar(u8, authority, '@') != null) return error.Credentials;
    var host: []const u8 = authority;
    var port: ?u16 = null;
    if (std.mem.startsWith(u8, authority, "[")) {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return error.Invalid;
        host = authority[0 .. close + 1];
        for (host[1..close]) |ch| if (!(std.ascii.isHex(ch) or ch == ':' or ch == '.')) return error.Invalid;
        if (close + 1 < authority.len) {
            if (authority[close + 1] != ':') return error.Invalid;
            port = try parsePort(authority[close + 2 ..]);
        }
    } else if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
        host = authority[0..colon];
        port = try parsePort(authority[colon + 1 ..]);
    }
    if (host.len == 0) return error.Invalid;
    if (host[0] != '[') for (host) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '.' or ch == '_' or ch >= 0x80)) return error.Invalid;
    };
    return .{ .scheme = scheme, .host_display = host, .port = port, .rest = after[auth_end..] };
}

fn parsePort(s: []const u8) Error!?u16 {
    if (s.len == 0) return null;
    return std.fmt.parseInt(u16, s, 10) catch error.Invalid;
}

/// `localhost`, `*.localhost`, 127.0.0.0/8, ::1 (Rust `loopback`).
pub fn loopbackHost(host: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(host, "localhost")) return true;
    if (host.len > ".localhost".len and std.ascii.endsWithIgnoreCase(host, ".localhost")) return true;
    if (std.mem.eql(u8, host, "[::1]") or std.mem.eql(u8, host, "::1")) return true;
    var it = std.mem.splitScalar(u8, host, '.');
    var octets: [4]u8 = undefined;
    var n: usize = 0;
    while (it.next()) |part| : (n += 1) {
        if (n == 4) return false;
        octets[n] = std.fmt.parseInt(u8, part, 10) catch return false;
    }
    return n == 4 and octets[0] == 127;
}

pub fn loopbackUrl(url: []const u8) bool {
    const p = parse(url) catch return false;
    return loopbackHost(p.host_display);
}

/// Rust `normalize_address`: bare hosts get https (http for loopback), only
/// http/https with a host and without credentials are accepted. Returns an
/// owned, canonical URL (lowercase scheme/host, default port dropped, "/" path).
pub fn normalizeAddress(gpa: Allocator, input: []const u8) (Error || Allocator.Error)![]u8 {
    const text = std.mem.trim(u8, input, " \t\r\n\x0b\x0c");
    if (text.len == 0) return error.Empty;
    for (text) |ch| if (ch < 0x20 or ch == 0x7f) return error.InvalidCharacters;
    // A bare host:port looks like a URI scheme to a URL parser. Only accept that
    // ambiguity when the suffix is an actual numeric port.
    const auth_end = std.mem.indexOfAny(u8, text, "/?#") orelse text.len;
    const authority = text[0..auth_end];
    const host_port = if (std.mem.lastIndexOfScalar(u8, authority, ':')) |c| blk: {
        const port = authority[c + 1 ..];
        if (port.len == 0) break :blk false;
        for (port) |ch| if (!std.ascii.isDigit(ch)) break :blk false;
        break :blk true;
    } else false;
    const explicit = std.mem.indexOf(u8, text, "://") != null or
        (std.mem.indexOfScalar(u8, text, ':') != null and !host_port and !std.mem.startsWith(u8, text, "["));

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const candidate = if (explicit) text else try std.fmt.allocPrint(arena, "https://{s}", .{text});
    const p = try parse(candidate);
    var scheme: []const u8 = try std.ascii.allocLowerString(arena, p.scheme);
    const host = try std.ascii.allocLowerString(arena, p.host_display);
    if (!explicit and loopbackHost(host)) scheme = "http";
    const default_port: u16 = if (std.mem.eql(u8, scheme, "http")) 80 else 443;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.print(gpa, "{s}://{s}", .{ scheme, host });
    if (p.port) |port| if (port != default_port) try out.print(gpa, ":{d}", .{port});
    if (p.rest.len == 0 or p.rest[0] != '/') try out.append(gpa, '/');
    for (p.rest) |ch| switch (ch) {
        ' ' => try out.appendSlice(gpa, "%20"),
        '\\' => try out.append(gpa, '/'),
        else => try out.append(gpa, ch),
    };
    return out.toOwnedSlice(gpa);
}

/// Rust `allowed_navigation`: http/https with a host and no credentials.
pub fn allowedNavigation(address: []const u8) bool {
    const p = parse(address) catch return false;
    return p.host_display.len > 0;
}

// ---- tests (zeron browser/model.rs) ---------------------------------------------------

test "normalizes web addresses and loopback ports" {
    const gpa = std.testing.allocator;
    const cases = [_][2][]const u8{
        .{ "localhost:3000", "http://localhost:3000/" },
        .{ "127.0.0.1:5173/a?x=1", "http://127.0.0.1:5173/a?x=1" },
        .{ "[::1]:8080", "http://[::1]:8080/" },
        .{ "[::1]", "http://[::1]/" },
        .{ " app.localhost:3000 ", "http://app.localhost:3000/" },
        .{ "example.com/path", "https://example.com/path" },
        .{ "https://localhost:3000", "https://localhost:3000/" },
        .{ "http://example.com", "http://example.com/" },
    };
    for (cases) |c| {
        const got = try normalizeAddress(gpa, c[0]);
        defer gpa.free(got);
        std.testing.expectEqualStrings(c[1], got) catch |e| {
            std.debug.print("input: {s}\n", .{c[0]});
            return e;
        };
    }
}

test "rejects non-web schemes, credentials and bad input" {
    const gpa = std.testing.allocator;
    for ([_][]const u8{
        "",
        "javascript:alert(1)",
        "file:///tmp/a",
        "data:text/html,hi",
        "zeron://open/chat/a",
        "https://user:pass@example.com",
        "https://",
        "two words",
        "https://example.com/\nsecret",
    }) |input| {
        if (normalizeAddress(gpa, input)) |ok| {
            gpa.free(ok);
            std.debug.print("accepted: {s}\n", .{input});
            return error.TestUnexpectedResult;
        } else |_| {}
    }
    try std.testing.expect(!allowedNavigation("javascript:alert(1)"));
    try std.testing.expect(!allowedNavigation("https://user@example.com/"));
    try std.testing.expect(allowedNavigation("http://127.0.0.1:8000/index.html"));
}

test "native visibility never outlives its surface" {
    try std.testing.expectEqual(Presentation.hidden, presentation(false, false));
    try std.testing.expectEqual(Presentation.hidden, presentation(false, true));
    try std.testing.expectEqual(Presentation.passthrough, presentation(true, true));
    try std.testing.expectEqual(Presentation.live, presentation(true, false));
}

test "tab labels fall back to host then browser" {
    const gpa = std.testing.allocator;
    var page: PageState = .{};
    defer page.deinit(gpa);
    try std.testing.expectEqualStrings("Browser", page.label());
    page.setUrl(gpa, "http://localhost:3000/path");
    try std.testing.expectEqualStrings("localhost", page.label());
    page.setTitle(gpa, "Local preview");
    try std.testing.expectEqualStrings("Local preview", page.label());
}

test "loopback hosts" {
    try std.testing.expect(loopbackHost("localhost"));
    try std.testing.expect(loopbackHost("app.localhost"));
    try std.testing.expect(loopbackHost("127.0.0.1"));
    try std.testing.expect(loopbackHost("[::1]"));
    try std.testing.expect(!loopbackHost("example.com"));
    try std.testing.expect(!loopbackHost("128.0.0.1"));
}
