//! Where the shell mounts the views owned by other modules:
//!   `zeron_ui_transcript.TranscriptView.init(app_state, cx)` — follows the selected chat;
//!   `zeron_composer.ComposerView.init(app_state, cx)` — the pill + footer.
//! In fixture mode the selected chat's transcript is loaded from the fixture
//! directory (`transcripts/<chat-id>.json`, or `transcript-<name>.json`
//! through `seed-ids.json` for the reference exports).

const std = @import("std");
const zpui = @import("zpui");
const model = @import("zeron_model");
const zt = @import("zeron_theme");
const tr = @import("zeron_ui_transcript");
const composer_mod = @import("zeron_composer");
const ui = @import("../components/root.zig");
const fixtures_mod = @import("fixtures.zig");

const App = zpui.App;
const Entity = zpui.Entity;
const div = zpui.div;
const px = zpui.px;
const layout = zt.layout;

fn provideTheme(app: *App) *const zt.Theme {
    return ui.theme.get(app);
}

fn appOf(cx: anytype) *App {
    if (@TypeOf(cx) == *App) return cx;
    return cx.app;
}

pub const Slots = struct {
    state: Entity(model.AppState),
    fixtures: ?*fixtures_mod.Fixtures,
    transcript_view: Entity(tr.TranscriptView),
    composer_view: Entity(composer_mod.ComposerView),
    /// Theme the composer was last configured with.
    theme_key: u64 = 0,

    pub fn init(state: Entity(model.AppState), fixtures: ?*fixtures_mod.Fixtures, cx: anytype) !Slots {
        tr.view.theme_provider = provideTheme;
        const t = try cx.newWith(tr.TranscriptView, tr.TranscriptView.init, .{state});
        errdefer t.release(cx);
        const c = try cx.newWith(composer_mod.ComposerView, composer_mod.ComposerView.init, .{state});
        var self: Slots = .{ .state = state.retain(cx), .fixtures = fixtures, .transcript_view = t, .composer_view = c };
        if (fixtures) |f| if (f.meta.now) |n| if (model.time.parse(n)) |ts| {
            var l = t.lease(cx);
            defer l.end();
            l.value.now_override_ms = ts.toUnixMillis();
        };
        self.loadFixtureTranscript(cx);
        return self;
    }

    pub fn deinit(self: *Slots, app: *App) void {
        self.composer_view.release(app);
        self.transcript_view.release(app);
        self.state.release(app);
    }

    /// Feed the selected chat's fixture transcript into its (offline) store.
    pub fn loadFixtureTranscript(self: *Slots, cx: anytype) void {
        const f = self.fixtures orelse return;
        const app_state = self.state.read(cx);
        const store = app_state.transcript orelse return;
        const st = store.read(cx);
        if (st.replayed) return;
        const bytes = fixtures_mod.transcriptBytes(f, app_state.engine.read(cx).io, st.chat_id) orelse return;
        const entries = tr.parseFixture(f.arena.allocator(), bytes) catch |err| {
            std.log.scoped(.zeron_fixtures).warn("transcript {s}: {t}", .{ st.chat_id, err });
            return;
        };
        tr.loadEntries(store, entries, appOf(cx)) catch {};
    }

    fn syncTheme(self: *Slots, cx: anytype) void {
        const theme = ui.theme.get(cx);
        const key = std.hash.Wyhash.hash(@intFromEnum(theme.appearance), theme.variant_id);
        if (key == self.theme_key) return;
        self.theme_key = key;
        self.composer_view.update(cx, composer_mod.ComposerView.setTheme, .{theme.*});
    }

    /// The transcript (fills its parent), clearing `clearance` px of composer.
    pub fn transcript(self: *Slots, clearance: f32, width: f32, cx: anytype) zpui.AnyElement {
        {
            var l = self.transcript_view.lease(cx);
            defer l.end();
            l.value.bottom_clearance = clearance;
            l.value.rail_enabled = width >= tr.view.rail_min_container_width;
        }
        return zpui.intoAnyElement(div().sizeFull().child(self.transcript_view));
    }

    /// The composer column for a main panel `width` px wide.
    pub fn composer(self: *Slots, width: f32, cx: anytype) zpui.AnyElement {
        self.syncTheme(cx);
        const w = @min(layout.composer_max_width, @max(width - 2 * layout.space_lg, 0));
        self.composer_view.update(cx, composer_mod.ComposerView.setAvailableWidth, .{@as(?f32, w)});
        return zpui.intoAnyElement(div().wFull().flex().flexCol().itemsCenter().px(px(layout.space_lg))
            .child(div().wFull().maxW(px(w)).child(self.composer_view)));
    }
};
