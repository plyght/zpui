//! Zig declarations of src/image/c/zpui_image_c.h (implemented by
//! c/zpui_svg.cpp and c/zpui_decode.c, compiled by image_build.zig).

pub const Svg = opaque {};

pub extern fn zpui_svg_parse(data: [*]const u8, len: usize) ?*Svg;
pub extern fn zpui_svg_destroy(svg: *Svg) void;
pub extern fn zpui_svg_size(svg: *const Svg, width: *f32, height: *f32) void;
pub extern fn zpui_svg_render(svg: *Svg, pixels: [*]u8, width: c_int, height: c_int, stride: c_int, matrix: *const [6]f32, current_color: u32) c_int;

pub extern fn zpui_stbi_info(data: [*]const u8, len: c_int, width: *c_int, height: *c_int) c_int;
pub extern fn zpui_stbi_load_rgba(data: [*]const u8, len: c_int, width: *c_int, height: *c_int) ?[*]u8;
pub extern fn zpui_stbi_load_gif(data: [*]const u8, len: c_int, delays: *?[*]c_int, width: *c_int, height: *c_int, frames: *c_int) ?[*]u8;
pub extern fn zpui_stbi_failure_reason() [*:0]const u8;
pub extern fn zpui_webp_load_rgba(data: [*]const u8, len: usize, width: *c_int, height: *c_int) ?[*]u8;
pub extern fn zpui_decode_free(ptr: ?*anyopaque) void;
