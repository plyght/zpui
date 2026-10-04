//! zeron media UI shared by the composer and the transcript (the
//! `zeron_media` module): the image lightbox (`viewer.zig`, zeron
//! `image_viewer.rs`) and small attachment widgets (`widgets.zig`: the
//! upload progress ring, thumbnails).

pub const viewer = @import("viewer.zig");
pub const widgets = @import("widgets.zig");
pub const Lightbox = viewer.Lightbox;
pub const LightboxOptions = viewer.Options;
pub const LightboxClosed = viewer.Closed;

test {
    @import("std").testing.refAllDecls(@This());
    _ = viewer;
    _ = widgets;
}
