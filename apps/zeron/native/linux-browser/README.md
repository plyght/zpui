# zeron-webkit (Linux browser helper)

`helper.c` is copied **verbatim** from zeron (`crates/ui/src/browser/linux/helper.c`,
commit `9e1a111`), MIT License, Copyright (c) 2026 Wing — see
`apps/zeron/assets/LICENSE.zeron`. Do not edit it here; re-copy it when zeron changes.

It runs WebKitGTK 4.1 in its own process, renders pages into offscreen GTK windows and
streams BGRA frames plus page state to zeron over stdout; zeron sends JSON commands on
stdin (protocol: `apps/zeron/src/ui/browser/linux.zig`).

Build: `zig build zeron` compiles it with `zig cc` into `zig-out/bin/zeron-webkit` when
`pkg-config` finds `webkit2gtk-4.1` and `json-glib-1.0` (Debian/Ubuntu:
`libwebkit2gtk-4.1-dev libjson-glib-dev`); otherwise it is skipped and the Browser tab
reports that the helper is missing. At runtime zeron looks for it in
`$ZERON_WEBKIT_HELPER`, next to the `zeron` binary, then in `../libexec/zeron/`.
