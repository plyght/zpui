//! zeron diff support: unified patch parsing (`zeron_ui::changes`), the
//! tool-edit line diff (`transcript::diff_to_file`), and a port of the
//! `similar` crate's Myers/Patience text diffing incl. word-level inline
//! emphasis.

const std = @import("std");

pub const patch = @import("patch.zig");
pub const similar = @import("similar.zig");

pub const LineKind = patch.LineKind;
pub const DiffLine = patch.DiffLine;
pub const Hunk = patch.Hunk;
pub const FileStatus = patch.FileStatus;
pub const FileDiff = patch.FileDiff;
pub const PatchSet = patch.PatchSet;
pub const LinePair = patch.LinePair;
pub const parsePatch = patch.parsePatch;
pub const fileNotices = patch.fileNotices;
pub const truncateFileLines = patch.truncateFileLines;
pub const splitPairs = patch.splitPairs;
pub const splitPairsUpto = patch.splitPairsUpto;
pub const diffToFile = patch.diffToFile;

pub const TextDiff = similar.TextDiff;
pub const DiffOp = similar.DiffOp;
pub const Change = similar.Change;
pub const InlineChange = similar.InlineChange;
pub const captureDiff = similar.captureDiff;
pub const groupDiffOps = similar.groupDiffOps;

test {
    std.testing.refAllDecls(@This());
    _ = patch;
    _ = similar;
    _ = @import("parity_test.zig");
}
