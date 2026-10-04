#!/usr/bin/env python3
"""Generate zpui's tailwind-style builder methods from zui's gpui_macros/src/styles.rs.

Outputs (paths relative to the zpui repo root):
  src/style/styled_generated.zig  `Methods(Self)`: spacing/size/inset/radius/border scales,
                                  shadow presets, cursor/overflow/visibility/position setters.
  src/style/builder.zig           `StyleBuilder`: a styled value over a bare StyleRefinement,
                                  with forwarders for every Styled + generated method.

Usage:
  scripts/gen_styled.py [--zui PATH]           regenerate the two files
  scripts/gen_styled.py --forward FILE.zig     rewrite the forwarder block(s) in FILE between
        // zpui:styled-forwarders begin(TypeName)
        // zpui:styled-forwarders end
  (forwarders reference `zpui_styled.Styled(TypeName)` / `.Generated(TypeName)`; the file must
  have `const zpui_styled = @import(".../styled.zig");` or the root module's `styled`.)

Deviations from gpui (intentional):
  * negative (`_neg_`) variants only for margin and inset prefixes; gpui also emits nonsense
    like `p_neg_4`, `w_neg_full`, `gap_neg_2`.
  * cursor setters whose CursorStyle variant is missing from src/platform/platform.zig are skipped
    (listed in the generated file's header).
"""

import argparse
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_ZUI = "/home/user/research/zui"
NEGATIVE_GROUPS = {"margin_box_style_prefixes", "position_box_style_prefixes"}
BOX_GROUPS = ["box_prefixes", "margin_box_style_prefixes", "padding_box_style_prefixes", "position_box_style_prefixes"]
CURSOR_OVERRIDES = {"IBeam": "ibeam", "ContextualMenu": "context_menu", "IBeamCursorForVerticalLayout": "ibeam_vertical"}


def camel(name: str) -> str:
    """gpui snake_case -> zpui camelCase; digit runs stay separated (`w_1_2` -> `w1_2`)."""
    parts = [p for p in name.split("_") if p]
    out = parts[0]
    for p in parts[1:]:
        if p[0].isdigit() and out[-1].isdigit():
            out += "_" + p
        else:
            out += p[0].upper() + p[1:]
    return out


def snake(name: str) -> str:
    return re.sub(r"(?<!^)(?=[A-Z])", "_", name).lower()


def zig_ident(name: str) -> str:
    return name if re.match(r"^[A-Za-z_]\w*$", name) else f'@"{name}"'


def rust_num(s: str) -> str:
    s = re.sub(r"(\d+)\.(?!\d)", r"\1.0", s.strip())
    return s.replace("/", " / ")


def length_expr(tokens: str) -> str:
    tokens = tokens.strip()
    if tokens.startswith("auto"):
        return "geom.auto"
    m = re.match(r"(px|rems|relative)\((.*)\)$", tokens)
    if not m:
        raise SystemExit(f"unrecognized length tokens: {tokens!r}")
    return f"geom.{m.group(1)}({rust_num(m.group(2))})"


def fn_body(src: str, name: str) -> str:
    m = re.search(r"fn " + name + r"\(\)[^{]*\{(.*?)\n\}", src, re.S)
    if not m:
        raise SystemExit(f"fn {name} not found in styles.rs")
    return m.group(1)


def parse_structs(body: str, kind: str):
    out = []
    for m in re.finditer(kind + r" \{(.*?)\n        \}", body, re.S):
        block = m.group(1)
        item = {"prefix": None}
        pm = re.search(r'(prefix|suffix): "([^"]*)"', block)
        item["name"] = pm.group(2)
        am = re.search(r"auto_allowed: (true|false)", block)
        item["auto"] = am and am.group(1) == "true"
        fields_m = re.search(r"fields: vec!\[(.*?)\]", block, re.S)
        if fields_m:
            item["fields"] = re.findall(r"quote! \{\s*([\w.]+)\s*\}", fields_m.group(1))
        tm = re.search(r"(?:length|radius|width)_tokens: quote! \{\s*(.*?)\s*\}", block, re.S)
        if tm:
            item["tokens"] = tm.group(1)
        out.append(item)
    return out


def platform_cursors() -> set:
    src = open(os.path.join(ROOT, "src/platform/platform.zig")).read()
    m = re.search(r"pub const CursorStyle = enum \{(.*?)\};", src, re.S)
    return set(re.findall(r"(\w+),", m.group(1))) if m else set()


class Gen:
    def __init__(self, styles: str):
        self.src = styles
        self.lines = []
        self.names = []
        self.field_sets = {}
        self.skipped = []

    def fields_const(self, fields, hint=None):
        key = tuple(fields)
        if key not in self.field_sets:
            ident = "f_" + (hint or "_".join(f.replace(".", "_") for f in fields))
            self.field_sets[key] = ident
        return self.field_sets[key]

    def method(self, gpui_name, doc, body):
        name = camel(gpui_name)
        self.names.append(name)
        self.lines.append(f"        /// gpui `{gpui_name}`{doc}")
        self.lines.append(f"        pub fn {zig_ident(name)}(self: Self) Self {{")
        self.lines.append(f"            return {body};")
        self.lines.append("        }")

    def custom(self, gpui_name, ty, fields, doc):
        name = camel(gpui_name)
        self.names.append(name)
        fc = self.fields_const(fields, gpui_name)
        self.lines.append(f"        /// {doc} Accepts `px(..)`, `rems(..)`, numbers (px) and `{ty}`.")
        self.lines.append(f"        pub fn {zig_ident(name)}(self: Self, length: anytype) Self {{")
        self.lines.append(f"            return set(self, &{fc}, {ty}.from(length));")
        self.lines.append("        }")

    def preset(self, prefix, suffix, ty, fields, tokens, negate):
        name = prefix + ("_neg" if negate else "") + (f"_{suffix}" if suffix else "")
        expr = f"{ty}.from({length_expr(tokens)})" + (".neg()" if negate else "")
        fc = self.fields_const(fields)
        self.method(name, f": {'-' if negate else ''}{tokens.strip()}.", f"set(self, &{fc}, comptime {expr})")

    def box_methods(self):
        suffixes = parse_structs(fn_body(self.src, "box_style_suffixes"), "BoxStyleSuffix")
        for group in BOX_GROUPS:
            negatives = group in NEGATIVE_GROUPS
            self.lines.append(f"\n        // ---- {group} ----\n")
            for p in parse_structs(fn_body(self.src, group), "BoxStylePrefix"):
                ty = "Length" if p["auto"] else "DefiniteLength"
                self.custom(p["name"], ty, p["fields"], f"Sets `{', '.join(p['fields'])}`.")
                for s in suffixes:
                    if s["name"] != "auto" or p["auto"]:
                        self.preset(p["name"], s["name"], ty, p["fields"], s["tokens"], False)
                    if s["name"] != "auto" and negatives:
                        self.preset(p["name"], s["name"], ty, p["fields"], s["tokens"], True)

    def corner_border_methods(self):
        for prefixes, suffixes, kind in [
            ("corner_prefixes", "corner_suffixes", "Corner"),
            ("border_prefixes", "border_suffixes", "Border"),
        ]:
            self.lines.append(f"\n        // ---- {prefixes} ----\n")
            sfx = parse_structs(fn_body(self.src, suffixes), kind + "StyleSuffix")
            for p in parse_structs(fn_body(self.src, prefixes), kind + "StylePrefix"):
                self.custom(p["name"], "AbsoluteLength", p["fields"], f"Sets `{', '.join(p['fields'])}`.")
                for s in sfx:
                    self.preset(p["name"], s["name"], "AbsoluteLength", p["fields"], s["tokens"], False)

    def unit_setters(self):
        """`fn x(mut self) -> Self { self.style().a.b = Some(gpui::Enum::Variant); ... self }`"""
        cursors = platform_cursors()
        self.lines.append("\n        // ---- visibility / position / overflow / cursor ----\n")
        pat = re.compile(
            r"fn (\w+)\(mut self\) -> Self \{\s*((?:self\.style\(\)\.[\w.]+ = Some\(gpui::\w+::\w+\);\s*)+)self\s*\}"
        )
        for m in pat.finditer(self.src):
            gpui_name = m.group(1)
            assigns = re.findall(r"self\.style\(\)\.([\w.]+) = Some\(gpui::(\w+)::(\w+)\);", m.group(2))
            parts = []
            ok = True
            for path, enum, variant in assigns:
                zv = CURSOR_OVERRIDES.get(variant, snake(variant)) if enum == "CursorStyle" else snake(variant)
                if enum == "CursorStyle" and zv not in cursors:
                    self.skipped.append(f"{gpui_name} (CursorStyle.{zv} missing in platform.zig)")
                    ok = False
                    break
                parts.append((path, f"style.{enum}.{zig_ident(zv)}"))
            if not ok:
                continue
            if len(parts) == 1:
                path, val = parts[0]
                fc = self.fields_const([path])
                body = f"set(self, &{fc}, {val})"
            else:
                body = "blk: {\n                var s = self;\n                const r = s.style();\n"
                for path, val in parts:
                    body += f"                r.{path} = {val};\n"
                body += "                break :blk s;\n            }"
            self.method(gpui_name, ".", body)

    def shadows(self):
        consts = []
        pat = re.compile(r"fn shadow_(\w+)\(mut self\) -> Self \{(.*?)\n        \}", re.S)
        sh = re.compile(
            r"BoxShadow::new\(px\(([-\d.]+)\), px\(([-\d.]+)\), hsla\(([^)]*)\)\)((?:\.\w+\(px\([-\d.]+\)\))*)"
        )
        self.lines.append("\n        // ---- box_shadow_style_methods ----\n")
        for m in pat.finditer(self.src):
            suffix = m.group(1)
            items = []
            for s in sh.finditer(m.group(2)):
                h = ", ".join(rust_num(x) for x in s.group(3).split(","))
                extra = "".join(
                    f", .{k} = {rust_num(v)}" for k, v in re.findall(r"\.(\w+)\(px\(([-\d.]+)\)\)", s.group(4))
                )
                items.append(
                    f"        .{{ .color = color.hsla({h}), .offset = .{{ .x = {rust_num(s.group(1))}, .y = {rust_num(s.group(2))} }}{extra} }},"
                )
            if not items:  # shadow_none: hand-written in src/styled.zig
                continue
            ident = zig_ident(suffix)
            consts.append(f"    pub const {ident} = [_]BoxShadow{{\n" + "\n".join(items) + "\n    };")
            self.method(f"shadow_{suffix}", " preset.", f"set(self, &f_box_shadow, @as([]const BoxShadow, &shadows.{ident}))")
        self.fields_const(["box_shadow"])
        return consts

    def render(self, zui_path):
        self.box_methods()
        self.corner_border_methods()
        self.unit_setters()
        shadow_consts = self.shadows()
        dupes = {n for n in self.names if self.names.count(n) > 1}
        if dupes:
            raise SystemExit(f"duplicate method names: {sorted(dupes)}")
        fields = []
        for key, ident in self.field_sets.items():
            items = ", ".join("&.{" + ", ".join(f'"{p}"' for p in f.split(".")) + "}" for f in key)
            fields.append(f"const {ident} = [_]Path{{ {items} }};")
        skipped = "".join(f"\n//!   {s}" for s in self.skipped) or " none"
        return f"""//! GENERATED by scripts/gen_styled.py from zui crates/gpui_macros/src/styles.rs; do not edit.
//! Re-run `python3 scripts/gen_styled.py` after zui changes.
//!
//! Skipped gpui methods:{skipped}

const style = @import("../style.zig");
const geom = @import("../geometry.zig");
const color = @import("../color.zig");

const Length = geom.Length;
const DefiniteLength = geom.DefiniteLength;
const AbsoluteLength = geom.AbsoluteLength;
const BoxShadow = style.BoxShadow;

/// A field path inside `StyleRefinement`, e.g. `.{{ "padding", "top" }}`.
const Path = []const []const u8;

{chr(10).join(fields)}

/// gpui's tailwind shadow presets (exact values from styles.rs).
pub const shadows = struct {{
{chr(10).join(shadow_consts)}
}};

/// Number of generated methods.
pub const method_count = {len(self.names)};

/// Generated builder methods for any `Self` with `fn style(*Self) *StyleRefinement`.
pub fn Methods(comptime Self: type) type {{
    return struct {{
        fn set(self: Self, comptime paths: []const Path, value: anytype) Self {{
            var s = self;
            const r = s.style();
            inline for (paths) |path| switch (path.len) {{
                1 => @field(r, path[0]) = value,
                2 => @field(@field(r, path[0]), path[1]) = value,
                else => unreachable,
            }};
            return s;
        }}
{chr(10).join(self.lines)}
    }};
}}
"""


def handwritten_names():
    src = open(os.path.join(ROOT, "src/styled.zig")).read()
    src = src[src.index("pub fn Styled(") :]
    src = src[: src.index("\n    };\n}")]
    return re.findall(r"^        pub fn (\w+)\(self: \*?Self", src, re.M)


def forwarders(type_name, gen_names, styled_ref="zpui_styled", indent="    "):
    hand = handwritten_names()
    lines = [
        f"{indent}const StyledMethods = {styled_ref}.Styled({type_name});",
        f"{indent}const GeneratedStyledMethods = {styled_ref}.Generated({type_name});",
    ]
    lines += [f"{indent}pub const {zig_ident(n)} = StyledMethods.{zig_ident(n)};" for n in hand]
    lines += [f"{indent}pub const {zig_ident(n)} = GeneratedStyledMethods.{zig_ident(n)};" for n in gen_names]
    return lines


def render_builder(gen_names):
    fw = "\n".join(forwarders("StyleBuilder", gen_names, styled_ref="styled"))
    return f"""//! GENERATED by scripts/gen_styled.py; do not edit.
//!
//! `StyleBuilder` is a chainable `StyleRefinement`: `StyleBuilder.init.flex().p2().bg(c).refinement`.
//! Use it for hover/active/focus refinements and anywhere a style is built without an element.

const style_mod = @import("../style.zig");
const styled = @import("../styled.zig");

pub const StyleBuilder = struct {{
    refinement: style_mod.StyleRefinement = .{{}},

    pub const init: StyleBuilder = .{{}};

    pub fn style(self: *StyleBuilder) *style_mod.StyleRefinement {{
        return &self.refinement;
    }}

{fw}
}};
"""


def zig_fmt(path):
    try:
        subprocess.run(["zig", "fmt", path], check=True, capture_output=True)
    except (OSError, subprocess.CalledProcessError) as e:
        print(f"warning: zig fmt {path} failed: {e}", file=sys.stderr)


def generate(zui):
    styles = open(os.path.join(zui, "crates/gpui_macros/src/styles.rs")).read()
    gen = Gen(styles)
    out = gen.render(zui)
    hand = set(handwritten_names())
    clash = hand & set(gen.names)
    if clash:
        raise SystemExit(f"generated names clash with src/styled.zig: {sorted(clash)}")
    paths = [os.path.join(ROOT, "src/style/styled_generated.zig"), os.path.join(ROOT, "src/style/builder.zig")]
    open(paths[0], "w").write(out)
    open(paths[1], "w").write(render_builder(gen.names))
    for p in paths:
        zig_fmt(p)
    print(f"generated {len(gen.names)} methods ({len(hand)} hand-written in src/styled.zig)")
    for s in gen.skipped:
        print(f"skipped: {s}")
    return gen.names


def inject(path, gen_names):
    src = open(path).read()
    pat = re.compile(
        r"^([ \t]*)// zpui:styled-forwarders begin\((\w+)\)\n.*?^[ \t]*// zpui:styled-forwarders end",
        re.S | re.M,
    )

    def repl(m):
        indent, ty = m.group(1), m.group(2)
        body = "\n".join(forwarders(ty, gen_names, indent=indent))
        return f"{indent}// zpui:styled-forwarders begin({ty})\n{body}\n{indent}// zpui:styled-forwarders end"

    new, n = pat.subn(repl, src)
    if n == 0:
        raise SystemExit(f"no forwarder markers in {path}")
    open(path, "w").write(new)
    print(f"wrote {n} forwarder block(s) into {path}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--zui", default=DEFAULT_ZUI)
    ap.add_argument("--forward", metavar="FILE", action="append", default=[])
    args = ap.parse_args()
    names = generate(args.zui)
    for f in args.forward:
        inject(f, names)


if __name__ == "__main__":
    main()
