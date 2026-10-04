/* Umbrella header translated by build.zig (b.addTranslateC) into the `linux_c`
 * module used by src/platform/linux/. Protocol headers are generated at build
 * time by wayland-scanner from the XMLs in protocols/. */
#include <wayland-client.h>
#include <wayland-cursor.h>
#include "xdg-shell-client-protocol.h"
#include "xdg-decoration-unstable-v1-client-protocol.h"
#include "fractional-scale-v1-client-protocol.h"
#include "viewporter-client-protocol.h"
#include "tablet-v2-client-protocol.h"
#include "cursor-shape-v1-client-protocol.h"
#include "text-input-unstable-v3-client-protocol.h"
#include "org-kde-kwin-blur-client-protocol.h"

#include <xkbcommon/xkbcommon.h>
#include <xkbcommon/xkbcommon-compose.h>
#include <xkbcommon/xkbcommon-x11.h>

#include <X11/Xlib.h>
#include <X11/Xlib-xcb.h>
#include <X11/Xcursor/Xcursor.h>
#include <X11/extensions/XInput2.h>
#include <X11/extensions/XI2proto.h>
#include <xcb/xcb.h>
#include <xcb/xkb.h>

#include <locale.h>
