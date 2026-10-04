#!/usr/bin/env python3
"""Report upstream changes that zpui / apps/zeron still need to port.

Reads tools/upstream/map.json (pinned revisions + a file-level map from upstream
source files to the Zig files that port them), fetches each upstream, diffs
`pinned..HEAD`, and writes a Markdown report:

  * changed upstream files grouped by the Zig file(s) that port them;
  * changes in areas that are mapped but not ported yet;
  * unmapped changes (new files, or files only a catch-all pattern matched) —
    add them to map.json;
  * generators / parity dumps whose inputs changed, with the command to re-run;
  * version-pin changes (zeron moving its zui / gpui-component rev) and
    Cargo.lock bumps of crates we ported line-for-line (pulldown-cmark, similar,
    tree-sitter…).

Usage (from the repo root):

  python3 tools/upstream/check.py                       # clone/fetch into .upstream-cache/, report to stdout
  python3 tools/upstream/check.py --out report.md       # also: --json report.json
  python3 tools/upstream/check.py --local zui=/home/user/research/zui --local zeron=/home/user/zeron
  python3 tools/upstream/check.py --offline --local zeron=/home/user/zeron --head zeron=HEAD
  python3 tools/upstream/check.py --only zui            # one upstream (repeatable)
  python3 tools/upstream/check.py --coverage            # list local upstream files no specific mapping covers
  python3 tools/upstream/check.py --bump zui            # after porting: set pinned = the fetched head in map.json

Exit status: 0, or with --fail-on-changes 2 when anything changed. When run on
GitHub Actions (`GITHUB_OUTPUT` set) it also writes `has_changes=true|false`
and `report=<path>` step outputs.

Only the standard library and the `git` CLI are needed.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_MAP = ROOT / "tools/upstream/map.json"
DEFAULT_CACHE = ROOT / ".upstream-cache"
ISSUE_BODY_LIMIT = 60000  # GitHub caps issue bodies at 65536 characters


# --------------------------------------------------------------------------- globs

def glob_to_regex(pattern: str) -> re.Pattern:
    """'*' = within one path segment, '**' = any depth (also zero segments), '?' = one char."""
    out, i = [], 0
    while i < len(pattern):
        c = pattern[i]
        if pattern.startswith("**", i):
            i += 2
            if i < len(pattern) and pattern[i] == "/":
                i += 1
                out.append("(?:.*/)?")
            else:
                out.append(".*")
            continue
        if c == "*":
            out.append("[^/]*")
        elif c == "?":
            out.append("[^/]")
        else:
            out.append(re.escape(c))
        i += 1
    return re.compile("^" + "".join(out) + "$")


def specificity(pattern: str) -> tuple[int, int]:
    literal = len(re.sub(r"\*+|\?", "", pattern))
    wildcards = pattern.count("*") + pattern.count("?")
    return (literal, -wildcards)


@dataclass
class Mapping:
    upstream: str
    pattern: str
    zig: list[str]
    status: str
    note: str | None
    catch_all: bool
    rx: re.Pattern = field(repr=False)
    rank: tuple[int, int] = (0, 0)


class Map:
    def __init__(self, path: Path):
        self.path = path
        self.raw = json.loads(path.read_text())
        self.upstreams: dict = self.raw["upstreams"]
        self.mappings: list[Mapping] = []
        for e in self.raw["mappings"]:
            self.mappings.append(Mapping(
                upstream=e["upstream"], pattern=e["pattern"], zig=e.get("zig", []),
                status=e.get("status", "ported"), note=e.get("note"), catch_all=bool(e.get("catch_all")),
                rx=glob_to_regex(e["pattern"]), rank=specificity(e["pattern"])))
        self.generators: list[dict] = self.raw.get("generators", [])
        self.pins: list[dict] = self.raw.get("pins", [])
        self.deps: list[dict] = self.raw.get("deps", [])

    def lookup(self, upstream: str, path: str) -> Mapping | None:
        best = None
        for m in self.mappings:
            if m.upstream == upstream and m.rx.match(path) and (
                    best is None or (not m.catch_all, m.rank) > (not best.catch_all, best.rank)):
                best = m
        return best

    def save_pinned(self, name: str, rev: str, date: str | None) -> None:
        self.raw["upstreams"][name]["pinned"] = rev
        if date:
            self.raw["upstreams"][name]["pinned_date"] = date
        self.path.write_text(json.dumps(self.raw, indent=1, ensure_ascii=False) + "\n")


# --------------------------------------------------------------------------- git

def git(repo: Path, *args: str, check: bool = True) -> str:
    res = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True)
    if check and res.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed in {repo}:\n{res.stderr.strip()}")
    return res.stdout


def has_commit(repo: Path, rev: str) -> bool:
    return subprocess.run(["git", "-C", str(repo), "cat-file", "-e", f"{rev}^{{commit}}"],
                          capture_output=True).returncode == 0


def prepare_repo(name: str, cfg: dict, args) -> tuple[Path, str]:
    """Returns (repo path, resolved head sha)."""
    url, branch = cfg["url"], cfg.get("branch", "main")
    local = args.local.get(name)
    ref = f"refs/remotes/upstream-check/{branch}"
    if local:
        repo = Path(local)
        if not (repo / ".git").exists() and not repo.name.endswith(".git"):
            raise RuntimeError(f"--local {name}={local} is not a git checkout")
    else:
        repo = Path(args.cache) / name
        if not (repo / ".git").exists() and not (repo / "HEAD").exists():
            if args.offline:
                raise RuntimeError(f"no cached clone at {repo} and --offline given")
            repo.parent.mkdir(parents=True, exist_ok=True)
            print(f"[{name}] cloning {url}", file=sys.stderr)
            subprocess.run(["git", "clone", "--quiet", "--filter=blob:none", "--no-checkout", url, str(repo)],
                           check=True)
    if not args.offline:
        print(f"[{name}] fetching {url} {branch}", file=sys.stderr)
        git(repo, "fetch", "--quiet", url, f"+refs/heads/{branch}:{ref}")
        if not has_commit(repo, cfg["pinned"]):
            git(repo, "fetch", "--quiet", url, cfg["pinned"], check=False)
    head_arg = args.head.get(name)
    if head_arg:
        head = git(repo, "rev-parse", head_arg).strip()
    elif git(repo, "rev-parse", "--verify", "--quiet", ref, check=False).strip():
        head = git(repo, "rev-parse", ref).strip()
    else:
        head = git(repo, "rev-parse", "HEAD").strip()
    if not has_commit(repo, cfg["pinned"]):
        raise RuntimeError(f"{name}: pinned revision {cfg['pinned']} is not in {repo} (force-pushed upstream?)")
    return repo, head


def show_file(repo: Path, rev: str, path: str) -> str | None:
    res = subprocess.run(["git", "-C", str(repo), "show", f"{rev}:{path}"], capture_output=True, text=True)
    return res.stdout if res.returncode == 0 else None


# --------------------------------------------------------------------------- analysis

@dataclass
class Change:
    status: str          # A M D R C T
    path: str
    old_path: str | None
    added: int | None
    deleted: int | None
    mapping: Mapping | None


@dataclass
class UpstreamResult:
    name: str
    url: str
    pinned: str
    head: str
    repo: Path
    commits: list[str] = field(default_factory=list)
    changes: list[Change] = field(default_factory=list)
    generators: list[dict] = field(default_factory=list)
    pin_changes: list[str] = field(default_factory=list)
    dep_changes: list[str] = field(default_factory=list)
    error: str | None = None

    @property
    def changed(self) -> bool:
        return self.pinned != self.head and bool(self.commits or self.changes)


def diff_changes(repo: Path, pinned: str, head: str, m: Map, name: str) -> list[Change]:
    numstat: dict[str, tuple[int | None, int | None]] = {}
    for line in git(repo, "diff", "--numstat", "-M", pinned, head).splitlines():
        parts = line.split("\t")
        if len(parts) < 3:
            continue
        a, d, p = parts[0], parts[1], parts[-1]
        if " => " in p:  # rename: "dir/{old => new}/x" or "old => new"
            mt = re.match(r"(.*)\{(.*) => (.*)\}(.*)", p)
            p = (mt.group(1) + mt.group(3) + mt.group(4)).replace("//", "/") if mt else p.split(" => ")[1]
        numstat[p] = (None if a == "-" else int(a), None if d == "-" else int(d))
    out = []
    for line in git(repo, "diff", "--name-status", "-M", pinned, head).splitlines():
        parts = line.split("\t")
        st = parts[0][0]
        if st in "RC" and len(parts) >= 3:
            old, new = parts[1], parts[2]
        else:
            old, new = None, parts[1]
        a, d = numstat.get(new, (None, None))
        mp = m.lookup(name, new)
        if (mp is None or mp.catch_all) and old:
            mo = m.lookup(name, old)
            if mo is not None and not mo.catch_all:
                mp = mo
        out.append(Change(st, new, old, a, d, mp))
    return out


def lock_versions(text: str | None) -> dict[str, list[str]]:
    vers: dict[str, list[str]] = {}
    if not text:
        return vers
    for blk in text.split("[[package]]"):
        n = re.search(r'^name = "([^"]+)"', blk, re.M)
        v = re.search(r'^version = "([^"]+)"', blk, re.M)
        if n and v:
            vers.setdefault(n.group(1), []).append(v.group(1))
    return vers


def analyze(name: str, cfg: dict, m: Map, args) -> UpstreamResult:
    res = UpstreamResult(name, cfg["url"], cfg["pinned"], "", Path("."))
    try:
        repo, head = prepare_repo(name, cfg, args)
    except Exception as exc:  # noqa: BLE001 — reported in the output instead
        res.error = str(exc)
        return res
    res.repo, res.head = repo, head
    if head == cfg["pinned"]:
        return res
    res.commits = git(repo, "log", "--no-merges", "--format=%h %ad %s", "--date=short",
                      f"{cfg['pinned']}..{head}").splitlines()
    res.changes = diff_changes(repo, cfg["pinned"], head, m, name)

    paths = [c.path for c in res.changes] + [c.old_path for c in res.changes if c.old_path]
    for gen in m.generators:
        if gen["upstream"] != name:
            continue
        rxs = [glob_to_regex(p) for p in gen["patterns"]]
        hits = sorted({p for p in paths if any(r.match(p) for r in rxs)})
        if hits:
            res.generators.append({**gen, "hits": hits})

    for pin in m.pins:
        if pin["upstream"] != name:
            continue
        before, after = show_file(repo, cfg["pinned"], pin["file"]), show_file(repo, head, pin["file"])
        rx = re.compile(pin["regex"])
        b = rx.search(before or "")
        a = rx.search(after or "")
        bv, av = (b.group(1) if b else None), (a.group(1) if a else None)
        tracked = m.upstreams.get(pin["tracks"], {}).get("pinned")
        tracking = bool(av and tracked and (tracked.startswith(av) or av.startswith(tracked)))
        if bv != av and tracking:
            res.pin_changes.append(f"`{pin['file']}` moved its **{pin['tracks']}** pin `{short(bv)}` → `{short(av)}`; "
                                   f"map.json already tracks it.")
        elif bv != av:
            res.pin_changes.append(f"`{pin['file']}` moved its **{pin['tracks']}** pin `{short(bv)}` → `{short(av)}` "
                                   f"(map.json tracks `{short(tracked)}`): port {pin['tracks']} up to `{short(av)}` "
                                   f"and bump its pin.")
        elif av and tracked and not tracking:
            res.pin_changes.append(f"`{pin['file']}` pins **{pin['tracks']}** at `{short(av)}` but map.json tracks "
                                   f"`{short(tracked)}`.")

    locks = {d["lockfile"] for d in m.deps if d["upstream"] == name}
    for lockfile in sorted(locks):
        before = lock_versions(show_file(repo, cfg["pinned"], lockfile))
        after = lock_versions(show_file(repo, head, lockfile))
        for dep in (d for d in m.deps if d["upstream"] == name and d["lockfile"] == lockfile):
            rx = glob_to_regex(dep["crate"])
            for crate in sorted(set(before) | set(after)):
                if not rx.match(crate):
                    continue
                if dep["crate"].endswith("*") and any(d2["crate"] == crate for d2 in m.deps):
                    continue  # an exact entry reports it
                bv, av = before.get(crate), after.get(crate)
                if bv != av:
                    res.dep_changes.append(f"`{crate}` {fmt_vers(bv)} → {fmt_vers(av)} — {dep['action']}")
    return res


def short(rev: str | None) -> str:
    return rev[:10] if rev else "none"


def fmt_vers(v: list[str] | None) -> str:
    return "/".join(v) if v else "(absent)"


# --------------------------------------------------------------------------- report

STATUS_WORD = {"A": "added", "M": "modified", "D": "deleted", "R": "renamed", "C": "copied", "T": "type changed"}


def change_line(c: Change, link_base: str | None) -> str:
    stat = ""
    if c.added is not None or c.deleted is not None:
        stat = f" (+{c.added or 0} −{c.deleted or 0})"
    name = f"`{c.old_path}` → `{c.path}`" if c.old_path else f"`{c.path}`"
    if link_base and c.status != "D":
        name = f"[{name}]({link_base}/{c.path})"
    extra = ""
    if c.mapping and c.mapping.status not in ("ported", "n/a"):
        extra = f" — *{c.mapping.status}*"
        if c.mapping.note:
            extra += f": {c.mapping.note}"
    return f"- {c.status} {name}{stat}{extra}"


def render(results: list[UpstreamResult], m: Map, args) -> str:
    now = _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    L: list[str] = []
    L.append("# Upstream changes to port")
    L.append("")
    L.append(f"_Generated {now} by `tools/upstream/check.py` from `tools/upstream/map.json`. "
             "After porting, bump the pins with `python3 tools/upstream/check.py --bump <upstream>` "
             "(see docs/UPSTREAM.md)._")
    L.append("")
    L.append("| upstream | pinned | head | commits | files | mapped | not ported | unmapped | ignored |")
    L.append("|---|---|---|---:|---:|---:|---:|---:|---:|")
    for r in results:
        if r.error:
            L.append(f"| {r.name} | `{short(r.pinned)}` | **error** | | | | | | |")
            continue
        cmp_url = f"{r.url}/compare/{r.pinned}...{r.head}"
        mapped = sum(1 for c in r.changes if c.mapping and not c.mapping.catch_all and c.mapping.zig)
        notp = sum(1 for c in r.changes if c.mapping and not c.mapping.catch_all and not c.mapping.zig
                   and c.mapping.status != "n/a")
        unm = sum(1 for c in r.changes if c.mapping is None or c.mapping.catch_all)
        ign = sum(1 for c in r.changes if c.mapping and not c.mapping.catch_all and not c.mapping.zig
                  and c.mapping.status == "n/a")
        head = f"[`{short(r.head)}`]({cmp_url})" if r.head != r.pinned else "= pinned"
        L.append(f"| {r.name} | `{short(r.pinned)}` | {head} | {len(r.commits)} | {len(r.changes)} | {mapped} | "
                 f"{notp} | {unm} | {ign} |")
    L.append("")

    errs = [r for r in results if r.error]
    for r in errs:
        L.append(f"> **{r.name}**: {r.error}")
        L.append("")

    gens = [(r, g) for r in results for g in r.generators]
    if gens:
        L.append("## Generators / parity dumps to re-run")
        L.append("")
        for r, g in gens:
            run = g["run"].replace("{zui}", str(args.paths.get("zui", "<zui checkout>"))) \
                          .replace("{zeron}", str(args.paths.get("zeron", "<zeron checkout>")))
            L.append(f"- **{g['name']}** ({r.name}: {', '.join(f'`{h}`' for h in g['hits'][:6])}"
                     f"{' …' if len(g['hits']) > 6 else ''})  ")
            L.append(f"  run: `{run}`  ")
            L.append(f"  updates: {', '.join(f'`{o}`' for o in g['outputs'])}")
        L.append("")

    pin_dep = [(r, s) for r in results for s in r.pin_changes + r.dep_changes]
    if pin_dep:
        L.append("## Version pins and dependency bumps")
        L.append("")
        for r, s in pin_dep:
            L.append(f"- {r.name}: {s}")
        L.append("")

    for r in results:
        if r.error or not r.changes:
            continue
        link_base = f"{r.url}/blob/{r.head}"
        L.append(f"## {r.name}: changes by Zig file")
        L.append("")
        by_zig: dict[str, list[Change]] = {}
        for c in r.changes:
            if c.mapping and not c.mapping.catch_all and c.mapping.zig:
                key = ", ".join(f"`{z}`" for z in c.mapping.zig)
                by_zig.setdefault(key, []).append(c)
        if not by_zig:
            L.append("_No changes to ported files._")
            L.append("")
        for key in sorted(by_zig):
            L.append(f"### {key}")
            for c in by_zig[key]:
                L.append(change_line(c, link_base))
            L.append("")

        notp = [c for c in r.changes if c.mapping and not c.mapping.catch_all and not c.mapping.zig
                and c.mapping.status != "n/a"]
        if notp:
            L.append(f"### {r.name}: changes in areas not ported yet")
            L.append("")
            L.append("_Nothing to port now; these widen the parity gap (docs/PARITY.md)._")
            L.append("")
            for c in notp:
                L.append(change_line(c, link_base))
            L.append("")

        unm = [c for c in r.changes if c.mapping is None or c.mapping.catch_all]
        if unm:
            L.append(f"### {r.name}: unmapped changes ⚠")
            L.append("")
            L.append("_Add a mapping for each of these to `tools/upstream/map.json`._")
            L.append("")
            for c in unm:
                L.append(change_line(c, link_base))
            L.append("")

        ign = [c for c in r.changes if c.mapping and not c.mapping.catch_all and not c.mapping.zig
               and c.mapping.status == "n/a"]
        if ign:
            L.append(f"<details><summary>{r.name}: {len(ign)} changed files that need no port</summary>")
            L.append("")
            for c in ign:
                L.append(change_line(c, None))
            L.append("")
            L.append("</details>")
            L.append("")

        if r.commits:
            L.append(f"<details><summary>{r.name}: {len(r.commits)} commits</summary>")
            L.append("")
            for line in r.commits[:200]:
                L.append(f"- {line}")
            if len(r.commits) > 200:
                L.append(f"- … {len(r.commits) - 200} more")
            L.append("")
            L.append("</details>")
            L.append("")

    if not any(r.changed for r in results) and not errs:
        L.append("All upstreams are at their pinned revisions. Nothing to port.")
        L.append("")
    return "\n".join(L)


def truncate_for_issue(md: str) -> str:
    if len(md) <= ISSUE_BODY_LIMIT:
        return md
    cut = md[:ISSUE_BODY_LIMIT].rsplit("\n", 1)[0]
    if cut.count("<details>") > cut.count("</details>"):
        cut += "\n\n</details>"
    return cut + "\n\n_Report truncated; the full report is attached to the workflow run as an artifact._\n"


# --------------------------------------------------------------------------- coverage

def coverage(m: Map, args) -> int:
    """List files in each local upstream tree (at its pinned rev) that only a catch-all (or nothing) covers."""
    missing = 0
    for name, cfg in m.upstreams.items():
        if args.only and name not in args.only:
            continue
        repo = Path(args.local.get(name) or cfg.get("local") or Path(args.cache) / name)
        if not repo.exists():
            print(f"[{name}] no checkout at {repo}; skipped", file=sys.stderr)
            continue
        files = git(repo, "ls-tree", "-r", "--name-only", cfg["pinned"]).splitlines()
        for f in files:
            mp = m.lookup(name, f)
            if mp is None or mp.catch_all:
                print(f"{name}: {f}" + (f"  (catch-all {mp.pattern})" if mp else ""))
                missing += 1
    print(f"{missing} uncovered files", file=sys.stderr)
    return 0


# --------------------------------------------------------------------------- main

def kv(values: list[str]) -> dict[str, str]:
    out = {}
    for v in values:
        if "=" not in v:
            raise SystemExit(f"expected NAME=VALUE, got {v!r}")
        k, val = v.split("=", 1)
        out[k] = val
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--map", default=str(DEFAULT_MAP))
    ap.add_argument("--cache", default=str(DEFAULT_CACHE), help="where upstream clones live (default .upstream-cache/)")
    ap.add_argument("--local", action="append", default=[], metavar="NAME=PATH",
                    help="use an existing checkout instead of cloning")
    ap.add_argument("--head", action="append", default=[], metavar="NAME=REV",
                    help="compare against this revision instead of the fetched branch head")
    ap.add_argument("--only", action="append", default=[], metavar="NAME", help="check only these upstreams")
    ap.add_argument("--include-optional", action="store_true",
                    help="also check upstreams marked optional (gpui-component); always done when a pin moved")
    ap.add_argument("--offline", action="store_true", help="do not clone or fetch")
    ap.add_argument("--out", help="write the Markdown report here (default: stdout)")
    ap.add_argument("--issue-out", help="write a copy truncated to GitHub's issue body limit")
    ap.add_argument("--json", help="write a machine-readable summary here")
    ap.add_argument("--fail-on-changes", action="store_true", help="exit 2 when anything changed")
    ap.add_argument("--coverage", action="store_true", help="list upstream files without a specific mapping")
    ap.add_argument("--bump", action="append", default=[], metavar="NAME",
                    help="set NAME's pinned revision in map.json to the resolved head, then exit")
    args = ap.parse_args()
    args.local, args.head = kv(args.local), kv(args.head)

    m = Map(Path(args.map))
    unknown = [n for n in [*args.only, *args.bump, *args.local, *args.head] if n not in m.upstreams]
    if unknown:
        raise SystemExit(f"unknown upstream(s): {', '.join(unknown)} (known: {', '.join(m.upstreams)})")
    if args.coverage:
        return coverage(m, args)

    if args.bump:
        for name in args.bump:
            repo, head = prepare_repo(name, m.upstreams[name], args)
            date = git(repo, "log", "-1", "--format=%cs", head).strip()
            m.save_pinned(name, head, date)
            print(f"{name}: pinned → {head} ({date})")
        print("Also update the pinned table in docs/UPSTREAM.md.")
        return 0

    names = [n for n in m.upstreams if (not args.only or n in args.only)
             and (not m.upstreams[n].get("optional") or args.include_optional or n in args.only)]
    results = [analyze(n, m.upstreams[n], m, args) for n in names]
    args.paths = {r.name: r.repo for r in results if not r.error}

    # A moved pin pulls in the optional upstream it tracks.
    for r in list(results):
        for pin in m.pins:
            if pin["upstream"] == r.name and any(pin["tracks"] in s and "port " in s for s in r.pin_changes) \
                    and pin["tracks"] not in names and pin["tracks"] in m.upstreams:
                names.append(pin["tracks"])
                results.append(analyze(pin["tracks"], m.upstreams[pin["tracks"]], m, args))

    md = render(results, m, args)
    if args.out:
        Path(args.out).write_text(md)
    else:
        sys.stdout.write(md)
    if args.issue_out:
        Path(args.issue_out).write_text(truncate_for_issue(md))

    has_changes = any(r.changed for r in results)
    if args.json:
        Path(args.json).write_text(json.dumps({
            "has_changes": has_changes,
            "upstreams": [{
                "name": r.name, "pinned": r.pinned, "head": r.head, "error": r.error,
                "commits": len(r.commits),
                "changes": [{"status": c.status, "path": c.path, "old_path": c.old_path,
                             "added": c.added, "deleted": c.deleted,
                             "zig": c.mapping.zig if c.mapping else [],
                             "mapping_status": c.mapping.status if c.mapping else None,
                             "unmapped": c.mapping is None or c.mapping.catch_all} for c in r.changes],
                "generators": [g["name"] for g in r.generators],
                "pin_changes": r.pin_changes, "dep_changes": r.dep_changes,
            } for r in results],
        }, indent=1) + "\n")

    gh_out = os.environ.get("GITHUB_OUTPUT")
    if gh_out:
        with open(gh_out, "a") as f:
            f.write(f"has_changes={'true' if has_changes else 'false'}\n")
            f.write(f"has_errors={'true' if any(r.error for r in results) else 'false'}\n")
            if args.out:
                f.write(f"report={args.out}\n")

    if any(r.error for r in results):
        for r in results:
            if r.error:
                print(f"error: {r.name}: {r.error}", file=sys.stderr)
    if args.fail_on_changes and has_changes:
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
