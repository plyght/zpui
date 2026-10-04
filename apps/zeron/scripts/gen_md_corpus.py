#!/usr/bin/env python3
"""Build the markdown parity corpus (apps/zeron/src/markdown/testdata/).

Inputs: every `original` document from pulldown-cmark 0.12.2's test suite
(CommonMark spec, GFM tables/strikethrough/tasklists, regressions), zeron's
own parser corpora and hand-written tricky cases, plus deterministic fuzz
documents assembled from markdown-significant fragments.

Format (both files): repeated `<byte length>\\n<bytes>\\n`.
  corpus.txt  — documents for full parses (events + trees + mend)
  stream.txt  — documents streamed through IncrementalParser

usage: gen_md_corpus.py <pulldown-cmark-0.12.2 dir> <out dir>
"""
import os, re, sys

pc, out = sys.argv[1], sys.argv[2]
suite = os.path.join(pc, "tests", "suite")
docs = []
for name in ["spec.rs", "gfm_table.rs", "gfm_strikethrough.rs", "gfm_tasklist.rs",
             "table.rs", "strikethrough.rs", "regression.rs", "smart_punct.rs"]:
    src = open(os.path.join(suite, name), encoding="utf-8").read()
    for m in re.finditer(r'let original = r(#*)"(.*?)"\1;', src, re.S):
        docs.append(m.group(2))

ZERON = [
    "# Title\n\nHello **bold** and *italic* and `code` and ~~gone~~.\n",
    "Paragraph one\nlazy continuation\n\nParagraph two with a [link](https://x.dev).\n",
    "- item one\n- item two\n  - nested a\n  - nested b\n- item three\n\ntail\n",
    "1. first\n2. second\n\n   loose paragraph in item\n\n3. third\n",
    "```rust\nfn main() {\n    println!(\"hi\");\n}\n```\n\nafter code\n",
    "intro\n\n```\nunclosed fence streaming",
    "> quoted line\n> more quote\n>\n> - a list in a quote\n\nplain\n",
    "| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |\n\ndone\n",
    "setext candidate\n===\n\nnext para\n---\n",
    "***\n\ntext between rules\n\n---\n",
    "- [x] done task\n- [ ] open task\n",
    "    indented code line one\n    line two\n\npara\n",
    "see [it's here](/tmp/2026/Some Folder/it's here.txt) and `[raw](/tmp/a b.md)`\n",
    "text\n\n```\n[x](/tmp/a b.md)\n```\n\nafter [y](file:///tmp/c d.md)\n",
    "para with <span>inline html</span> inside\n\n<div>\nblock html\n</div>\n",
    "###### deep heading\n\n#### h4\n",
    "Título \U0001f980\r\n\r\nIntro\r\n\r\n- [ ] repetida\r\n  - [X] repetida\r\n\r\n> - [x] citada\r\n\r\n```md\r\n- [ ] literal\r\n```\r\n",
    "\"How do we negotiate with machines that won't speak?\" someone asked.\n\nYuki almost laughed. \"You don't. You listen to the silence. And you finally understand what it means to be powerless.\"",
    "See [docs] for more.\n\nMore text.\n\n[docs]: https://example.com\n",
    "Before [![**alt**](a.png \"Title\")](next.md) after ![](b.png) ![](b.png)",
    "PR is updated: https://github.com/zeronsh/comet/pull/31\n",
    "see https://x.dev/a, then rest.\n",
    "(docs: https://x.dev/Foo_(bar))\n",
    "**see https://x.dev now**\n",
    "foohttps://x.dev is glued\n",
    "the https:// scheme alone\n",
    "`https://x.dev` in code\n",
    "[https://shown.dev](https://real.dev)\n",
    "[label](https://example.com) and https://example.org/path",
    "[x](Some Folder/a.md)", "[x](/usr/bin/some thing)", "[x](file://localhost/tmp/a b.md)",
    "[x](/tmp/a b/c/)", "[x](/tmp/a?b c.md)", "[x](/tmp/../a b.md)",
    "see [it](</tmp/Some Folder/it's here.txt>) now",
    "shot ![two](/tmp/pics/two words.png) done",
    "[x](file:///tmp/a b/c.md)",
    "see [it](/tmp/Some Folder/it's here.txt) and [web](https://x.dev/a b)",
    "    [x](/tmp/a b.md)\n",
    # tricky: nested lists, fences in lists, tables, code spans, emphasis
    "1. one\n   - a\n     - deep\n       1. deeper\n   - b\n2. two\n\n   ```js\n   let x = 1;\n   ```\n3. three\n",
    "- item\n\n  ```python\n  def f():\n      return 1\n  ```\n\n- next\n  ~~~\n  tilde fence\n  ~~~\n",
    "- a\n- b\n\n- c\n",
    "* tight\n* list\n+ new list\n+ again\n",
    "- [ ] todo\n- [x] done\n- [X] Done too\n- [] not a task\n- [ ]\n",
    "1) paren\n2) list\n\n7. starts at seven\n8. eight\n",
    "| Left | Center | Right | None |\n|:-----|:------:|------:|------|\n| `a|b` | **b** | c \\| d | [l](u) |\n| short |\n| 1 | 2 | 3 | 4 | 5 |\n",
    "a | b\n--|--\n1 | 2\n",
    "| only header |\n|---|\n",
    "| a |\n|---|\n| `code with \\| pipe` |\n| x \\\\| y |\n",
    "Inline ``code with ` backtick`` and ` `` ` and `` ` `` and ```triple```.\n",
    "Unclosed `code here and *em*\n",
    "*a **b** c* **a *b* c** ***abc*** **a*b*c** _a_b_ __a__b__ *a*b*\n",
    "foo*bar* foo_bar_ *foo bar * ** not ** __ x__ a * b *\n",
    "~~strike~~ ~one~ ~~~three~~~ a~~b~~c\n",
    "<b>bold html</b> and <!-- comment --> and <?php x ?> and <![CDATA[ x ]]>\n",
    "<details>\n<summary>Hi</summary>\n\nmarkdown *inside*\n\n</details>\n",
    "<script>\nlet a = '**x**';\n</script>\nafter\n",
    "Entities: &amp; &copy; &#35; &#x22; &notanentity; &#0; &#xFFFFFF;\n",
    "Autolinks <https://example.com/a?b=c> and <mailto:me@x.y> and <me@example.com>\n",
    "Hard  \nbreak and soft\nbreak and backslash\\\nbreak\n",
    "Heading with trailing hashes ##\n## Real heading ##\n#nospace\n#\n",
    "> quote\nlazy\n> > nested\n> back\n\n>\n",
    "```mermaid\ngraph TD\n  A-->B\n```\n",
    "```  rust  extra info\ncode\n```\n",
    "````\n```\nnested fence\n```\n````\n",
    "Line one\n===\nLine two\n---\n",
    "para\n-\n", "para\n--\n", "- a\n-\n",
    "[ref link][r] and [collapsed][] and [r]\n\n[r]: /url \"title\"\n[collapsed]: </c d> 'single'\n",
    "\\*escaped\\* \\` \\[ \\] \\\\ \\# done\n",
    "tabs\tin\ttext\n\tindented code with tab\n",
    "  - two space list\n    - nested\n\n        indented code in list\n",
    "Emoji \U0001f600 and ünicode **böld** _ém_\n",
    "word**bold**word word__notbold__word\n",
    "[link with `code`](https://a.b) and [**bold link**](x) and [nested [brackets]](y)\n",
    "![image](i.png) ![alt *em*](j.png 'T')\n",
    "Text ending with backslash\\",
    "Trailing spaces  ",
    "1. a\n\n\n2. b\n",
    "- \n  foo\n",
    "> ```\n> code in quote\n> ```\n",
    "| a | b |\n|---|---|\n| 1 | 2 |\nnot a row\n",
    "text\n| a | b |\n|---|---|\n| 1 | 2 |\n",
]

# Deterministic fuzz documents.
FRAGS = ["**", "*", "_", "__", "`", "``", "~~", "~", "[", "]", "](", ")", "(", "<", ">", "|", "- ", "* ",
         "1. ", "2) ", "> ", "```", "~~~", "    ", "\t", "# ", "## ", "\\", "&amp;", "&#35;", "&nope;",
         "http://x.y/z", "https://a.b/c_(d)", "<a href=\"x\">", "</a>", "<!--", "-->", "[x] ", "[ ] ",
         ": ", "---", "===", "![", " ", "  ", "word", "über", "\U0001f600", "a", "b", "c", "\n", "\n\n",
         "\r\n", "|---|", "| a |", ":-:", "![alt](i.png)", "[t](/tmp/a b.md)", "<https://q.r>",
         "<me@x.io>", "\"", "'", "!", "@", "1", "-", "+", "=", "#"]

def lcg(seed):
    s = seed
    while True:
        s = (s * 6364136223846793005 + 1442695040888963407) & ((1 << 64) - 1)
        yield s >> 33

rng = lcg(0x5eed)
fuzz = []
for k in range(600):
    n = 4 + next(rng) % 40
    parts = [FRAGS[next(rng) % len(FRAGS)] for _ in range(n)]
    fuzz.append("".join(parts))

corpus = docs + ZERON + fuzz
stream = ZERON + [d for d in docs if 30 <= len(d) <= 400][::9] + fuzz[:80]

def write(path, items):
    with open(path, "wb") as f:
        for d in items:
            b = d.encode("utf-8")
            f.write(str(len(b)).encode() + b"\n" + b + b"\n")

write(os.path.join(out, "corpus.txt"), corpus)
write(os.path.join(out, "stream.txt"), stream)
print(f"corpus: {len(corpus)} docs ({len(docs)} suite, {len(ZERON)} zeron, {len(fuzz)} fuzz); stream: {len(stream)}")
