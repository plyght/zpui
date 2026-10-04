//! Wire types the model needs beyond `zeron_engine.protocol` (same
//! conventions: exact camelCase/kebab-case serde names, `Option` → `?T`).

const std = @import("std");
const engine_mod = @import("zeron_engine");
const json_util = engine_mod.json_util;
const protocol = engine_mod.protocol;

/// `zeron_proto::TransferProgress` (`WatchTransfers` items are `[]TransferProgress`).
pub const TransferProgress = struct {
    uploadId: []const u8,
    fileName: []const u8,
    done: u64,
    total: u64,
};

pub const HarnessUpdatePolicy = enum {
    notify,
    @"auto-when-idle",
    off,
    unknown,

    const Impl = json_util.OpenEnum(@This(), .unknown);
    pub const jsonParse = Impl.jsonParse;
    pub const jsonParseFromValue = Impl.jsonParseFromValue;
};

pub const HarnessInstallSource = enum {
    npm,
    homebrew,
    cargo,
    vendor,
    @"managed-by-zeron",
    unknown,

    const Impl = json_util.OpenEnum(@This(), .unknown);
    pub const jsonParse = Impl.jsonParse;
    pub const jsonParseFromValue = Impl.jsonParseFromValue;
};

pub const HarnessUpdatePhase = enum {
    dormant,
    checking,
    current,
    available,
    @"waiting-for-idle",
    preparing,
    downloading,
    installing,
    verifying,
    updated,
    @"manual-action-required",
    failed,
};

pub const HarnessUpdateProgress = struct {
    completedBytes: ?u64 = null,
    totalBytes: ?u64 = null,
    message: ?[]const u8 = null,
};

pub const HarnessUpdateFailure = struct {
    message: []const u8,
    retryable: bool = false,
};

/// One row of `WatchHarnessUpdates` (items are `[]HarnessUpdateStatus`).
pub const HarnessUpdateStatus = struct {
    harness: protocol.HarnessId,
    installedVersion: ?[]const u8 = null,
    latestVersion: ?[]const u8 = null,
    channel: ?[]const u8 = null,
    source: HarnessInstallSource = .unknown,
    policy: HarnessUpdatePolicy = .notify,
    phase: HarnessUpdatePhase,
    progress: ?HarnessUpdateProgress = null,
    checkedAt: ?i64 = null,
    @"error": ?HarnessUpdateFailure = null,
    canApply: bool = false,
    manualCommand: ?[]const u8 = null,

    /// Home notices describe discovered releases or an update in progress.
    pub fn showUpdateNotice(self: HarnessUpdateStatus) bool {
        return switch (self.phase) {
            .available, .@"waiting-for-idle", .preparing, .downloading, .installing, .verifying, .updated, .failed => true,
            else => false,
        };
    }
};

/// The engine's app `UpdateStatus` stream item (`zeron_update::UpdateStatus`).
pub const UpdateStatus = struct {
    currentVersion: []const u8,
    latestVersion: ?[]const u8 = null,
    updateAvailable: bool = false,
    /// Epoch ms of the last successful check.
    checkedAt: ?i64 = null,
    @"error": ?[]const u8 = null,
};

/// One org membership (tolerant mirror of `ListOrgs` → `{orgs: [...]}`).
pub const OrgRow = struct {
    organizationId: []const u8,
    name: []const u8,
};
