# zui shader notes (for porting the zpui renderers)

Source of truth: zui's `crates/gpui_macos/src/shaders.metal` (abbrev. **M:line**) and
`crates/gpui_wgpu/src/shaders.wgsl` (**W:line**), plus `shaders_subpixel.wgsl` (**WS:line**),
`gpui_wgpu/src/blur_kernel.rs` (**BK:line**), `gpui_wgpu/src/wgpu_renderer.rs` (**WR:line**)
and `gpui_macos/src/metal_renderer.rs` (**MR:line**). The instance structs are mirrored in
`src/scene.zig` / `src/color.zig` / `src/atlas.zig`, with comptime size/offset asserts.

## 0. Conventions shared by every primitive

**Instance layouts.** Metal structs are cbindgen output of the Rust `#[repr(C)]` structs, so they
are plain 4-byte scalars and match `extern struct` exactly. WGSL storage buffers add two rules:
`vec2<f32>`/`vec2<i32>`/`mat2x2<f32>` (hence `Bounds`, `AtlasTile`, `TransformationMatrix`) are
8-byte aligned, and the array stride is the struct size rounded to its alignment. That is why
`Underline`, `MonochromeSprite`, `SubpixelSprite`, `PolychromeSprite` and `Shadow` carry
`pad: u32` fields; every instance struct size is a multiple of 8. No instance struct contains
`vec3`/`vec4` members, so the 16-byte vector alignment only matters for **uniforms**
(`BlurPassParams`, `BackdropBlurParams`, `GammaParams`; see 9 and 10). Sizes:

| struct | bytes | notes |
|---|---|---|
| `Hsla` | 16 | WGSL `struct Hsla {h,s,l,a: f32}` (align 4, not vec4) |
| `Background` | 72 | tag u32, color_space u32, solid, angle/pattern f32, 2×`LinearColorStop`(20), pad |
| `EdgeFadeParams` | 32 | |
| `AtlasTile` | 32 | `bounds` at 16 (i32) |
| `TransformationMatrix` | 24 | row-major in Rust; WGSL `transpose(mat2x2)` (W:183) |
| `Shadow` | 112 | |
| `Quad` | 192 | background at 40, fade at 160 |
| `Underline` | 64 | |
| `MonochromeSprite` / `SubpixelSprite` | 144 | tile at 56, transformation at 88 |
| `PolychromeSprite` | 168 | alpha_mask at 96, tile at 136 |
| `BackdropBlur` | 56 | Metal instance only; WGSL uses `BackdropBlurUniform` |
| `PathRasterizationVertex` | 104 | bounds at 88 |
| `PathSprite` | 16 | |
| `SurfaceBounds` | 32 | WGSL `SurfaceParams` uniform |

**Unit quad.** Metal draws 6 vertices from a buffer `[(0,0),(1,0),(0,1),(0,1),(1,0),(1,1)]`
(MR:321) as two triangles per instance. WGSL draws a 4-vertex triangle strip computing
`unit_vertex = vec2(f32(vid & 1), 0.5 * f32(vid & 2))` (W:576).

**Device position** (M:1024, W:170–178): `p = unit * bounds.size + bounds.origin`;
`ndc = p / viewport * (2, -2) + (-1, 1)`. Transformed variant (sprites, M:1036, W:180):
`p' = R * p + t` with row-major `R`.

**Clipping** to `content_mask.bounds` (M:1140, W:192): vertex stage outputs
`(p.x - clip.x, clip.right - p.x, p.y - clip.y, clip.bottom - p.y)`. Metal feeds it to hardware
`[[clip_distance]]` (except mono sprites, which pass it as a varying and `return 0` when any
component < 0, M:672). WGSL has no clip distances in Naga: every fragment shader starts with
`if any(clip < 0) return vec4(0)` (e.g. W:619). Mono/poly/subpixel sprites do the check *after*
`textureSample` so derivatives stay uniform (W:1309–1315).

**Color conversion** `hsla_to_rgba` (M:926, W:242): `h6 = h*6; c = (1-|2l-1|)*s;
x = c*(1-|fmod(h6,2)-1|); m = l - c/2`; sector by `h6` in [0,1),[1,2)…, else branch = sector 5;
output `(rgb + m, a)`. Metal treats the result as display sRGB; the WGSL comments call it
"linear" (wgpu draws to an sRGB-handled target), which is why WGSL gradients convert in
`prepare_gradient_color` (below).

**Output alpha mode.** Metal pipelines blend `SourceAlpha / OneMinusSourceAlpha` on RGB and
`One / OneMinusSourceAlpha` on alpha (MR:2150–2158) — shaders output **straight** alpha.
WGSL wraps every return in `blend_color(color, factor)` (W:391): `a = color.a * factor;
rgb *= (premultiplied_alpha ? a : 1)`; the pipeline uses `PREMULTIPLIED_ALPHA_BLENDING` when the
surface is premultiplied, else `ALPHA_BLENDING` (WR:829–834).

**SDF helpers** (identical in both):
- `pick_corner_radius(center_to_point, radii)` (M:1069, W:341): x<0 → left, y<0 → top
  (screen y-down): TL / TR / BL / BR.
- `quad_sdf_impl(ccp, r)` (M:1099, W:372): if `r == 0` → `max(ccp.x, ccp.y)`; else
  `length(max(ccp, 0)) + min(0, max(ccp.x, ccp.y)) - r`.
- `quad_sdf(p, bounds, radii)` (M:1087, W:362): `half = size/2; ctp = p - (origin + half);
  r = pick(ctp); ccp = |ctp| - half + r; quad_sdf_impl(ccp, r)`. Positive outside.
- Coverage everywhere is `saturate(0.5 - distance)`.
- `over(below, above)` (M:1168, W:313): `a = above.a + below.a*(1-above.a);
  rgb = (above.rgb*above.a + below.rgb*below.a*(1-above.a)) / a`.

**Edge fade** `edge_fade_alpha(pos, fade)` (M:1208, W:533) — zui addition. `ramp = 1`; for each
edge with `band > 0`: top `clamp((y - top_y)/band_top,0,1)`, bottom
`clamp((bottom_y - y)/band_bottom,0,1)`, left `clamp((x - left_x)/band_left,0,1)`, right
`clamp((right_x - x)/band_right,0,1)`; `ramp = min(ramp, ·)`; return `ramp * ramp` (squared, to
match the CPU per-glyph curve). All-zero params → 1. Positions are framebuffer
(device-pixel) coordinates, i.e. `@builtin(position).xy` / `[[position]].xy`.

## 1. Backgrounds / gradients (`Background`)

Vertex stage `prepare_fill_color` (M:1177) / `prepare_gradient_color` (W:404):
- tags 0 (solid), 2 (pattern slash), 3 (checkerboard): `solid = hsla_to_rgba(solid)`.
- tag 1 (linear gradient): `c0, c1 = hsla_to_rgba(stops)`; then
  - Metal: if `color_space == 1` → `srgb_to_oklab` (M:984) on both; sRGB stays as is.
  - WGSL: `color_space == 0` → `linear_to_srgba` (piecewise sRGB OETF, W:224); `== 1` →
    `linear_srgb_to_oklab` (W:278, no linearization since the input is "linear").
  - Results are passed as `flat` varyings to avoid per-pixel conversion.

Fragment `fill_color` (M:1225) / `gradient_color` (W:431):
- **Linear gradient**: `rad = (fmod(angle, 360) - 90) * π/180; dir = (cos, sin)`; squash the short
  side: if `w > h` → `dir.y *= h/w` else `dir.x *= w/h`. `t = dot(p - center, dir) / |dir|`;
  if `|dir.x| > |dir.y|` → `t = (t + half.x)/w` else `t = (t + half.y)/h`;
  `t = clamp((t - p0)/(p1 - p0), 0, 1)` with stop percentages `p0,p1`.
  - sRGB: Metal `mix(c0,c1,t)`; WGSL `srgba_to_linear(mix(c0,c1,t))` (W:473).
  - Oklab: `oklab_to_srgb(mix(c0,c1,t))` (Metal, M:1005: inverse LMS cube then `pow(1/2.2)`) /
    `oklab_to_linear_srgb` (WGSL, W:296).
  - Metal only: triangular dither (M:1281–1288): `seed = p * 0.6180339887;
    r1 = fract(sin(dot(seed,(12.9898,78.233)))*43758.5453);
    r2 = fract(sin(dot(seed,(39.3460,11.135)))*24634.6345); tri = r1 + r2 - 1;
    rgb += tri*2/255; a += tri*3/255`.
  - Oklab matrices (both): LMS = `[0.4122214708 0.5363325363 0.0514459929; 0.2119034982
    0.6806995451 0.1073969566; 0.0883024619 0.2817188376 0.6299787005] * rgb`, cube-root, then
    `[0.2104542553 0.7936177850 -0.0040720468; 1.9779984951 -2.4285922050 0.4505937099;
    0.0259040371 0.7827717662 -0.8086757660]`. Inverse at M:1006–1017 / W:297–309. Metal's
    `srgb_to_linear`/`linear_to_srgb` are the `pow(·, 2.2)` approximation (M:974–980); WGSL uses
    the exact piecewise curves (W:210–229).
- **Pattern slash** (M:1292, W:481): `width = (h / 65535) / 255; interval = fmod(h, 65535) / 255;
  height = width + interval; period = height * sin(π/4)`; rotate `p - origin` by 45°
  (`[[c,-s],[s,c]]`, M:1198); `pat = fmod(rot.x, period)`;
  `d = min(pat, period - pat) - period*(width/height)/2`; `color = solid; a *= saturate(0.5 - d)`.
  (CPU packing: `height = (width*255)*0xFFFF + interval*255`, `color.zig: patternSlash`.)
- **Checkerboard** (M:1308, W:500): `cell = floor((p - origin)/size)`;
  `a *= saturate(fmod(cell.x + cell.y, 2))`.

## 2. Quad (`quad_vertex`/`quad_fragment` M:67–404, `vs_quad`/`fs_quad` W:574–949)

Vertex: device position, clip distances, `border_color = hsla_to_rgba`, gradient prep.

Fragment:
1. `bg = fill_color(...)`; `fade = edge_fade_alpha(pos, quad.fade)`; `bg.a *= fade` (M:110, W:629).
2. `unrounded` = all radii 0. Fast path: no borders && unrounded → return `bg`.
3. `size, half = size/2, point = pos - origin, ctp = point - half`; `aa = 0.5`;
   `r = pick_corner_radius(ctp)`; `border = (ctp.x<0 ? left : right, ctp.y<0 ? top : bottom)`;
   `reduced = (border == 0 ? -aa : border)` per component (zero-width borders produce no AA
   fringe).
4. `ctc = |ctp| - half` (corner_to_point, ≤0); `ccp = ctc + r`;
   `near_corner = ccp.x >= 0 && ccp.y >= 0`; `sbi = ctc + reduced`;
   `beyond_inner = sbi.x > 0 || sbi.y > 0`; `within_inner = sbi.x < -aa && sbi.y < -aa`.
   If `within_inner && !near_corner` → return `bg`.
5. `outer = quad_sdf_impl(ccp, r)`. `inner`:
   - `ccp.x <= 0 || ccp.y <= 0` → `-max(sbi.x, sbi.y)` (straight);
   - else if `beyond_inner` → `-1`;
   - else if `reduced.x == reduced.y` → `-(outer + reduced.x)` (circular inner edge);
   - else `quarter_ellipse_sdf(ccp, max(0, r - reduced))` (M:445, W:988):
     `(length(ccp/radii) - 1) * (radii.x + radii.y) * -0.5`.
6. `border_sdf = max(inner, outer)`. If `border_sdf < aa`: border color (Metal also multiplies
   `border.a *= fade`, M:220), optional dash factor (below), then
   `color = mix(bg, over(bg, border), saturate(aa - inner))`.
7. Return `color * (1,1,1, saturate(aa - outer))` (Metal M:403).
   WGSL returns `blend_color(color, saturate(aa - outer) * edge_fade_alpha(...))` (W:948) — note
   WGSL applies the fade to the background **twice** in this path and does not fade the border
   separately; Metal applies it once to fill and once to border. Pick one (Metal's is correct).

**Dashed borders** (`border_style == 1`, M:223–394, W:748–939). Dash = 2·width, gap = 1·width
(`period_per_width = 3`, `dv_numerator = 1/3`); "dash velocity" = dash periods per pixel.
- Unrounded: lay out per side. `horizontal = ccp.x < ccp.y`;
  `w = horizontal ? max(bottom, top) : max(right, left)`; `dv = (1/3)/w`;
  `t = (horizontal ? point.x : point.y) * dv`; `max_t = (horizontal ? size.x : size.y) * dv`.
- Rounded: clockwise around the perimeter starting at the top-left end of the top edge.
  `dv_side = w <= 0 ? 0 : (1/3)/w`; straight lengths `s_t = (w - r_tl - r_tr)*dv_t`,
  `s_r = (h - r_tr - r_br)*dv_r`, `s_b = (w - r_br - r_bl)*dv_b`, `s_l = (h - r_bl - r_tl)*dv_l`;
  `corner_dash_velocity(a,b)` (M:414) = the non-zero one, else `min(a,b)`; corner lengths
  `c_X = r_X * π/2 * cdv_X`; cumulative `upto_tr = s_t; upto_r = +c_tr; upto_br = +s_r;
  upto_b = +c_br; upto_bl = +s_b; upto_l = +c_bl; upto_tl = +s_l; max_t = upto_tl + c_tl`.
  Near a corner: `corner_t = atan2(ccp.y, ccp.x) * r`; TR: `t = upto_r - corner_t*cdv_tr`;
  BR: `upto_br + corner_t*cdv_br`; BL: `upto_l - corner_t*cdv_bl`; TL: `upto_tl + corner_t*cdv_tl`.
  Straight: top `t = (point.x - r_tl)*dv_t`; bottom `upto_bl - (point.x - r_bl)*dv_b`;
  left `upto_tl - (point.y - r_tl)*dv_l`; right `upto_r + (point.y - r_tr)*dv_r`.
- `dash_length = 2/3`; `max_t -= unrounded ? dash_length : 0`. If `max_t >= 1`:
  `period = max_t / floor(max_t)`; `border.a *= dash_alpha(t, period, 2/3, dv, 0.5)`.
  Else if unrounded and `gap = max_t - dash_length > 0`: `period = dash_length + gap`, same call.
- `dash_alpha` (M:426, W:971): `centered = fmod(t + period/2 - length/2, period) - period/2;
  sd = |centered| - length/2; saturate(0.5 - sd / dv)`. WGSL defines `fmod(a,b) = a - b*trunc(a/b)`
  (W:1000) to match Metal's sign-of-dividend `fmod`.

WGSL fast pipelines (W:600–614, selection WR:2021–2060, WR:2722): `fs_solid_quad` (solid
background, no radii/borders/fade: clip test + `blend_color(solid, 1)`) and
`fs_opaque_solid_quad` (also alpha == 1 and fully inside the content mask: return `solid`
directly). A batch uses the fast pipeline only if **all** its quads qualify.

## 3. Shadow (M:469–562, W:1032–1103)

Vertex: drop shadow geometry = `bounds` inflated by `margin = 3*blur_radius` on every side; inset
shadow geometry = `element_bounds`. Clip against `content_mask`; `color = hsla_to_rgba`.

Fragment: `half = size/2; ctp = pos - center(bounds); r = pick_corner_radius(ctp)`.
- `blur == 0`: `alpha = saturate(0.5 - quad_sdf(pos, bounds, radii))`.
- else (Evan Wallace's rounded-rect blur): `low = ctp.y - half.y; high = ctp.y + half.y;
  start = clamp(-3σ, low, high); end = clamp(3σ, low, high); step = (end - start)/4;
  y = start + step/2`; 4 iterations:
  `alpha += blur_along_x(ctp.x, ctp.y - y, σ, r, half) * gaussian(y, σ) * step; y += step`.
  - `gaussian(x,σ) = exp(-x²/(2σ²)) / (sqrt(2π)·σ)` (M:1117, W:320).
  - `erf(v)` (M:1122, W:325), vectorized: `s = sign(v); a = |v|;
    r1 = 1 + (0.278393 + (0.230389 + (0.000972 + 0.078108a)a)a)a; s - s/(r1²)²`.
  - `blur_along_x(x, y, σ, r, half)` (M:1130, W:333): `delta = min(half.y - r - |y|, 0);
    curved = half.x - r + sqrt(max(0, r² - delta²));
    integral = 0.5 + 0.5*erf((x + (-curved, curved)) * sqrt(0.5)/σ); integral.y - integral.x`.
- Inset (`inset != 0`): `alpha = (1 - alpha) * saturate(0.5 - quad_sdf(pos, element_bounds,
  element_corner_radii))` — `bounds` is the "hole".
- Output `color * (1,1,1,alpha)` / `blend_color(color, alpha)`.
`M_PI_F` is `3.1415926` in WGSL (W:99).

## 4. Underline (M:577–626, W:1225–1268)

Straight (`wavy == 0`): solid `color` (WGSL `blend_color(color, color.a)` — alpha applied twice
when not premultiplying; Metal returns `color`). Wavy: `st = (pos - origin)/h - (0, 0.5)`;
`freq = π * 2 * thickness / h`; `amp = thickness * 0.8 / h`; `sine = sin(st.x*freq)*amp`;
`dsine = cos(st.x*freq)*amp*freq`; `d = (st.y - sine)/sqrt(1 + dsine²) * h`;
`alpha = saturate(0.5 - max(-(d + thickness/2), d - thickness/2))`.

## 5. Monochrome sprite (M:644–683, W:1292–1318)

Vertex: transformed device position and clip distances; `tile_position =
(tile.origin + unit * tile.size) / atlas_size` (M:1060, W:187 — WGSL reads the size via
`textureDimensions`). Linear-filtered sample.
- Metal: atlas is A8 → `color.a *= sample.a * edge_fade_alpha(...)`.
- WGSL: atlas is R8 → `a = apply_contrast_and_gamma_correction(sample.r, color.rgb,
  grayscale_enhanced_contrast, gamma_ratios)` (W:65, adapted from Windows Terminal's DWrite
  shader: `k = enhancedContrast * saturate(4*(0.75 - lum))`, `lum = dot(rgb,(0.30,0.59,0.11))`;
  `a' = a(k+1)/(a·k+1)`; `a'' = a' + a'(1-a')·((g.x·lum + g.y)·a' + g.z·lum + g.w)`), then
  `blend_color(color, a * edge_fade)`.

**Subpixel sprite** (WS:28–58, wgpu only): sample `.rgb` (swap to `.bgr` if `is_bgr`), per-channel
contrast/gamma (`apply_contrast_and_gamma_correction3`, W:73), dual-source output
`foreground = (color.rgb, 1)`, `alpha = (color.a * coverage_rgb * edge_fade, 1)` with blend
`Src1 / OneMinusSrc1` on color (WR:1013).

## 6. Polychrome sprite (M:698–756, W:1366–1396)

Untransformed device position. Fragment: `sample`; `d = quad_sdf(pos, bounds, corner_radii)`
(per-corner rounded images); grayscale if set: `g = dot(rgb, (0.2126, 0.7152, 0.0722))`;
`alpha *= opacity * saturate(0.5 - d) * edge_fade_alpha(pos, fade) * image_mask_alpha(pos,
alpha_mask)`.

`image_mask_alpha` (M:721, W:1332) — zui addition: if `feather <= 0` → 1. Else
`q = |pos - center| - half + radius;
dist = length(max(q,0)) + min(max(q.x,q.y),0) - radius` (standard rounded-box SDF);
`alpha = smoothstep(0, feather, dist - clearance)`; if `bottom_feather > 0`:
`alpha = min(alpha, smoothstep(0, bottom_feather, bottom_y - pos.y))`.

Object-fit cover is CPU-side: zui crops the atlas tile to the visible fraction of the fitted box
(`Window::paint_image_fitted_masked`, `window.rs` ~L4600; ported as `scene.cropTileForFit`)
so the sprite bounds equal the visible rect and the corner SDF rounds the real corners.

## 7. Paths (two passes)

**Rasterization** into an intermediate (viewport-sized) texture, 4× MSAA on Metal
(`PATH_SAMPLE_COUNT = 4`, MR:44), optional MSAA on wgpu. Vertices: one
`PathRasterizationVertex` per path vertex with `color = path.color` and
`bounds = path.clipped_bounds()` (WR:2369–2378). Blend `One / OneMinusSourceAlpha` (output is
premultiplied).
- Vertex (M:771, W:1124): `ndc = xy * (2/w, -2/h) + (-1, 1)`; clip distances against `bounds`.
- Fragment (M:796, W:1137): `dx = dFdx(st), dy = dFdy(st)` (computed before the clip test in
  WGSL); if `length((dx.x, dy.x)) < 0.001` → `alpha = 1` (interior triangles, `st = (0,1)`); else
  Loop–Blinn quadratic: `f = st.x² - st.y`; `grad = (2·st.x·dx.x - dx.y, 2·st.x·dy.x - dy.y)`;
  `alpha = saturate(0.5 - f/|grad|)`. Color from `fill_color` with the path's background and
  bounds (gradients/patterns work on paths). Output `(rgb·a·alpha, a·alpha)`.
- Triangulation (`scene.zig: Path`): fan from the contour start `(start, current, to)` with
  `st = (0,1)` for every line/curve after the first; curves add `(current, ctrl, to)` with
  `st = (0,0), (0.5,0), (1,1)`. Overlapping fan triangles are resolved by the blend (nonzero-ish
  accumulation), not a stencil.

**Composite** (`path_sprite_*` M:843–872, `vs_path`/`fs_path` W:1182–1202): draw `PathSprite`
rects, `uv = screen_pos / viewport`, return the sample (no content mask; already applied).
To avoid double-blending translucent paths: if every path in the batch has the same order, one
sprite per path's clipped bounds (disjoint by construction); otherwise one sprite for the union
of all clipped bounds (MR:1730–1751). Metal blend `One / OneMinusSourceAlpha`; wgpu color
`One / OneMinusSrcAlpha`, alpha `One / One` (WR:959–970).

## 8. Surface (M:885–924, W:1423–1447)

Placeholder in zpui. Bi-planar YCbCr (`y` R8 + `cbcr` RG8) sampled at `unit_vertex`, converted by
the column-major matrix `[(1,1,1,0), (0,-0.3441,1.772,0), (1.402,-0.7141,0,0),
(-0.701,0.5291,-0.886,1)] * (y, cb, cr, 1)` (full-range BT.601).

## 9. Backdrop blur (zui addition)

**Scene semantics** (`scene.zig: Scene.insertBackdropBlur`, `BatchIterator.next`): blurs get a
draw order like any primitive but live in `scene.backdrop_blurs`, outside the batch stream. The
batch iterator caps every batch at `(next_blur.order, Shadow)` after skipping blurs with
`order <= head.order`, so no batch straddles a blur. zui's `Window::paint_backdrop_blur` inserts a
transparent shadow "splitter" before the blur. Renderer loop (MR:999–1006, WR:1876–1895): before
each batch, process every pending blur with `blur.order <= batch.firstOrder()`, in order:
end the pass, snapshot, blur, resume the pass with `Load`, composite, then draw the batch.

**Snapshot region** (MR:1013–1044, WR:1284–1311): `σ = max(blur_radius, 1)` (device px);
`pad = ceil(3σ) + 2`; `visible = bounds ∩ content_mask`; `x0 = max(floor(vis.x - pad), 0)`,
`y0` likewise, `x1 = min(ceil(vis.right + pad), W)`, `y1` likewise; skip if empty. Copy a
scratch-sized window positioned at `copy = max(min(x0, W - scratch.w), 0)` so the whole scratch
texture holds real framebuffer content (clamp-to-edge then behaves like a full-drawable blur;
scratch textures are reused and may be larger than the region).

**Metal blur**: `MPSImageGaussianBlur(sigma: σ)` with `edgeMode = clamp` (MR:1474–1504; LRU of
4 kernels keyed by σ ± 0.01), scratch → blurred texture.

**wgpu blur** (two separable passes, `fs_blur_pass` W:1490–1539):
- `downsample = clamp(floor(σ/8), 1, 4)` (WR:1303); blur targets are
  `ceil(region/downsample)`; `σ_t = max(σ/downsample, 0.5)` in blur-texel units.
- Weights (BK:8–26): `radius = ceil(3·σ_t)`; if `radius > 128` the CPU leaves zeros and the
  shader computes `exp(-k²/(2σ²))` on the fly and normalizes by the running sum; otherwise
  `w[k] = exp(-k²/(2σ_t²)) / Σ_{-r..r}` stored as `array<vec4<f32>, 33>` (index `k/4`, lane `k%4`).
- Pass 1 (horizontal): reads the full-res snapshot, `direction = (1,0)`,
  `stride = downsample`, `texel = 1/snapshot_size`, writes `blur_a`. Taps at
  `uv + k·dir·stride·texel` for `k ∈ [-r, r]`, weight `w[|k|]`.
- Pass 2 (vertical): reads `blur_a`, `direction = (0,1)`, `stride = 1`, `texel = 1/blur_size`,
  writes `blur_b`. At unit stride it uses the linear-sampling trick: center `w[0]`, then for
  `k = 1,3,5…`: `wsum = w[k] + w[k+1]`, `offset = (k + w[k+1]/wsum)·step`, two taps (±) weighted
  `wsum`.
- `sigma` is clamped to ≥ 0.5 in the shader too. Scissor rects limit work to the visible region
  plus halos (`blur_regions`, BK:31–64: vertical region = visible mapped into blur space ±1 texel;
  horizontal region adds `ceil(3σ)+1` rows of halo in y and 1 texel in x).
- `BlurPassParams` uniform (std140): `direction vec2 @0, sigma @8, stride @12,
  source_texel_size vec2 @16, padding vec2 @24, weights array<vec4,33> @32` → 560 bytes.

**Composite** (`backdrop_blur_fragment` M:1355–1377, `fs_backdrop_blur` W:1572–1590): pipeline
with **blending disabled** — the blur replaces the region, so outside fragments must `discard`
(not return 0): discard if clip distance < 0 (WGSL; Metal uses hardware clip) or
`quad_sdf(pos, bounds, corner_radii) > 0` (hard edge, no AA). Sample with clamp-to-edge linear at
`uv = (pos - source_rect.xy) / source_rect.zw` where `source_rect = (copy_x, copy_y, scratch_w,
scratch_h)` in drawable pixels (normalized UVs make the downsample factor irrelevant).
`BackdropBlurParams` uniform: `bounds @0, corner_radii @16, clip_bounds @32, source_rect @48`
→ 64 bytes (uniform address space rounds the `Corners`/`Bounds` struct members to 16-byte
alignment, which the Rust layout happens to satisfy).

## 10. Other uniforms (wgpu)

- `GlobalParams { viewport_size: vec2<f32>, premultiplied_alpha: u32, pad: u32 }` (W:80) — 16 B.
- `GammaParams { gamma_ratios: vec4<f32>, grayscale_enhanced_contrast: f32,
  subpixel_enhanced_contrast: f32, is_bgr: u32, pad: u32 }` (W:86) — 32 B.
- Metal passes `viewport_size` / `atlas_size` as `Size_DevicePixels` (two i32) in separate
  buffer slots per draw.

## 11. Edge-fade summary by primitive

Applied per pixel to: Quad (fill + border), MonochromeSprite, SubpixelSprite, PolychromeSprite.
Not applied to Shadow, Underline, Path, Surface, BackdropBlur.
