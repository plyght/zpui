//! Mermaid diagrams for zeron: a port of mermaid-rs-renderer 0.3.1 (parser,
//! layout and SVG emission) plus zeron's palette and restyle pass.

pub const util = @import("util.zig");
pub const ir = @import("ir.zig");
pub const parser = @import("parser.zig");
pub const validator = @import("validator.zig");
pub const theme = @import("theme.zig");
pub const config = @import("config.zig");
pub const text = @import("text.zig");

test {
    _ = util;
    _ = ir;
    _ = parser;
    _ = validator;
    _ = theme;
    _ = config;
    _ = text;
    _ = @import("regex.zig");
    _ = @import("json5.zig");
    _ = @import("svg_fmt.zig");
}

pub const layout = @import("layout/layout.zig");
test {
    _ = layout;
    _ = @import("parity_test.zig");
}
