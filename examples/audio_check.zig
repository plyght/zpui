//! Compile-only check of zpui.audio for cross builds without a macOS SDK:
//! `zig build audio-check -Dtarget=aarch64-macos` emits zig-out/audio-check.o
//! (no framework linking). Taking the demo's `main` address forces analysis
//! and codegen of the CoreAudio output backend.

const std = @import("std");
const za = @import("zpui_audio");
const demo = @import("audio_demo.zig");

export fn zpui_audio_check() callconv(.c) usize {
    var sum: usize = @intFromPtr(&demo.main);
    sum +%= @intFromPtr(&za.Audio.init);
    return sum;
}
