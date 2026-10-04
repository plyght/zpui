//! Parakeet TDT v3 on ONNX Runtime — zeron `Recognizer` (lib.rs) over a
//! port of parakeet-rs 0.3.8's TDT path: `ParakeetTDT::transcribe_samples`
//! (features → encoder → greedy TDT decode with the decoder/joint graph →
//! SentencePiece detokenisation, `TimestampMode::Tokens`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ort = @import("ort.zig");
const features = @import("features.zig");
const resample = @import("resample.zig");
const model = @import("model.zig");

pub const max_seconds = 60;

/// Rust error strings, surfaced verbatim in the composer.
pub const msg = struct {
    pub const damaged = "Model is damaged. Remove it in Settings and download again.";
    pub const load = "Could not load Parakeet v3";
    pub const rate = "Unsupported microphone sample rate";
    pub const too_long = "Recording exceeds one minute";
    pub const transcribe = "Could not transcribe this recording";
};

pub const LoadError = error{ RuntimeUnavailable, Damaged, LoadFailed, OutOfMemory };
pub const TranscribeError = error{ UnsupportedSampleRate, TooLong, TranscribeFailed, OutOfMemory };

pub const Vocabulary = struct {
    tokens: [][]u8,

    /// parakeet-rs `Vocabulary::from_file` over the file's bytes: `token id`
    /// per line, ids may be sparse (holes stay empty).
    pub fn parse(gpa: Allocator, bytes: []const u8) !Vocabulary {
        var list: std.ArrayList([]u8) = .empty;
        errdefer {
            for (list.items) |t| gpa.free(t);
            list.deinit(gpa);
        }
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            const id = std.fmt.parseInt(usize, line[sp + 1 ..], 10) catch return error.InvalidVocab;
            while (list.items.len <= id) try list.append(gpa, try gpa.alloc(u8, 0));
            gpa.free(list.items[id]);
            list.items[id] = try gpa.dupe(u8, line[0..sp]);
        }
        return .{ .tokens = try list.toOwnedSlice(gpa) };
    }

    pub fn deinit(self: Vocabulary, gpa: Allocator) void {
        for (self.tokens) |t| gpa.free(t);
        gpa.free(self.tokens);
    }
};

/// Unicode `char::is_alphabetic` for the scripts Parakeet v3 writes (Latin,
/// Greek, Cyrillic and their extensions); used only by the digit-spacing
/// heuristic.
fn isAlphabetic(cp: u21) bool {
    if (cp < 0x80) return std.ascii.isAlphabetic(@intCast(cp));
    if (cp == 0xAA or cp == 0xB5 or cp == 0xBA) return true;
    if (cp >= 0xC0 and cp <= 0x24F) return cp != 0xD7 and cp != 0xF7;
    if (cp >= 0x250 and cp <= 0x2AF) return true; // IPA
    if (cp >= 0x370 and cp <= 0x3FF) return cp != 0x37E and cp != 0x387 and cp != 0x375;
    if (cp >= 0x400 and cp <= 0x52F) return !(cp >= 0x482 and cp <= 0x489);
    if (cp >= 0x1E00 and cp <= 0x1FFF) return true;
    return false;
}

/// parakeet-rs `ParakeetTDTDecoder::decode_with_timestamps` +
/// `rebuild_text(_, Tokens)`: token ids → trimmed text.
pub fn detokenize(gpa: Allocator, vocab: *const Vocabulary, tokens: []const usize) Allocator.Error![]u8 {
    var full: std.ArrayList(u8) = .empty;
    defer full.deinit(gpa);
    var display: std.ArrayList(u8) = .empty;
    defer display.deinit(gpa);
    for (tokens) |id| {
        if (id >= vocab.tokens.len) continue;
        const token = vocab.tokens[id];
        // `▁` (U+2581) marks a word start.
        display.clearRetainingCapacity();
        var i: usize = 0;
        while (i < token.len) {
            if (std.mem.startsWith(u8, token[i..], "\u{2581}")) {
                try display.append(gpa, ' ');
                i += 3;
            } else {
                try display.append(gpa, token[i]);
                i += 1;
            }
        }
        // SentencePiece digits lack the ▁ prefix ("at60"): space them after
        // a word, but not after a single uppercase letter ("A4").
        if (full.items.len > 0 and (display.items.len == 0 or display.items[0] != ' ') and allDigits(display.items)) {
            var trailing: usize = 0;
            var last: ?u21 = null;
            var j = full.items.len;
            while (j > 0) {
                var start = j - 1;
                while (start > 0 and (full.items[start] & 0xC0) == 0x80) start -= 1;
                const cp = std.unicode.utf8Decode(full.items[start..j]) catch 0xFFFD;
                if (last == null) last = cp;
                if (!isAlphabetic(cp)) break;
                trailing += 1;
                j = start;
            }
            const article_a = trailing == 1 and last == 'a';
            if (trailing > 1 or article_a) try display.insert(gpa, 0, ' ');
        }
        const special = token.len >= 2 and token[0] == '<' and token[token.len - 1] == '>' and !std.mem.eql(u8, token, "<unk>");
        if (!special) try full.appendSlice(gpa, display.items);
    }
    return gpa.dupe(u8, std.mem.trim(u8, full.items, " \t\r\n"));
}

/// Rust `chars().all(|c| c.is_ascii_digit())` (true for the empty string).
fn allDigits(s: []const u8) bool {
    for (s) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}

pub const Recognizer = struct {
    gpa: Allocator,
    api: *const ort.Api,
    encoder: *ort.Session,
    joint: *ort.Session,
    vocab: Vocabulary,
    extractor: *features.Extractor,

    /// Rust `Recognizer::load`: verify every artifact's digest, then build
    /// both sessions.
    pub fn load(gpa: Allocator, io: Io, dir: []const u8) LoadError!Recognizer {
        if (!model.verify(io, dir)) return error.Damaged;
        const api = ort.api() orelse return error.RuntimeUnavailable;
        var d = Io.Dir.cwd().openDir(io, dir, .{}) catch return error.LoadFailed;
        defer d.close(io);
        const vocab_bytes = d.readFileAlloc(io, "vocab.txt", gpa, .limited(16 * 1024 * 1024)) catch return error.LoadFailed;
        defer gpa.free(vocab_bytes);
        var vocab = Vocabulary.parse(gpa, vocab_bytes) catch return error.LoadFailed;
        errdefer vocab.deinit(gpa);
        const enc_path = findModel(gpa, io, d, dir, &.{ "encoder-model.onnx", "encoder.onnx", "encoder-model.int8.onnx" }) catch return error.LoadFailed;
        defer gpa.free(enc_path);
        const joint_path = findModel(gpa, io, d, dir, &.{ "decoder_joint-model.onnx", "decoder_joint-model.int8.onnx", "decoder_joint.onnx", "decoder-model.onnx" }) catch return error.LoadFailed;
        defer gpa.free(joint_path);
        const encoder = api.createSession(enc_path) catch return error.LoadFailed;
        errdefer api.releaseSession(encoder);
        const joint = api.createSession(joint_path) catch return error.LoadFailed;
        errdefer api.releaseSession(joint);
        const extractor = try features.Extractor.init(gpa);
        return .{ .gpa = gpa, .api = api, .encoder = encoder, .joint = joint, .vocab = vocab, .extractor = extractor };
    }

    fn findModel(gpa: Allocator, io: Io, d: Io.Dir, dir: []const u8, candidates: []const []const u8) ![:0]u8 {
        for (candidates) |name| {
            _ = d.statFile(io, name, .{}) catch continue;
            return std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ dir, name }, 0);
        }
        return error.FileNotFound;
    }

    pub fn deinit(self: *Recognizer) void {
        self.api.releaseSession(self.encoder);
        self.api.releaseSession(self.joint);
        self.vocab.deinit(self.gpa);
        self.extractor.deinit();
    }

    /// Rust `Recognizer::transcribe`. Takes ownership of `samples`; the
    /// returned text is owned by the caller.
    pub fn transcribe(self: *Recognizer, samples: []f32, rate: u32) TranscribeError![]u8 {
        var owned = samples;
        defer self.gpa.free(owned);
        if (rate < 8_000 or rate > 192_000) return error.UnsupportedSampleRate;
        if (samples.len > @as(usize, rate) * max_seconds) return error.TooLong;
        var silent = true;
        for (samples) |s| if (@abs(s) >= 0.0001) {
            silent = false;
            break;
        };
        if (samples.len < rate / 5 or silent) return self.gpa.dupe(u8, "");
        const converted = resample.forModel(self.gpa, owned, rate) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.UnsupportedSampleRate => return error.UnsupportedSampleRate,
        };
        owned = converted;
        return self.transcribe16k(converted) catch |e| switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.TranscribeFailed,
        };
    }

    /// `ParakeetTDT::transcribe_samples` at 16 kHz.
    pub fn transcribe16k(self: *Recognizer, audio: []const f32) ![]u8 {
        const gpa = self.gpa;
        const feats = try self.extractor.extract(gpa, audio);
        defer feats.deinit(gpa);
        const tokens = try self.forward(feats);
        defer gpa.free(tokens);
        return detokenize(gpa, &self.vocab, tokens);
    }

    /// `ParakeetTDTModel::forward`: encoder, then frame-by-frame greedy TDT
    /// decoding. Returns the emitted token ids.
    pub fn forward(self: *Recognizer, feats: features.Features) ![]usize {
        const gpa = self.gpa;
        const api = self.api;
        const t_in = feats.frames;
        // The encoder takes (batch, features, time).
        const input = try gpa.alloc(f32, features.n_mels * t_in);
        defer gpa.free(input);
        for (0..t_in) |t| for (0..features.n_mels) |m| {
            input[m * t_in + t] = feats.data[t * features.n_mels + m];
        };
        var length = [_]i64{@intCast(t_in)};
        const in_value = try api.tensor(f32, input, &.{ 1, features.n_mels, @intCast(t_in) });
        defer api.releaseValue(in_value);
        const len_value = try api.tensor(i64, &length, &.{1});
        defer api.releaseValue(len_value);
        var enc_out: [2]?*ort.Value = undefined;
        try api.run(self.encoder, &.{ "audio_signal", "length" }, &.{ in_value, len_value }, &.{ "outputs", "encoded_lengths" }, &enc_out);
        defer for (enc_out) |v| api.releaseValue(v);
        var dims_buf: [8]i64 = undefined;
        const dims = try api.dims(enc_out[0].?, &dims_buf);
        if (dims.len != 3) return error.BadEncoderOutput;
        const dim: usize = @intCast(dims[1]);
        const steps: usize = @intCast(dims[2]);
        const enc = try api.data(f32, enc_out[0].?);

        const vocab_size = self.vocab.tokens.len;
        const blank = vocab_size - 1;
        const max_tokens_per_step = 10;
        var state_h: [1280]f32 = @splat(0);
        var state_c: [1280]f32 = @splat(0);
        const frame = try gpa.alloc(f32, dim);
        defer gpa.free(frame);
        var tokens: std.ArrayList(usize) = .empty;
        errdefer tokens.deinit(gpa);

        var t: usize = 0;
        var emitted: usize = 0;
        var last: [1]i32 = .{@intCast(blank)};
        var target_len = [_]i32{1};
        while (t < steps) {
            for (0..dim) |d| frame[d] = enc[d * steps + t];
            const v_frame = try api.tensor(f32, frame, &.{ 1, @intCast(dim), 1 });
            defer api.releaseValue(v_frame);
            const v_targets = try api.tensor(i32, &last, &.{ 1, 1 });
            defer api.releaseValue(v_targets);
            const v_tlen = try api.tensor(i32, &target_len, &.{1});
            defer api.releaseValue(v_tlen);
            const v_h = try api.tensor(f32, &state_h, &.{ 2, 1, 640 });
            defer api.releaseValue(v_h);
            const v_c = try api.tensor(f32, &state_c, &.{ 2, 1, 640 });
            defer api.releaseValue(v_c);
            var outs: [3]?*ort.Value = undefined;
            try api.run(
                self.joint,
                &.{ "encoder_outputs", "targets", "target_length", "input_states_1", "input_states_2" },
                &.{ v_frame, v_targets, v_tlen, v_h, v_c },
                &.{ "outputs", "output_states_1", "output_states_2" },
                &outs,
            );
            defer for (outs) |v| api.releaseValue(v);
            const logits = try api.data(f32, outs[0].?);
            const n_vocab = @min(vocab_size, logits.len);
            // `Iterator::max_by` keeps the LAST of equal maxima.
            var token: usize = blank;
            if (n_vocab > 0) {
                token = 0;
                for (logits[0..n_vocab], 0..) |x, i| if (x >= logits[token]) {
                    token = i;
                };
            }
            var duration: usize = 0;
            const dur = logits[n_vocab..];
            if (dur.len > 0) {
                for (dur, 0..) |x, i| if (x >= dur[duration]) {
                    duration = i;
                };
            }
            if (token != blank) {
                const h = try api.data(f32, outs[1].?);
                const cc = try api.data(f32, outs[2].?);
                if (h.len == state_h.len) @memcpy(&state_h, h);
                if (cc.len == state_c.len) @memcpy(&state_c, cc);
                try tokens.append(gpa, token);
                last[0] = @intCast(token);
                emitted += 1;
            }
            if (duration > 0) {
                t += duration;
                emitted = 0;
            } else if (token == blank or emitted >= max_tokens_per_step) {
                t += 1;
                emitted = 0;
            }
        }
        return tokens.toOwnedSlice(gpa);
    }
};

test "detokenize spaces digits like parakeet-rs decoder_tdt tests" {
    const gpa = std.testing.allocator;
    const cases = .{
        .{ &[_][]const u8{ "\u{2581}like", "1", "0", "0" }, "like 100" },
        .{ &[_][]const u8{ "\u{2581}a", "2", "4" }, "a 24" },
        .{ &[_][]const u8{ "\u{2581}A", "4" }, "A4" },
        .{ &[_][]const u8{ "$", "1", "0", "0" }, "$100" },
        .{ &[_][]const u8{ "\u{2581}In", "2", "0", "2", "1" }, "In 2021" },
        .{ &[_][]const u8{ "\u{2581}Hello", "<unk>", "<blk>", "," }, "Hello<unk>," },
    };
    inline for (cases) |case| {
        var toks: [8][]u8 = undefined;
        for (case[0], 0..) |t, i| toks[i] = @constCast(t);
        const vocab: Vocabulary = .{ .tokens = toks[0..case[0].len] };
        var ids: [8]usize = undefined;
        for (0..case[0].len) |i| ids[i] = i;
        const text = try detokenize(gpa, &vocab, ids[0..case[0].len]);
        defer gpa.free(text);
        try std.testing.expectEqualStrings(case[1], text);
    }
}

test "vocab parses sparse ids" {
    const gpa = std.testing.allocator;
    const v = try Vocabulary.parse(gpa, "<unk> 0\n\u{2581}a 2\r\n<blk> 3\n");
    defer v.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 4), v.tokens.len);
    try std.testing.expectEqualStrings("", v.tokens[1]);
    try std.testing.expectEqualStrings("<blk>", v.tokens[3]);
}
