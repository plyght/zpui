//! zeron's actions (the `zeron_actions` module): every `actions!` group of
//! the Rust UI as zpui actions, with identical `namespace::Name` strings —
//! `composer` (composer.rs), `shell` (shell.rs, incl. the data-carrying
//! `JumpSession`), `terminal` (terminal/panel.rs), `browser`
//! (browser/mod.rs) and `zeron` (app_menus.rs). `keymap.zig` holds the
//! default bindings (`applyKeymap`).

const std = @import("std");
const zpui = @import("zpui");
const action = zpui.action;

pub const keymap = @import("keymap.zig");

/// `actions!(composer, [...])` — text editing in the composer inputs.
pub const composer = struct {
    pub const Backspace = action("composer::Backspace");
    pub const Delete = action("composer::Delete");
    pub const Left = action("composer::Left");
    pub const Right = action("composer::Right");
    pub const Up = action("composer::Up");
    pub const Down = action("composer::Down");
    pub const SelectLeft = action("composer::SelectLeft");
    pub const SelectRight = action("composer::SelectRight");
    pub const SelectUp = action("composer::SelectUp");
    pub const SelectDown = action("composer::SelectDown");
    pub const SelectAll = action("composer::SelectAll");
    pub const Home = action("composer::Home");
    pub const End = action("composer::End");
    pub const SelectHome = action("composer::SelectHome");
    pub const SelectEnd = action("composer::SelectEnd");
    pub const DocStart = action("composer::DocStart");
    pub const DocEnd = action("composer::DocEnd");
    pub const SelectDocStart = action("composer::SelectDocStart");
    pub const SelectDocEnd = action("composer::SelectDocEnd");
    pub const WordLeft = action("composer::WordLeft");
    pub const WordRight = action("composer::WordRight");
    pub const SelectWordLeft = action("composer::SelectWordLeft");
    pub const SelectWordRight = action("composer::SelectWordRight");
    pub const DeleteWordLeft = action("composer::DeleteWordLeft");
    pub const DeleteWordRight = action("composer::DeleteWordRight");
    pub const DeleteToLineStart = action("composer::DeleteToLineStart");
    pub const DeleteToLineEnd = action("composer::DeleteToLineEnd");
    pub const Copy = action("composer::Copy");
    pub const Cut = action("composer::Cut");
    pub const Paste = action("composer::Paste");
    pub const Newline = action("composer::Newline");
    pub const MessageNewlineOrAccept = action("composer::MessageNewlineOrAccept");
    pub const ModifiedSubmit = action("composer::ModifiedSubmit");
    pub const Submit = action("composer::Submit");
    pub const Undo = action("composer::Undo");
    pub const Redo = action("composer::Redo");
    pub const MentionTab = action("composer::MentionTab");
    pub const ToggleDictation = action("composer::ToggleDictation");
    pub const OutdentList = action("composer::OutdentList");

    pub const all = .{
        Backspace,         Delete,                 Left,            Right,          Up,
        Down,              SelectLeft,             SelectRight,     SelectUp,       SelectDown,
        SelectAll,         Home,                   End,             SelectHome,     SelectEnd,
        DocStart,          DocEnd,                 SelectDocStart,  SelectDocEnd,   WordLeft,
        WordRight,         SelectWordLeft,         SelectWordRight, DeleteWordLeft, DeleteWordRight,
        DeleteToLineStart, DeleteToLineEnd,        Copy,            Cut,            Paste,
        Newline,           MessageNewlineOrAccept, ModifiedSubmit,  Submit,         Undo,
        Redo,              MentionTab,             ToggleDictation, OutdentList,
    };
};

/// `actions!(shell, [...])` + `JumpSession(usize)`.
pub const shell = struct {
    pub const SaveFile = action("shell::SaveFile");
    pub const RandomWallpaper = action("shell::RandomWallpaper");
    pub const ToggleSidebar = action("shell::ToggleSidebar");
    pub const ToggleChanges = action("shell::ToggleChanges");
    pub const ToggleFiles = action("shell::ToggleFiles");
    pub const AddSpacePalette = action("shell::AddSpacePalette");
    pub const ToggleCommandPalette = action("shell::ToggleCommandPalette");
    pub const OpenModelPicker = action("shell::OpenModelPicker");
    pub const NewSession = action("shell::NewSession");
    pub const OpenSettings = action("shell::OpenSettings");
    pub const NextSession = action("shell::NextSession");
    pub const PrevSession = action("shell::PrevSession");
    pub const ArchiveSession = action("shell::ArchiveSession");

    /// Open the session at `slot` (zero-based) of the sidebar's active list.
    pub const JumpSession = struct {
        pub const action_name = "shell::JumpSession";
        slot: usize = 0,
    };

    pub const all = .{
        SaveFile,        RandomWallpaper,      ToggleSidebar,   ToggleChanges, ToggleFiles,
        AddSpacePalette, ToggleCommandPalette, OpenModelPicker, NewSession,    OpenSettings,
        NextSession,     PrevSession,          ArchiveSession,  JumpSession,
    };
};

/// `actions!(terminal, [ToggleTerminal])`.
pub const terminal = struct {
    pub const ToggleTerminal = action("terminal::ToggleTerminal");
    pub const all = .{ToggleTerminal};
};

/// `actions!(browser, [...])`.
pub const browser = struct {
    pub const Reload = action("browser::Reload");
    pub const FocusAddress = action("browser::FocusAddress");
    pub const NewTab = action("browser::NewTab");
    pub const CloseTab = action("browser::CloseTab");
    pub const Back = action("browser::Back");
    pub const Forward = action("browser::Forward");
    pub const all = .{ Reload, FocusAddress, NewTab, CloseTab, Back, Forward };
};

/// `actions!(zeron, [...])` — the app menu verbs.
pub const zeron = struct {
    pub const About = action("zeron::About");
    pub const CheckForUpdates = action("zeron::CheckForUpdates");
    pub const Quit = action("zeron::Quit");
    pub const Hide = action("zeron::Hide");
    pub const HideOthers = action("zeron::HideOthers");
    pub const ShowAll = action("zeron::ShowAll");
    pub const Minimize = action("zeron::Minimize");
    pub const Zoom = action("zeron::Zoom");
    pub const CloseWindow = action("zeron::CloseWindow");
    pub const AppearanceSystem = action("zeron::AppearanceSystem");
    pub const AppearanceLight = action("zeron::AppearanceLight");
    pub const AppearanceDark = action("zeron::AppearanceDark");
    pub const all = .{
        About,    CheckForUpdates, Quit,        Hide,             HideOthers,      ShowAll,
        Minimize, Zoom,            CloseWindow, AppearanceSystem, AppearanceLight, AppearanceDark,
    };
};

/// Register every action type with the app's `ActionRegistry` (so keymaps
/// and the command palette can build them by name).
pub fn registerAll(app: *zpui.App) !void {
    inline for (.{ composer.all, shell.all, terminal.all, browser.all, zeron.all }) |group| {
        try app.actions.registerAll(group);
    }
}

test "action names mirror the Rust actions! groups" {
    const t = std.testing;
    try t.expectEqualStrings("composer::MessageNewlineOrAccept", composer.MessageNewlineOrAccept.action_name);
    try t.expectEqualStrings("shell::JumpSession", shell.JumpSession.action_name);
    try t.expectEqualStrings("terminal::ToggleTerminal", terminal.ToggleTerminal.action_name);
    try t.expectEqualStrings("browser::FocusAddress", browser.FocusAddress.action_name);
    try t.expectEqualStrings("zeron::AppearanceDark", zeron.AppearanceDark.action_name);
    try t.expectEqual(39, composer.all.len);
    try t.expectEqual(14, shell.all.len);
    try t.expectEqual(6, browser.all.len);
    try t.expectEqual(12, zeron.all.len);

    const app = try zpui.App.initTest(t.allocator);
    defer app.deinit();
    try registerAll(app);
    var built = try app.actions.build(t.allocator, "shell::JumpSession");
    defer built.deinit(t.allocator);
    try t.expect(built.is(shell.JumpSession));
}

test {
    _ = keymap;
}
