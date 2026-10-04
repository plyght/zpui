//! File editor actions and default bindings — gpui-component's input
//! bindings (`base/state.rs` `init`: the `Input` context) under zpui's
//! `FileEditor` key context, plus the find bar (`FileEditorFind`) and
//! go-to-line (`FileEditorGoto`) contexts. `secondary-` is cmd on macOS and
//! ctrl elsewhere; word motions use alt on macOS and ctrl elsewhere.

const std = @import("std");
const builtin = @import("builtin");
const zpui = @import("zpui");
const zeron_actions = @import("zeron_actions");
const action = zpui.action;
const Spec = zpui.core.keymap.BindingSpec;

pub const context = "FileEditor";
pub const find_context = "FileEditorFind";
pub const goto_context = "FileEditorGoto";

pub const Backspace = action("file_editor::Backspace");
pub const Delete = action("file_editor::Delete");
pub const DeleteWordLeft = action("file_editor::DeleteToPreviousWordStart");
pub const DeleteWordRight = action("file_editor::DeleteToNextWordEnd");
pub const DeleteToLineStart = action("file_editor::DeleteToBeginningOfLine");
pub const DeleteToLineEnd = action("file_editor::DeleteToEndOfLine");
pub const Left = action("file_editor::MoveLeft");
pub const Right = action("file_editor::MoveRight");
pub const Up = action("file_editor::MoveUp");
pub const Down = action("file_editor::MoveDown");
pub const SelectLeft = action("file_editor::SelectLeft");
pub const SelectRight = action("file_editor::SelectRight");
pub const SelectUp = action("file_editor::SelectUp");
pub const SelectDown = action("file_editor::SelectDown");
pub const WordLeft = action("file_editor::MoveToPreviousWord");
pub const WordRight = action("file_editor::MoveToNextWord");
pub const SelectWordLeft = action("file_editor::SelectToPreviousWordStart");
pub const SelectWordRight = action("file_editor::SelectToNextWordEnd");
pub const Home = action("file_editor::MoveHome");
pub const End = action("file_editor::MoveEnd");
pub const SelectHome = action("file_editor::SelectToStartOfLine");
pub const SelectEnd = action("file_editor::SelectToEndOfLine");
pub const DocStart = action("file_editor::MoveToStart");
pub const DocEnd = action("file_editor::MoveToEnd");
pub const SelectDocStart = action("file_editor::SelectToStart");
pub const SelectDocEnd = action("file_editor::SelectToEnd");
pub const PageUp = action("file_editor::MovePageUp");
pub const PageDown = action("file_editor::MovePageDown");
pub const SelectPageUp = action("file_editor::SelectPageUp");
pub const SelectPageDown = action("file_editor::SelectPageDown");
pub const SelectAll = action("file_editor::SelectAll");
pub const Copy = action("file_editor::Copy");
pub const Cut = action("file_editor::Cut");
pub const Paste = action("file_editor::Paste");
pub const Undo = action("file_editor::Undo");
pub const Redo = action("file_editor::Redo");
pub const Enter = action("file_editor::Enter");
pub const IndentInline = action("file_editor::IndentInline");
pub const OutdentInline = action("file_editor::OutdentInline");
pub const Indent = action("file_editor::Indent");
pub const Outdent = action("file_editor::Outdent");
pub const Escape = action("file_editor::Escape");
pub const Save = action("file_editor::Save");
pub const Search = action("file_editor::Search");
pub const Replace = action("file_editor::Replace");
pub const FindNext = action("file_editor::FindNext");
pub const FindPrevious = action("file_editor::FindPrevious");
pub const CloseFind = action("file_editor::CloseFind");
pub const ToggleCaseSensitive = action("file_editor::ToggleCaseSensitive");
pub const ToggleWholeWord = action("file_editor::ToggleWholeWord");
pub const ReplaceNext = action("file_editor::ReplaceNext");
pub const ReplaceAll = action("file_editor::ReplaceAll");
pub const GoToLine = action("file_editor::GoToLine");
pub const ConfirmGoToLine = action("file_editor::ConfirmGoToLine");
pub const CloseGoToLine = action("file_editor::CloseGoToLine");
pub const ToggleSoftWrap = action("file_editor::ToggleSoftWrap");
pub const SelectLine = action("file_editor::SelectLine");

const mac = builtin.os.tag == .macos;
const C: ?[]const u8 = context;
const F: ?[]const u8 = find_context;
const G: ?[]const u8 = goto_context;
const word = if (mac) "alt" else "ctrl";
const composer = zeron_actions.composer;

const editor_bindings = [_]Spec{
    .init("backspace", Backspace{}, C),
    .init("shift-backspace", Backspace{}, C),
    .init("delete", Delete{}, C),
    .init("shift-delete", Delete{}, C),
    .init("secondary-backspace", DeleteToLineStart{}, C),
    .init("secondary-delete", DeleteToLineEnd{}, C),
    .init(word ++ "-backspace", DeleteWordLeft{}, C),
    .init(word ++ "-delete", DeleteWordRight{}, C),
    .init("escape", Escape{}, C),
    .init("up", Up{}, C),
    .init("down", Down{}, C),
    .init("left", Left{}, C),
    .init("right", Right{}, C),
    .init("pageup", PageUp{}, C),
    .init("pagedown", PageDown{}, C),
    .init("shift-pageup", SelectPageUp{}, C),
    .init("shift-pagedown", SelectPageDown{}, C),
    .init("tab", IndentInline{}, C),
    .init("shift-tab", OutdentInline{}, C),
    .init("secondary-]", Indent{}, C),
    .init("secondary-[", Outdent{}, C),
    .init("shift-left", SelectLeft{}, C),
    .init("shift-right", SelectRight{}, C),
    .init("shift-up", SelectUp{}, C),
    .init("shift-down", SelectDown{}, C),
    .init("home", Home{}, C),
    .init("end", End{}, C),
    .init("shift-home", SelectHome{}, C),
    .init("shift-end", SelectEnd{}, C),
    .init(word ++ "-left", WordLeft{}, C),
    .init(word ++ "-right", WordRight{}, C),
    .init("shift-" ++ word ++ "-left", SelectWordLeft{}, C),
    .init("shift-" ++ word ++ "-right", SelectWordRight{}, C),
    .init("secondary-a", SelectAll{}, C),
    .init("secondary-c", Copy{}, C),
    .init("secondary-x", Cut{}, C),
    .init("secondary-v", Paste{}, C),
    .init("secondary-z", Undo{}, C),
    .init("secondary-shift-z", Redo{}, C),
    .init("ctrl-y", Redo{}, C),
    .init("enter", Enter{}, C),
    .init("shift-enter", Enter{}, C),
    .init("secondary-home", DocStart{}, C),
    .init("secondary-end", DocEnd{}, C),
    .init("secondary-shift-home", SelectDocStart{}, C),
    .init("secondary-shift-end", SelectDocEnd{}, C),
    .init("secondary-s", Save{}, C),
    .init("secondary-f", Search{}, C),
    .init(if (mac) "cmd-alt-f" else "ctrl-h", Replace{}, C),
    .init("f3", FindNext{}, C),
    .init("shift-f3", FindPrevious{}, C),
    .init("secondary-g", FindNext{}, C),
    .init("secondary-shift-g", FindPrevious{}, C),
    .init(if (mac) "ctrl-g" else "ctrl-l", GoToLine{}, C),
    .init("alt-z", ToggleSoftWrap{}, C),
} ++ (if (mac) [_]Spec{
    .init("cmd-left", Home{}, C),
    .init("cmd-right", End{}, C),
    .init("cmd-up", DocStart{}, C),
    .init("cmd-down", DocEnd{}, C),
    .init("cmd-shift-left", SelectHome{}, C),
    .init("cmd-shift-right", SelectEnd{}, C),
    .init("cmd-shift-up", SelectDocStart{}, C),
    .init("cmd-shift-down", SelectDocEnd{}, C),
    .init("ctrl-a", Home{}, C),
    .init("ctrl-e", End{}, C),
} else [_]Spec{});

/// The find and go-to-line fields use the `PaletteSearch` input context
/// (text-editing keys only), so their plain arrows / Enter / Escape bubble here.
const find_bindings = [_]Spec{
    .init("enter", FindNext{}, F),
    .init("shift-enter", FindPrevious{}, F),
    .init("f3", FindNext{}, F),
    .init("shift-f3", FindPrevious{}, F),
    .init("escape", CloseFind{}, F),
    .init("left", composer.Left{}, F),
    .init("right", composer.Right{}, F),
    .init("alt-c", ToggleCaseSensitive{}, F),
    .init("alt-w", ToggleWholeWord{}, F),
    .init("secondary-f", Search{}, F),
    .init(if (mac) "cmd-alt-f" else "ctrl-h", Replace{}, F),
    .init("enter", ReplaceNext{}, "replace_input"),
    .init("secondary-enter", ReplaceAll{}, "replace_input"),
    .init("enter", ConfirmGoToLine{}, G),
    .init("escape", CloseGoToLine{}, G),
    .init("left", composer.Left{}, G),
    .init("right", composer.Right{}, G),
};

/// Install the editor's default bindings (idempotent per app).
pub fn bindDefaults(app: *zpui.App) !void {
    try app.bindKeys(&editor_bindings);
    try app.bindKeys(&find_bindings);
}
