# ghostty-vt: Ghostty's terminal core, vendored and ported to Zig 0.17

This directory is the **libghostty-vt** Zig module (Ghostty's `src/lib_vt.zig`
and everything it imports), copied from Ghostty and ported from Zig 0.16 to
Zig 0.17 so zpui builds with **one toolchain**. Ghostty is MIT licensed
(`LICENSE`); uucode is MIT (`uucode/LICENSE.md`).

| | |
|---|---|
| Upstream | ghostty-org/ghostty `f96c9711b9f72ecf75e0fd50f3434529b4dea5b6` (2026-10-04, 1.3.2-dev) |
| uucode | jacobsandlund/uucode `1fb73433` ("Migrate to Zig 0.17"). Ghostty pins `9d555245`, 9 commits earlier; the only differences are the 0.17 port |
| Files | 267 upstream files (`FILES.txt`), about 205k lines including tests and tables, plus 2 new shim files |
| Consumer | `apps/zeron/src/terminal` (`zeron_terminal` module), via `module.zig` |

## Why vendor + port (option a)

* Ghostty's `build.zig` calls `requireZig`, which refuses anything except 0.16, so
  libghostty-vt can't be a 0.17 package dependency.
* Linking the C API that a separate pinned Zig 0.16 builds (option b) would mean two
  toolchains in CI and on every dev machine. It would also mean a C ABI layer
  between two Zig codebases, and losing the Zig API (`RenderState`, `Selection`,
  encoders).
* The port turned out to be mostly mechanical: 0.16 to 0.17 is `@typeInfo` field
  layout, a few std renames and removals, and the removed `**` operator. A small
  set of shims and two scripts covers it. Writing our own emulator (option c)
  would throw away years of conformance work.

## Layout

```
module.zig            build wiring (imported by the top-level build.zig)
src/                  upstream src/ subset, same relative paths
src/lib/compat/zig017.zig   NEW: 0.16-API shims (fields/decls/params, StructField,
                            stackFallback, ManagedMemoryPool, bufPrintZ, metaFields)
src/lib/compat/repeat.zig   NEW: replacement for the removed `**` on strings
generated/props.zig   unicode width/grapheme property tables (Ghostty `props_uucode`)
generated/symbols.zig "is symbol" table (Ghostty `symbols_uucode`)
generated/uucode_tables.zig  uucode runtime tables (grapheme_break, width)
uucode/               uucode runtime sources (0.17) + uucode_runtime_config.zig
tools/port017.py      mechanical 0.16->0.17 rewrites (idempotent)
tools/autofix017.py   compiler-error-driven rewrites (info.fields, .params, ptr attrs)
tools/update.sh       re-vendor a newer Ghostty (copy -> port017 -> patch)
tools/make_patch.sh   regenerate ghostty-zig017.patch
tools/unigen/         regenerate generated/*.zig (regen.sh /path/to/uucode)
ghostty-zig017.patch  the hand-made delta on top of (upstream + port017.py)
FILES.txt             the upstream files that are vendored
```

## Build configuration (`module.zig`)

The same imports Ghostty's `src/build/GhosttyZig.zig` sets up for the `lib` artifact:

* `terminal_options`: `artifact=.lib`, `simd=false` (no C++ simdutf/highway, no
  libc requirement), `oniguruma=false` (so no tmux control mode),
  `kitty_graphics=false` (it needs wuffs), and `snapshot=false` (state serialization
  is unused, and its golden tests need build-generated files). `c_abi=false`.
  `slow_runtime_safety` is on in Debug only, like upstream. Everything else is on:
  formatter, selection, search, render_state, input_encode, color,
  grid_introspection and glyph_protocol.
* `build_options`: only `simd` (and `wasm_shared`) are read by the closure.
* `unicode_tables` and `symbols_tables` are generated **once** and checked in
  (Ghostty builds them at build time with a host exe). `tools/unigen/regen.sh`
  rebuilds them byte-for-byte.
* `uucode` uses pre-generated tables (`generated/uucode_tables.zig`). Ghostty's
  `src/build/uucode_config.zig` keeps its fields and components, but the tables are
  trimmed to the three fields the runtime reads (`grapheme_break`,
  `grapheme_break_no_control`, `width`). That gives 3.2 MB of source instead of
  5.5 MB, and no UCD parsing at build time.

## Changes, in three layers

### 1. Import-closure cuts (stubs and test removals)

Zig 0.17 loads **every** file reachable through `@import("x.zig")`, even inside unused
functions and tests. Upstream `lib_vt.zig` reaches the whole app (apprt, font,
renderer, config, termio) through a handful of hub files. These were cut:

| File | Change |
|---|---|
| `build_config.zig` | **Replaced by a stub**: `AppRuntime`/`app_runtime=.none`, `slow_runtime_safety`, `is_debug`. Upstream imports apprt/font/renderer. |
| `quirks.zig` | **Replaced by a stub**: only `inlineAssert`. Upstream imports `font/main.zig`. |
| `terminal/search.zig` | `Thread = void` unconditionally. Upstream only imports `search/Thread.zig` (xev + app globals) for `.ghostty`. |
| `input/function_keys.zig` | Removed test "keys" (imports `termio.zig`; upstream skips it for `.lib`). |
| `input/key_mods.zig` | Removed 4 `RemapSet: formatEntry` tests (import `config/formatter.zig`). |
| `font/Metrics.zig` | Removed 2 `formatConfig` tests (import `config.zig`; upstream skips them for `.lib`). |
| `font/Glyph.zig` | Removed test "Constraints" (imports `nerd_font_attributes.zig`, 2.4k-line tables). |
| `font/opentype/{glyf,head,sfnt}.zig` | Removed the tests that `@embedFile` fonts through `font/embedded.zig`. |
| `lib_vt.zig` | Added `pub const device_attributes = terminal.device_attributes;` so embedders can implement the DA effect. |

### 2. Mechanical rewrites (`tools/port017.py`, idempotent)

| 0.16 | 0.17 |
|---|---|
| `"ab" ** n` | `zpui_repeat.str("ab", n)` (comptime helper, same `*const [N:0]u8` type) |
| `[_]T{x} ** n` | `@as([n]T, @splat(x))` |
| `@typeInfo(T).@"struct"/"enum"/"union".fields` / `.decls` | `zig017.fields(...)` / `zig017.decls(...)` (returns 0.16-shaped `StructField`/`EnumField`/`UnionField` arrays built from `field_names`/`field_types`/`field_attrs`/`field_values`) |
| `@typeInfo(F).@"fn".params` | `zig017.params(...)` |
| `std.meta.fields(T)` (a compile error now) | `zig017.metaFields(T)` |
| `std.builtin.Type.StructField/EnumField/UnionField` | `zig017.*` (with `.Attributes` = `Type.Struct/Union.FieldAttributes`) |
| `std.meta.Int(s, n)` | `@Int(s, n)` |
| `std.heap.stackFallback(n, a)` | `zig017.stackFallback(n, a)` (owning wrapper over `std.heap.BufferFirstAllocator`) |
| `std.fmt.bufPrintZ` | `zig017.bufPrintZ` (`bufPrintSentinel(.., 0)`) |
| `alloc.dupeZ(u8, x)` | `alloc.dupeSentinel(u8, x, 0)` |
| `X.initEmpty()` / `X.initFull()` (static bit sets, `EnumSet`) | `X.empty` / `X.full` |
| `std.hash.crc.Crc32Iscsi` | `std.hash.crc.Generic(u32, .{ CRC-32/ISCSI params })` (the new `@"CRC-32/ISCSI"` alias is the SSE4.2 wrapper on x86_64, with a different raw `.crc` state) |
| `std.ascii.indexOfIgnoreCase` | `std.ascii.findIgnoreCase` |
| `.Debug/.ReleaseSafe/.ReleaseFast/.ReleaseSmall` (OptimizeMode) | `.debug/.safe/.fast/.small` (`std.lang.Optimize`) |

The script adds `const zig017 = @import(".../lib/compat/zig017.zig");` and/or the
`zpui_repeat` import at the end of every file it touches. It rewrites 51 files at
164 call sites.

### 3. Hand edits (all in `ghostty-zig017.patch`)

* **Compiler-error-driven** (`tools/autofix017.py`): `info.fields`, `info.decls` and
  `fn_info.params` on *captured* type-info values (`.@"struct" => |info|`, `const
  info = @typeInfo(T).@"enum"`), which regexes can't safely find. Also
  `ptr_info.is_const` → `ptr_info.attrs.@"const"` (and the other pointer attrs).
  Affected: `datastruct/{comparison,segmented_list,split_tree}.zig`,
  `lib/{packed,struct,union}.zig`, `input/key.zig`, `terminal/{charsets,
  parse_table,page,style,device_status,...}.zig`, `unicode/grapheme.zig`,
  `lib/compat/testing.zig`.
* `lib/compat/testing.zig`: `std.meta.declarations` now returns names (`[:0]const
  u8`) instead of `Declaration` structs.
* `lib/TinyIo.zig`: the `std.Io.VTable` changes. Removed `processReplacePath`,
  `processSpawnPath`, `netSend`, `netRead` and `netWrite`. Added
  `inheritParentDir`/`inheritParentFile` (the `Io.failing*` defaults).
* `terminal/PageList.zig`: `std.heap.memory_pool.Managed(Pin)` →
  `zig017.ManagedMemoryPool(Pin)` (0.17 pools are unmanaged).
* `terminal/c/{sys,terminal}.zig`, `terminal/kitty/graphics_pixel.zig`,
  `simd/base64_scalar.zig`: anonymous `.{x} ** n` array repetition rewritten by hand
  (`@splat`, typed `[_]u16{..} ++ @as([n]u16, @splat(0))`).
* **Skipped tests** (`if (true) return error.SkipZigTest;` plus a comment), where 0.17
  `std.testing` semantics differ and the code under test is fine:
  * `Terminal: setPwd/setTitle preserves a sentinel on allocation failure`:
    `FailingAllocator` no longer fails the in-place resize the test relies on.
  * `stream: continuation allocation failure recovers`: same cause.
  * `lib/tinyio: dirRealPathFile edge cases`: the 0.17 `realPathFile` reports a
    different error for overlong names. `TinyIo` is unused by zpui.
  * `HISTORY decode compresses history pages when requested` (snapshot):
    in Debug only, it aborts with a SafeAllocator canary panic on the record
    writer's scratch buffer. It passes in ReleaseSafe. Snapshot serialization is
    disabled in the zpui build and the root cause has not been found yet. Revisit
    this before enabling `snapshot`.

## Updating Ghostty

```sh
vendor/ghostty-vt/tools/update.sh /path/to/ghostty        # copy FILES.txt, port017.py, apply patch
zig build ghostty-vt-test 2>&1 | python3 vendor/ghostty-vt/tools/autofix017.py  # repeat until 0 fixes
# fix the rest by hand, then:
vendor/ghostty-vt/tools/make_patch.sh /path/to/ghostty    # refresh ghostty-zig017.patch
```

If upstream adds imports, recompute the closure. Any new file reachable from
`src/lib_vt.zig` must be added to `FILES.txt`, or cut like the hubs above.
`update.sh` followed by `diff -r` against the current tree reproduces the vendored
sources exactly (checked when this was written).

Regenerate the unicode tables after a uucode or Unicode update with
`vendor/ghostty-vt/tools/unigen/regen.sh /path/to/uucode`.

## Tests

* `zig build ghostty-vt-test` runs the full upstream suite (about 2.8k tests),
  always with `slow_runtime_safety` on, because some upstream tests assert it.
  That means a page integrity check on every mutation, so a Debug run takes about
  12 min. `-Doptimize=ReleaseSafe` is much faster. The test run's cwd is
  `vendor/ghostty-vt`, so the snapshot golden files resolve. Status as of the port
  (ReleaseSafe): 2754 passed, 43 skipped (38 upstream skips for macOS-only or
  disabled features, plus the 5 above), 0 failed. A Debug run gave the same
  results up to the snapshot test that is now skipped.
* `zig build terminal-test` runs the zeron wrapper tests (fast). It is part of
  `zig build test`.
