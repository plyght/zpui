//! Images and SVGs for zpui (gpui `svg_renderer.rs`, `assets.rs`,
//! `elements/img.rs`, `elements/image_cache.rs`).
//!
//! - `svg`: lunasvg-backed SVG rendering; `SvgRenderer` + `RenderSvgParams`
//!   produce monochrome alpha masks for tinted icons (`AtlasKey.svg`) and
//!   straight-alpha BGRA for multicolor SVGs.
//! - `decode`: PNG/JPEG/GIF/BMP/TGA/HDR/PNM (stb_image), WebP (simplewebp),
//!   SVG fallback; EXIF orientation; max-size downscaling. Pure functions,
//!   safe to run on executor workers.
//! - `RenderImage`: shared decoded frames (BGRA, straight alpha) keyed into
//!   the polychrome atlas by id.
//! - `ImageSource` / `ImageCache`: sources, load bookkeeping, `evict` that
//!   frees atlas tiles (zui fork's `ImageSource::evict`), LRU trimming.
//! - `ObjectFit` / `fitImage`: object-fit geometry and the cover tile crop.
//!
//! The window/element layer owns the `SvgRenderer`, `ImageCache` and atlases;
//! nothing here keeps global state except the atomic `RenderImage` id counter.

pub const svg = @import("svg.zig");
pub const decode_mod = @import("decode.zig");
pub const fit = @import("fit.zig");
pub const cache = @import("cache.zig");
pub const render_image = @import("render_image.zig");
pub const encode = @import("encode.zig");
pub const encodePng = encode.encodePng;

pub const SvgRenderer = svg.SvgRenderer;
pub const SvgDocument = svg.Document;
pub const RenderSvgParams = svg.RenderSvgParams;
pub const AssetSource = svg.AssetSource;
pub const SMOOTH_SVG_SCALE_FACTOR = svg.SMOOTH_SVG_SCALE_FACTOR;

pub const Format = decode_mod.Format;
pub const DecodeOptions = decode_mod.Options;
pub const DecodeError = decode_mod.Error;
pub const decode = decode_mod.decode;
pub const decodeFile = decode_mod.decodeFile;
pub const probe = decode_mod.probe;
pub const guessFormat = decode_mod.guessFormat;
pub const extensions = decode_mod.extensions;

pub const ImageId = render_image.ImageId;
pub const Frame = render_image.Frame;
pub const DecodedImage = render_image.DecodedImage;
pub const RenderImage = render_image.RenderImage;

pub const ImageSource = cache.ImageSource;
pub const EncodedImage = cache.EncodedImage;
pub const ImageCache = cache.ImageCache;
pub const LoadError = cache.LoadError;
pub const DecodeJob = cache.DecodeJob;
pub const dropImage = cache.dropImage;

pub const ObjectFit = fit.ObjectFit;
pub const FittedImage = fit.FittedImage;
pub const fitImage = fit.fitImage;

test {
    @import("std").testing.refAllDecls(@This());
    _ = svg;
    _ = decode_mod;
    _ = fit;
    _ = cache;
    _ = render_image;
    _ = encode;
}
