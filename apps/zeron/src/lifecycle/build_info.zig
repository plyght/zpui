//! Build-time facts for the lifecycle code (the `zeron_build` options module, added to
//! the app's root module by build.zig `addZeronLifecycle`).

const opts = @import("zeron_build");

/// The app version (`-Dzeron-version=`; `zeron --version` prints `zeron <version>`, which
/// the self-updater checks on staged binaries).
pub const version: []const u8 = opts.version;
/// The default release feed (`-Dzeron-releases-url=`; empty = updates off until
/// `ZERON_RELEASES_URL` is set).
pub const releases_url: []const u8 = opts.releases_url;
