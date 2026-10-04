#!/usr/bin/env python3
"""Build the diff parity corpus (apps/zeron/src/diff/testdata/).

patches.txt — unified patches: hand-written edge cases plus real `git show`
              output from the zeron repository (renames, binaries, modes).
pairs.txt   — (old, new) text pairs, consecutive records; an old of "\\0"
              means "no old text" (new file) for diff_to_file.
Format: repeated `<byte length>\\n<bytes>\\n`.

usage: gen_diff_corpus.py <zeron repo> <out dir>
"""
import os, subprocess, sys

repo, out = sys.argv[1], sys.argv[2]

PATCHES = [
    "diff --git a/x b/x\n@@ -1 +1 @@\n-a\n+b\n",
    "diff --git a/src/lib.rs b/src/lib.rs\nindex 1111111..2222222 100644\n--- a/src/lib.rs\n+++ b/src/lib.rs\n@@ -10,7 +10,8 @@ fn main() {\n     let a = 1;\n-    let b = 2;\n+    let b = 3;\n+    let c = 4;\n     println!(\"{a}\");\n \n     done();\n }\n",
    "diff --git a/new.txt b/new.txt\nnew file mode 100644\nindex 0000000..e69de29\n--- /dev/null\n+++ b/new.txt\n@@ -0,0 +1,2 @@\n+hello\n+world\n",
    "diff --git a/gone.txt b/gone.txt\ndeleted file mode 100644\nindex e69de29..0000000\n--- a/gone.txt\n+++ /dev/null\n@@ -1,2 +0,0 @@\n-hello\n-world\n",
    "diff --git a/old name.txt b/new name.txt\nsimilarity index 90%\nrename from old name.txt\nrename to new name.txt\nindex 1..2 100644\n--- a/old name.txt\n+++ b/new name.txt\n@@ -1,3 +1,3 @@\n a\n-b\n+B\n c\n",
    "diff --git \"a/sp ace/\\\"q\\\".txt\" \"b/sp ace/\\\"q\\\".txt\"\nindex 1..2 100644\n--- \"a/sp ace/\\\"q\\\".txt\"\n+++ \"b/sp ace/\\\"q\\\".txt\"\n@@ -1 +1 @@\n-x\n+y\n",
    "diff --git a/img.png b/img.png\nindex 1..2 100644\nBinary files a/img.png and b/img.png differ\n",
    "diff --git a/bin.dat b/bin.dat\nnew file mode 100644\nindex 0000000..1234567\nGIT binary patch\nliteral 10\nRcmZQzU|?WiU|?Wk0002A0RR91\n\nliteral 0\nHcmV?d00001\n\n",
    "diff --git a/run.sh b/run.sh\nold mode 100644\nnew mode 100755\n",
    "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1,2 +1,2 @@\n-old last\n\\ No newline at end of file\n+new last\n\\ No newline at end of file\n",
    "diff --git a/crlf.txt b/crlf.txt\r\n--- a/crlf.txt\r\n+++ b/crlf.txt\r\n@@ -1,2 +1,2 @@\r\n line\r\n-old\r\n+new\r\n",
    "diff --git a/e.txt b/e.txt\n@@ -5 +5,2 @@\n context\n\n+added after empty\n--- not a header\n+++ not a header either\n",
    "garbage before any file\n@@ -1 +1 @@\n-x\n+y\ndiff --git a/after b/after\n@@ -3,0 +4 @@ heading text\n+one\n@@ bad header @@\n+still in previous hunk\n@@ -100,3 +200,4 @@\n x\n-y\n+z\n+w\n z2\n",
    "diff --git a/m b/m\n@@ -1,4 +1,4 @@\n-a\n-b\n+c\n x\n-d\n+e\n+f\n+g\n",
    "diff --git a/u b/u\n@@ -9998,3 +9998,4 @@\n é\n-ü\n+ö\n+日本\n 🦀\n",
    "diff --git a/p b/q\n--- a/p\n+++ b/q\n@@ -1 +1 @@\n-p\n+q\n",
    "diff --git a/x b/x\n@@ -1,2 +1,2 @@\n x\n@@ -10,2 +10,2 @@\n-a\n+b\n\\ marker\n",
    "diff --git a/one b/one\n@@ -1 +1 @@\n-1\n+2\ndiff --git a/two b/two\nnew file mode 100644\n@@ -0,0 +1 @@\n+t\n",
    "",
    "diff --git a/only-header b/only-header\nindex 1..2\n",
    "diff --git a/tab\tname b/tab\tname\n@@ -1 +1 @@\n-\ta\n+\tb\n",
]

def git(*args):
    return subprocess.run(["git", "-C", repo, *args], capture_output=True, check=True).stdout.decode("utf-8", "replace")

commits = git("log", "--format=%H", "-n", "80").split()
real = []
for c in commits:
    p = git("show", "--format=", "-M", "--summary", c)
    if 0 < len(p) <= 40000:
        real.append(p)
    if len(real) >= 25:
        break
# Commits with renames anywhere in history.
for c in git("log", "--all", "--diff-filter=R", "--format=%H").split()[:3]:
    p = git("show", "--format=", "-M", c)
    real.append(p[:60000])

patches = PATCHES + real

# Text pairs.
def lcg(seed):
    s = seed
    while True:
        s = (s * 6364136223846793005 + 1442695040888963407) & ((1 << 64) - 1)
        yield s >> 33

PAIRS = [
    ("", ""), ("", "a\n"), ("a\n", ""), ("a\nb\nc\n", "a\nb\nc\n"), ("a\nb\nc", "a\nB\nc"),
    ("a\nb\nc\n", "a\nb\nc"), ("one\r\ntwo\r\n", "one\r\nTWO\r\n"), ("x\ry\rz", "x\rY\rz"),
    ("\0", "brand new\nfile\n"), ("\0", ""),
    ("Hello World\nsome stuff here\nsome more stuff here\n\nAha stuff here\nand more stuff",
     "Stuff\nHello World\nsome amazing stuff here\nsome more stuff here\n"),
    (">>>>\na\nb\nc\n====\nd\ne\nf\n<<<<\n", ">>>>\nx\nb\nc\n====\ny\ne\nf\n<<<<\n"),
    ("a\na\na\nb\na\na\n", "a\nb\na\na\na\na\n"),
    ("fn main() {\n    let x = 1;\n}\n", "fn main() {\n    let x = 2;\n    let y = 3;\n}\n"),
    ("The quick brown fox jumps over the lazy dog.\n", "The quick red fox leaped over the lazy cat!\n"),
    ("alpha beta gamma\ndelta epsilon\n", "alpha BETA gamma\ndelta  epsilon zeta\n"),
    ("unicode: über café 日本語\n", "unicode: uber café 日本\n"),
    ("tabs\tand  spaces\n", "tabs  and\tspaces\n"),
    ("\n\n\n", "\n\n"), ("a\n\nb\n\nc\n", "a\nb\nc\n"),
    ("".join(f"line {i}\n" for i in range(60)), "".join(f"line {i}\n" for i in range(60) if i % 7) + "tail\n"),
]

src_files = ["crates/markdown/src/mend.rs", "crates/markdown/src/parser.rs", "crates/ui/src/markdown/links.rs",
             "Cargo.toml", "crates/ui/src/markdown/mermaid.rs"]
rng = lcg(0xd1ff)
words = ["foo", "bar", "baz", "qux", "let", "fn", "x", "=", "1;", "(", ")", "{", "}", "self", "\t", "  "]
mut = []
for path in src_files:
    try:
        text = open(os.path.join(repo, path), encoding="utf-8").read()
    except OSError:
        continue
    lines = text.splitlines(keepends=True)
    for k in range(12):
        start = next(rng) % max(1, len(lines) - 200)
        base = lines[start:start + 20 + next(rng) % 60]
        new = list(base)
        for _ in range(1 + next(rng) % 8):
            if not new:
                break
            i = next(rng) % len(new)
            op = next(rng) % 5
            if op == 0:
                del new[i]
            elif op == 1:
                new.insert(i, " ".join(words[next(rng) % len(words)] for _ in range(1 + next(rng) % 6)) + "\n")
            elif op == 2:
                ws = new[i].split(" ")
                j = next(rng) % len(ws)
                ws[j] = words[next(rng) % len(words)]
                new[i] = " ".join(ws)
            elif op == 3:
                new.insert(i, new[i])
            else:
                j = next(rng) % len(new)
                new[i], new[j] = new[j], new[i]
        mut.append(("".join(base), "".join(new)))

pairs = PAIRS + mut

def write(path, items):
    with open(path, "wb") as f:
        for d in items:
            b = d.encode("utf-8")
            f.write(str(len(b)).encode() + b"\n" + b + b"\n")

write(os.path.join(out, "patches.txt"), patches)
write(os.path.join(out, "pairs.txt"), [x for p in pairs for x in p])
print(f"patches: {len(patches)} ({len(real)} from git); pairs: {len(pairs)}")
