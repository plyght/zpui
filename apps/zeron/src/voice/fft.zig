//! Small FFT for the voice pipeline (stands in for rustfft/realfft, which
//! rubato's resampler and parakeet-rs's spectrogram use). Any length: mixed
//! radix (every factor <= 64, generic butterflies) and Bluestein for lengths
//! with a larger prime factor. Twiddles are computed in f64 and stored as
//! f32; arithmetic is f32 like rustfft, so results agree to float rounding.
//! Unnormalised in both directions (realfft's convention).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Complex = extern struct {
    re: f32 = 0,
    im: f32 = 0,

    pub inline fn add(a: Complex, b: Complex) Complex {
        return .{ .re = a.re + b.re, .im = a.im + b.im };
    }
    pub inline fn sub(a: Complex, b: Complex) Complex {
        return .{ .re = a.re - b.re, .im = a.im - b.im };
    }
    pub inline fn mul(a: Complex, b: Complex) Complex {
        return .{ .re = a.re * b.re - a.im * b.im, .im = a.re * b.im + a.im * b.re };
    }
    pub inline fn conj(a: Complex) Complex {
        return .{ .re = a.re, .im = -a.im };
    }
    pub inline fn normSqr(a: Complex) f32 {
        return a.re * a.re + a.im * a.im;
    }
};

const max_radix = 64;

/// A forward complex FFT plan of length `n`.
pub const Plan = struct {
    gpa: Allocator,
    n: usize,
    /// Mixed-radix factors (empty when Bluestein is used).
    factors: []usize = &.{},
    /// exp(-2πi j / n), j < n (mixed radix only).
    twiddles: []Complex = &.{},
    scratch: []Complex = &.{},
    bluestein: ?*Bluestein = null,

    pub fn init(gpa: Allocator, n: usize) Allocator.Error!Plan {
        std.debug.assert(n > 0);
        var factors: std.ArrayList(usize) = .empty;
        errdefer factors.deinit(gpa);
        var rest = n;
        var large_prime = false;
        while (rest % 4 == 0) : (rest /= 4) try factors.append(gpa, 4);
        while (rest % 2 == 0) : (rest /= 2) try factors.append(gpa, 2);
        var f: usize = 3;
        while (rest > 1) {
            if (f * f > rest) {
                if (rest > max_radix) large_prime = true;
                try factors.append(gpa, rest);
                break;
            }
            while (rest % f == 0) : (rest /= f) {
                if (f > max_radix) large_prime = true;
                try factors.append(gpa, f);
            }
            f += 2;
        }
        if (large_prime) {
            factors.deinit(gpa);
            const b = try gpa.create(Bluestein);
            errdefer gpa.destroy(b);
            b.* = try Bluestein.init(gpa, n);
            return .{ .gpa = gpa, .n = n, .bluestein = b };
        }
        const tw = try gpa.alloc(Complex, n);
        errdefer gpa.free(tw);
        for (tw, 0..) |*t, j| t.* = expNeg(j, n);
        const scratch = try gpa.alloc(Complex, n);
        return .{ .gpa = gpa, .n = n, .factors = try factors.toOwnedSlice(gpa), .twiddles = tw, .scratch = scratch };
    }

    pub fn deinit(self: *Plan) void {
        if (self.bluestein) |b| {
            b.deinit();
            self.gpa.destroy(b);
        }
        self.gpa.free(self.factors);
        self.gpa.free(self.twiddles);
        self.gpa.free(self.scratch);
    }

    /// In-place forward transform of `data` (length `n`).
    pub fn forward(self: *Plan, data: []Complex) void {
        std.debug.assert(data.len == self.n);
        if (self.bluestein) |b| return b.forward(data);
        if (self.n == 1) return;
        @memcpy(self.scratch, data);
        self.recurse(self.scratch.ptr, 1, data.ptr, self.n, self.factors);
    }

    /// In-place inverse (unnormalised): conj(FFT(conj(x))).
    pub fn inverse(self: *Plan, data: []Complex) void {
        for (data) |*d| d.im = -d.im;
        self.forward(data);
        for (data) |*d| d.im = -d.im;
    }

    fn recurse(self: *Plan, in: [*]const Complex, stride: usize, out: [*]Complex, n: usize, factors: []const usize) void {
        if (n == 1) {
            out[0] = in[0];
            return;
        }
        const p = factors[0];
        const m = n / p;
        for (0..p) |q| self.recurse(in + q * stride, stride * p, out + q * m, m, factors[1..]);
        const step = self.n / n; // twiddle index scale at this level
        var tmp: [max_radix]Complex = undefined;
        for (0..m) |k| {
            for (0..p) |q| {
                const idx = (q * k * step) % self.n;
                tmp[q] = if (q == 0) out[k] else out[q * m + k].mul(self.twiddles[idx]);
            }
            switch (p) {
                2 => {
                    out[k] = tmp[0].add(tmp[1]);
                    out[k + m] = tmp[0].sub(tmp[1]);
                },
                4 => {
                    // -i rotation for the forward transform.
                    const a = tmp[0].add(tmp[2]);
                    const b = tmp[0].sub(tmp[2]);
                    const c = tmp[1].add(tmp[3]);
                    const d = tmp[1].sub(tmp[3]);
                    const d_rot: Complex = .{ .re = d.im, .im = -d.re };
                    out[k] = a.add(c);
                    out[k + m] = b.add(d_rot);
                    out[k + 2 * m] = a.sub(c);
                    out[k + 3 * m] = b.sub(d_rot);
                },
                else => {
                    // Generic DFT across the p sub-results: w_p^(q*s).
                    const pstep = self.n / p;
                    for (0..p) |s| {
                        var acc = tmp[0];
                        for (1..p) |q| acc = acc.add(tmp[q].mul(self.twiddles[((q * s) % p) * pstep]));
                        out[k + s * m] = acc;
                    }
                },
            }
        }
    }
};

fn expNeg(j: usize, n: usize) Complex {
    const a = -2.0 * std.math.pi * @as(f64, @floatFromInt(j)) / @as(f64, @floatFromInt(n));
    return .{ .re = @floatCast(@cos(a)), .im = @floatCast(@sin(a)) };
}

/// Bluestein's chirp-z for lengths with a prime factor above `max_radix`.
const Bluestein = struct {
    gpa: Allocator,
    n: usize,
    inner: Plan,
    chirp: []Complex,
    kernel: []Complex,
    work: []Complex,

    fn init(gpa: Allocator, n: usize) Allocator.Error!Bluestein {
        var m: usize = 1;
        while (m < 2 * n - 1) m <<= 1;
        var inner = try Plan.init(gpa, m);
        errdefer inner.deinit();
        const chirp = try gpa.alloc(Complex, n);
        errdefer gpa.free(chirp);
        for (chirp, 0..) |*c, k| {
            // exp(-πi k²/n), with k² reduced mod 2n in integers for precision.
            const k2 = (@as(u128, k) * k) % (2 * @as(u128, n));
            const a = -std.math.pi * @as(f64, @floatFromInt(k2)) / @as(f64, @floatFromInt(n));
            c.* = .{ .re = @floatCast(@cos(a)), .im = @floatCast(@sin(a)) };
        }
        const kernel = try gpa.alloc(Complex, m);
        errdefer gpa.free(kernel);
        @memset(kernel, .{});
        kernel[0] = chirp[0].conj();
        for (1..n) |k| {
            kernel[k] = chirp[k].conj();
            kernel[m - k] = chirp[k].conj();
        }
        inner.forward(kernel);
        const work = try gpa.alloc(Complex, m);
        return .{ .gpa = gpa, .n = n, .inner = inner, .chirp = chirp, .kernel = kernel, .work = work };
    }

    fn deinit(self: *Bluestein) void {
        self.inner.deinit();
        self.gpa.free(self.chirp);
        self.gpa.free(self.kernel);
        self.gpa.free(self.work);
    }

    fn forward(self: *Bluestein, data: []Complex) void {
        @memset(self.work, .{});
        for (0..self.n) |k| self.work[k] = data[k].mul(self.chirp[k]);
        self.inner.forward(self.work);
        for (self.work, self.kernel) |*w, kk| w.* = w.mul(kk);
        self.inner.inverse(self.work);
        const scale = 1.0 / @as(f32, @floatFromInt(self.work.len));
        for (0..self.n) |k| {
            const v: Complex = .{ .re = self.work[k].re * scale, .im = self.work[k].im * scale };
            data[k] = v.mul(self.chirp[k]);
        }
    }
};

/// Real-input FFT of length `n` (realfft `RealToComplex` / `ComplexToReal`).
pub const RealPlan = struct {
    plan: Plan,
    buf: []Complex,

    pub fn init(gpa: Allocator, n: usize) Allocator.Error!RealPlan {
        var plan = try Plan.init(gpa, n);
        errdefer plan.deinit();
        return .{ .plan = plan, .buf = try gpa.alloc(Complex, n) };
    }

    pub fn deinit(self: *RealPlan) void {
        self.plan.gpa.free(self.buf);
        self.plan.deinit();
    }

    pub fn len(self: *const RealPlan) usize {
        return self.plan.n;
    }

    /// `input` (n reals) → `output` (n/2 + 1 bins).
    pub fn forward(self: *RealPlan, input: []const f32, output: []Complex) void {
        const n = self.plan.n;
        std.debug.assert(input.len == n and output.len == n / 2 + 1);
        for (self.buf, input) |*b, x| b.* = .{ .re = x, .im = 0 };
        self.plan.forward(self.buf);
        @memcpy(output, self.buf[0 .. n / 2 + 1]);
        output[0].im = 0;
        if (n % 2 == 0) output[n / 2].im = 0;
    }

    /// `input` (n/2 + 1 bins, Hermitian half) → `output` (n reals),
    /// unnormalised. The imaginary parts of DC (and Nyquist for even n) are
    /// ignored, as realfft does.
    pub fn inverse(self: *RealPlan, input: []const Complex, output: []f32) void {
        const n = self.plan.n;
        std.debug.assert(input.len == n / 2 + 1 and output.len == n);
        self.buf[0] = .{ .re = input[0].re, .im = 0 };
        for (1..n) |k| {
            self.buf[k] = if (k <= n / 2) input[k] else input[n - k].conj();
        }
        if (n % 2 == 0) self.buf[n / 2].im = 0;
        self.plan.inverse(self.buf);
        for (output, self.buf) |*o, b| o.* = b.re;
    }
};

test "fft matches a direct DFT for mixed, prime and Bluestein lengths" {
    const gpa = std.testing.allocator;
    for ([_]usize{ 1, 2, 8, 12, 30, 49, 512, 2052, 2646, 2 * 67, 2 * 4409 }) |n| {
        var plan = try Plan.init(gpa, n);
        defer plan.deinit();
        const x = try gpa.alloc(Complex, n);
        defer gpa.free(x);
        var state: u32 = @intCast(n);
        for (x) |*v| {
            state = state *% 1664525 +% 1013904223;
            v.* = .{ .re = @as(f32, @floatFromInt(state >> 8)) / 16777216.0 - 0.5, .im = @as(f32, @floatFromInt(state & 0xff)) / 256.0 - 0.5 };
        }
        const y = try gpa.dupe(Complex, x);
        defer gpa.free(y);
        plan.forward(y);
        // Spot-check bins against an f64 DFT.
        var k: usize = 0;
        while (k < n) : (k += @max(1, n / 7)) {
            var re: f64 = 0;
            var im: f64 = 0;
            for (x, 0..) |v, j| {
                const a = -2.0 * std.math.pi * @as(f64, @floatFromInt((j * k) % n)) / @as(f64, @floatFromInt(n));
                re += v.re * @cos(a) - v.im * @sin(a);
                im += v.re * @sin(a) + v.im * @cos(a);
            }
            const tol = 2e-4 * @sqrt(@as(f64, @floatFromInt(n)));
            try std.testing.expectApproxEqAbs(re, y[k].re, tol);
            try std.testing.expectApproxEqAbs(im, y[k].im, tol);
        }
        plan.inverse(y);
        for (x, y) |a, b| {
            try std.testing.expectApproxEqAbs(a.re * @as(f32, @floatFromInt(n)), b.re, 1e-3 * @as(f32, @floatFromInt(n)));
        }
    }
}
