//! Git history wire types (zeron `crates/proto/src/entities.rs`
//! `GitHistoryRefKind`, `GitHistoryRef`, `GitHistoryCommit`,
//! `GitHistoryComparison`, `GitHistoryPage`) and request params for
//! `ListGitHistory`, `SearchGitHistory`, `FetchAll`. Kept here (additive to
//! `zeron_engine.protocol`, which does not carry them yet).

pub const GitHistoryRefKind = enum { branch, remote, tag };

pub const GitHistoryRef = struct {
    kind: GitHistoryRefKind,
    label: []const u8,
};

pub const GitHistoryCommit = struct {
    sha: []const u8,
    parentShas: []const []const u8 = &.{},
    subject: []const u8 = "",
    authorName: []const u8 = "",
    authorEmail: []const u8 = "",
    authoredAt: []const u8 = "",
    refs: []const GitHistoryRef = &.{},
};

pub const GitHistoryComparison = struct {
    base: []const u8,
    ahead: usize,
    behind: usize,
};

pub const GitHistoryPage = struct {
    commits: []const GitHistoryCommit = &.{},
    branchTips: []const GitHistoryCommit = &.{},
    headSha: ?[]const u8 = null,
    nextCursor: ?usize = null,
    totalCount: ?usize = null,
    headCommitCount: ?usize = null,
    comparison: ?GitHistoryComparison = null,
};

pub const params = struct {
    pub const ListGitHistory = struct {
        cwd: []const u8,
        cursor: usize = 0,
        limit: usize = 100,
        targetDeviceId: ?[]const u8 = null,
    };
    pub const SearchGitHistory = struct {
        cwd: []const u8,
        query: []const u8,
        cursor: usize = 0,
        limit: usize = 100,
        targetDeviceId: ?[]const u8 = null,
    };
    pub const FetchAll = struct {
        repoPath: []const u8,
        targetDeviceId: ?[]const u8 = null,
    };
};
