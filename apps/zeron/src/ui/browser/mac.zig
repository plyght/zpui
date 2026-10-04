//! macOS browser host: port of zeron `browser/macos.rs` on raw Objective-C.
//!
//! A `WKWebView` (ephemeral `WKWebsiteDataStore`, shared by every tab) is a native
//! child view of the zpui window (`Window.attachNativeView`); the browser element
//! places it at its layout bounds each frame and zpui's overlay plane keeps menus,
//! popovers and tooltips above it. A runtime class `ZeronBrowserDelegate` is both
//! the navigation delegate (policy: http/https only; provisional/commit/finish/fail
//! state) and the UI delegate (target=_blank → new tab), and KV-observes `URL`,
//! `title`, `loading`, `canGoBack`, `canGoForward`, `estimatedProgress`. Callbacks only
//! record state and wake the view (`Waker`); they never re-enter zpui.
//!
//! WebKit is loaded at runtime (`dlopen`), so the binary links no extra framework and
//! cross-compiles without an SDK.

const std = @import("std");
const zpui = @import("zpui");
const model = @import("model.zig");
const Waker = @import("waker.zig").Waker;

const mac = zpui.mac_platform;
const objc = mac.objc_runtime;
const id = objc.id;
const SEL = objc.SEL;
const BOOL = objc.BOOL;
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.zeron_browser);

const host_ivar = "zeronHost";
const observed = [_][:0]const u8{ "URL", "title", "loading", "canGoBack", "canGoForward", "estimatedProgress" };

var delegate_class: ?*objc.Class = null;
var data_store: ?id = null;

extern "c" fn dlopen(path: [*:0]const u8, mode: c_int) ?*anyopaque;

fn loadWebKit() bool {
    if (objc.getClass("WKWebView") != null) return true;
    _ = dlopen("/System/Library/Frameworks/WebKit.framework/WebKit", 1); // RTLD_LAZY
    return objc.getClass("WKWebView") != null;
}

fn cls(comptime name: [:0]const u8) *objc.Class {
    return objc.getClass(name).?;
}

fn nsStr(gpa: Allocator, s: []const u8) ?id {
    const z = gpa.dupeSentinel(u8, s, 0) catch return null;
    defer gpa.free(z);
    return objc.nsString(z);
}

/// Objective-C block literal header (enough to invoke one).
const Block = extern struct {
    isa: ?*anyopaque,
    flags: c_int,
    reserved: c_int,
    invoke: *const anyopaque,
};

fn callPolicyBlock(block: *Block, policy: objc.NSInteger) void {
    const f: *const fn (*Block, objc.NSInteger) callconv(.c) void = @ptrCast(@alignCast(block.invoke));
    f(block, policy);
}

pub const Host = struct {
    gpa: Allocator,
    web: id,
    delegate: id,
    waker: *Waker,
    error_message: ?[]const u8 = null,
    /// The URL being loaded before WebKit commits it (Rust `requested_url`).
    requested_url: ?[]u8 = null,
    new_tabs: std.ArrayList([]u8) = .empty,
    finished: bool = false,

    pub fn create(gpa: Allocator, waker: *Waker) !*Host {
        if (!loadWebKit()) return error.WebKitUnavailable;
        registerDelegate();
        const pool = objc.AutoreleasePool.push();
        defer pool.pop();
        if (data_store == null) data_store = cls("WKWebsiteDataStore").msg(id, "nonPersistentDataStore", .{}).retain();
        const config = cls("WKWebViewConfiguration").new().?;
        defer config.release();
        config.msg(void, "setWebsiteDataStore:", .{data_store.?});
        const zero: objc.CGRect = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } };
        const web = cls("WKWebView").msg(id, "alloc", .{}).msg(?id, "initWithFrame:configuration:", .{ zero, config }) orelse return error.WebViewCreationFailed;
        errdefer web.release();
        const self = try gpa.create(Host);
        waker.retain();
        const delegate = delegate_class.?.new().?;
        self.* = .{ .gpa = gpa, .web = web, .delegate = delegate, .waker = waker };
        objc.setIvar(delegate, host_ivar, self);
        web.msg(void, "setNavigationDelegate:", .{delegate});
        web.msg(void, "setUIDelegate:", .{delegate});
        web.msg(void, "setAutoresizingMask:", .{@as(objc.NSUInteger, 0)});
        for (observed) |key| web.msg(void, "addObserver:forKeyPath:options:context:", .{ delegate, objc.nsString(key), @as(objc.NSUInteger, 0), @as(?*anyopaque, null) });
        return self;
    }

    pub fn destroy(self: *Host) void {
        const pool = objc.AutoreleasePool.push();
        defer pool.pop();
        for (observed) |key| self.web.msg(void, "removeObserver:forKeyPath:", .{ self.delegate, objc.nsString(key) });
        self.web.msg(void, "setNavigationDelegate:", .{@as(?id, null)});
        self.web.msg(void, "setUIDelegate:", .{@as(?id, null)});
        self.web.msg(void, "stopLoading", .{});
        objc.setIvar(self.delegate, host_ivar, null);
        self.delegate.release();
        self.web.release();
        if (self.requested_url) |u| self.gpa.free(u);
        for (self.new_tabs.items) |u| self.gpa.free(u);
        self.new_tabs.deinit(self.gpa);
        self.waker.release();
        self.gpa.destroy(self);
    }

    /// The `NSView*` to attach to the window.
    pub fn view(self: *Host) *anyopaque {
        return @ptrCast(self.web);
    }

    pub fn load(self: *Host, url: []const u8) !void {
        const pool = objc.AutoreleasePool.push();
        defer pool.pop();
        self.error_message = null;
        self.setRequested(url);
        const s = nsStr(self.gpa, url) orelse return error.OutOfMemory;
        const nsurl = cls("NSURL").msg(?id, "URLWithString:", .{s}) orelse return error.InvalidUrl;
        const request = cls("NSURLRequest").msg(id, "requestWithURL:", .{nsurl});
        _ = self.web.msg(?id, "loadRequest:", .{request});
    }

    pub fn reload(self: *Host) void {
        self.error_message = null;
        _ = self.web.msg(?id, "reload", .{});
        self.changed();
    }

    pub fn stop(self: *Host) void {
        self.web.msg(void, "stopLoading", .{});
    }

    pub fn history(self: *Host, forward: bool) void {
        if (forward) _ = self.web.msg(?id, "goForward", .{}) else _ = self.web.msg(?id, "goBack", .{});
    }

    fn setRequested(self: *Host, url: ?[]const u8) void {
        if (self.requested_url) |u| self.gpa.free(u);
        self.requested_url = if (url) |u| self.gpa.dupe(u8, u) catch null else null;
    }

    /// Snapshot the page into `page` (Rust `state`). Returns whether it changed.
    pub fn state(self: *Host, page: *model.PageState) bool {
        const pool = objc.AutoreleasePool.push();
        defer pool.pop();
        var snap: model.PageState = .{};
        const url: ?[]const u8 = self.requested_url orelse if (self.web.msg(?id, "URL", .{})) |u|
            (if (u.msg(?id, "absoluteString", .{})) |s| objc.utf8(s) else null)
        else
            null;
        snap.url = @constCast(url);
        snap.title = @constCast(if (self.web.msg(?id, "title", .{})) |t| objc.utf8(t) else "");
        snap.loading = objc.fromBOOL(self.web.msg(BOOL, "isLoading", .{}));
        snap.can_back = objc.fromBOOL(self.web.msg(BOOL, "canGoBack", .{}));
        snap.can_forward = objc.fromBOOL(self.web.msg(BOOL, "canGoForward", .{}));
        snap.@"error" = @constCast(self.error_message);
        if (snap.@"error" != null) snap.loading = false;
        snap.progress = if (snap.loading) @floatCast(self.web.msg(f64, "estimatedProgress", .{})) else null;
        // A failed provisional request has no committed WebKit URL.
        if (snap.url == null) snap.url = page.url;
        return page.assign(self.gpa, snap);
    }

    pub fn takeNewTabs(self: *Host) std.ArrayList([]u8) {
        const out = self.new_tabs;
        self.new_tabs = .empty;
        return out;
    }

    fn changed(self: *Host) void {
        self.waker.wake();
    }

    fn fail(self: *Host, msg: []const u8) void {
        self.error_message = msg;
        self.changed();
    }
};

fn hostOf(this: id) ?*Host {
    return @ptrCast(@alignCast(objc.getIvar(this, host_ivar)));
}

fn registerDelegate() void {
    if (delegate_class != null) return;
    const b = objc.ClassBuilder.init("NSObject", "ZeronBrowserDelegate") orelse {
        delegate_class = objc.getClass("ZeronBrowserDelegate");
        return;
    };
    _ = b.addPointerIvar(host_ivar);
    _ = b.addMethod("observeValueForKeyPath:ofObject:change:context:", &observe, "v@:@@@^v");
    _ = b.addMethod("webView:decidePolicyForNavigationAction:decisionHandler:", &decideAction, "v@:@@@?");
    _ = b.addMethod("webView:decidePolicyForNavigationResponse:decisionHandler:", &decideResponse, "v@:@@@?");
    _ = b.addMethod("webView:didStartProvisionalNavigation:", &didStart, "v@:@@");
    _ = b.addMethod("webView:didCommitNavigation:", &didCommit, "v@:@@");
    _ = b.addMethod("webView:didFinishNavigation:", &didFinish, "v@:@@");
    _ = b.addMethod("webView:didFailProvisionalNavigation:withError:", &didFailProvisional, "v@:@@@");
    _ = b.addMethod("webView:didFailNavigation:withError:", &didFail, "v@:@@@");
    _ = b.addMethod("webViewWebContentProcessDidTerminate:", &terminated, "v@:@");
    _ = b.addMethod("webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:", &createWebView, "@@:@@@@");
    _ = objc.addProtocol(b, "WKNavigationDelegate");
    _ = objc.addProtocol(b, "WKUIDelegate");
    delegate_class = b.register();
}

fn observe(this: id, _: SEL, _: ?id, _: ?id, _: ?id, _: ?*anyopaque) callconv(.c) void {
    if (hostOf(this)) |h| h.changed();
}

fn actionUrl(action: id) []const u8 {
    const request = action.msg(?id, "request", .{}) orelse return "";
    const url = request.msg(?id, "URL", .{}) orelse return "";
    const s = url.msg(?id, "absoluteString", .{}) orelse return "";
    return objc.utf8(s);
}

const WKNavigationActionPolicyCancel: objc.NSInteger = 0;
const WKNavigationActionPolicyAllow: objc.NSInteger = 1;

fn decideAction(this: id, _: SEL, _: id, action: id, decision: *Block) callconv(.c) void {
    const url = actionUrl(action);
    const allowed = model.allowedNavigation(url);
    if (hostOf(this)) |h| if (allowed) {
        const main_frame = if (action.msg(?id, "targetFrame", .{})) |f| objc.fromBOOL(f.msg(BOOL, "isMainFrame", .{})) else false;
        if (main_frame) h.setRequested(url);
    };
    callPolicyBlock(decision, if (allowed) WKNavigationActionPolicyAllow else WKNavigationActionPolicyCancel);
}

fn decideResponse(this: id, _: SEL, _: id, response: id, decision: *Block) callconv(.c) void {
    const displayable = objc.fromBOOL(response.msg(BOOL, "canShowMIMEType", .{}));
    if (!displayable) if (hostOf(this)) |h| h.fail("This file can\u{2019}t be previewed here. Open it in your default browser.");
    callPolicyBlock(decision, if (displayable) 1 else 0);
}

fn didStart(this: id, _: SEL, _: id, _: ?id) callconv(.c) void {
    const h = hostOf(this) orelse return;
    h.error_message = null;
    h.finished = false;
    h.changed();
}

fn didCommit(this: id, _: SEL, _: id, _: ?id) callconv(.c) void {
    const h = hostOf(this) orelse return;
    h.setRequested(null);
    h.changed();
}

fn didFinish(this: id, _: SEL, _: id, _: ?id) callconv(.c) void {
    const h = hostOf(this) orelse return;
    h.finished = true;
    h.changed();
}

fn errorCode(err: id) objc.NSInteger {
    return err.msg(objc.NSInteger, "code", .{});
}

fn didFailProvisional(this: id, _: SEL, _: id, _: ?id, err: id) callconv(.c) void {
    if (errorCode(err) == -999) return; // NSURLErrorCancelled
    const h = hostOf(this) orelse return;
    log.warn("browser provisional navigation failed: {s}", .{objc.errorDescription(err)});
    h.fail("Check the address and make sure your server is running, then try again.");
}

fn didFail(this: id, _: SEL, _: id, _: ?id, err: id) callconv(.c) void {
    if (errorCode(err) == -999) return;
    const h = hostOf(this) orelse return;
    log.warn("browser navigation failed: {s}", .{objc.errorDescription(err)});
    h.fail("The connection was interrupted. Try loading this page again.");
}

fn terminated(this: id, _: SEL, _: id) callconv(.c) void {
    if (hostOf(this)) |h| h.fail("The page stopped responding. Reload to continue.");
}

/// target=_blank / window.open: never a new native window; a user-visible new tab.
fn createWebView(this: id, _: SEL, _: id, _: id, action: id, _: id) callconv(.c) ?id {
    const h = hostOf(this) orelse return null;
    const url = actionUrl(action);
    if (model.allowedNavigation(url)) {
        const owned = h.gpa.dupe(u8, url) catch return null;
        h.new_tabs.append(h.gpa, owned) catch h.gpa.free(owned);
        h.changed();
    }
    return null;
}
