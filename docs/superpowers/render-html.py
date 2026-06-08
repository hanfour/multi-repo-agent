#!/usr/bin/env python3
"""Render OneAD spec/plan markdown files to standalone HTML.

Outputs alongside each .md: <basename>.html — self-contained, no CDN runtime,
just Google Fonts via @import for typography. Style aligns with the OneAD
proposal deck (light theme, no gradients, blue #1E5BFC + orange #F36F3E).

Usage:
    python3 render-html.py                       # render default set
    python3 render-html.py path/to/file.md ...   # render specific files
"""
import re
import sys
from pathlib import Path

import markdown

ROOT = Path(__file__).resolve().parent

DEFAULT_FILES = [
    ROOT / "specs" / "2026-05-29-branch-aware-sync-review-design.md",
]

EXTENSIONS = [
    "toc",
    "tables",
    "fenced_code",
    "codehilite",
    "attr_list",
    "def_list",
    "sane_lists",
    "md_in_html",
]
EXT_CONFIGS = {
    "toc": {"toc_depth": "2-4", "permalink": False, "anchorlink": False},
    "codehilite": {"guess_lang": False, "css_class": "highlight"},
}

CSS = r"""
:root {
  --ink: #0F172A;
  --ink-soft: #475569;
  --muted: #94A3B8;
  --border: #E2E8F0;
  --bg: #FFFFFF;
  --bg-soft: #F8FAFC;
  --primary: #1E5BFC;
  --primary-soft: #E8EFFF;
  --primary-tint: #F5F8FF;
  --orange: #F36F3E;
  --yellow: #ECC94B;
  --coral: #E85D5D;
  --emerald: #16A34A;
  --code-bg: #F1F5F9;
}
* { box-sizing: border-box; }
html, body { margin: 0; padding: 0; }
body {
  font-family: "Noto Sans TC", "PingFang TC", -apple-system, BlinkMacSystemFont,
               "Segoe UI", "Helvetica Neue", Helvetica, Arial, sans-serif;
  color: var(--ink);
  background: var(--bg);
  line-height: 1.7;
  font-size: 15.5px;
}
.layout {
  display: grid;
  grid-template-columns: 280px 1fr;
  min-height: 100vh;
}
aside.toc {
  position: sticky;
  top: 0;
  height: 100vh;
  overflow-y: auto;
  padding: 2em 1.4em 2em 2em;
  background: var(--bg-soft);
  border-right: 1px solid var(--border);
  font-size: 13.5px;
}
aside.toc .toc-eyebrow {
  font-size: 11px;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.1em;
  color: var(--muted);
  margin-bottom: 0.8em;
}
aside.toc .toc-title {
  font-size: 16px;
  font-weight: 700;
  margin-bottom: 1em;
  color: var(--ink);
}
aside.toc ul { list-style: none; padding-left: 0; margin: 0; }
aside.toc li { margin: 0.2em 0; }
aside.toc a {
  color: var(--ink-soft);
  text-decoration: none;
  display: block;
  padding: 0.25em 0.55em;
  border-radius: 4px;
  border-left: 2px solid transparent;
}
aside.toc a:hover { background: var(--primary-soft); color: var(--primary); }
aside.toc ul ul { padding-left: 1em; font-size: 12.5px; }
aside.toc ul ul a { padding: 0.15em 0.55em; }
main.content {
  max-width: 880px;
  padding: 3em 3.5em 6em;
}
.doc-header {
  border-bottom: 2px solid var(--primary);
  padding-bottom: 1.2em;
  margin-bottom: 2em;
}
.doc-header .eyebrow {
  display: inline-block;
  font-size: 11px;
  font-weight: 700;
  letter-spacing: 0.12em;
  text-transform: uppercase;
  color: var(--primary);
  background: var(--primary-soft);
  padding: 0.3em 0.85em;
  border-radius: 999px;
  margin-bottom: 0.7em;
}
.doc-header h1 { font-size: 2.1em; margin: 0.1em 0 0.3em; letter-spacing: -0.02em; }
.doc-header .meta {
  font-size: 13px;
  color: var(--ink-soft);
}
h1, h2, h3, h4, h5, h6 {
  font-weight: 700;
  color: var(--ink);
  margin: 1.8em 0 0.6em;
  letter-spacing: -0.01em;
}
h1 { font-size: 1.9em; border-bottom: 2px solid var(--border); padding-bottom: 0.3em; }
h2 { font-size: 1.5em; border-bottom: 1px solid var(--border); padding-bottom: 0.2em; }
h3 { font-size: 1.2em; color: var(--primary); }
h4 { font-size: 1.05em; }
p { margin: 0.6em 0; }
strong { color: var(--ink); }
em { color: var(--ink-soft); }
a { color: var(--primary); text-decoration: none; }
a:hover { text-decoration: underline; }
hr {
  border: none;
  border-top: 1px solid var(--border);
  margin: 2.5em 0;
}
blockquote {
  margin: 1em 0;
  padding: 0.8em 1.2em;
  background: var(--primary-tint);
  border-left: 4px solid var(--primary);
  border-radius: 0 6px 6px 0;
  color: var(--ink);
}
blockquote p { margin: 0.3em 0; }
ul, ol { margin: 0.4em 0 0.8em; padding-left: 1.5em; }
li { margin: 0.25em 0; }
table {
  width: 100%;
  border-collapse: collapse;
  margin: 1em 0;
  font-size: 0.94em;
  border: 1px solid var(--border);
  border-radius: 6px;
  overflow: hidden;
}
th {
  text-align: left;
  background: var(--primary-tint);
  padding: 0.6em 0.8em;
  font-weight: 700;
  border-bottom: 2px solid var(--primary);
  color: var(--ink);
}
td {
  padding: 0.55em 0.8em;
  border-bottom: 1px solid var(--border);
  vertical-align: top;
}
tr:last-child td { border-bottom: 0; }
tr:hover td { background: var(--bg-soft); }
code {
  background: var(--code-bg);
  padding: 0.12em 0.45em;
  border-radius: 4px;
  font-size: 0.88em;
  font-family: "SF Mono", Menlo, Consolas, monospace;
  color: var(--primary);
  border: 1px solid var(--border);
}
pre {
  background: var(--bg-soft);
  border: 1px solid var(--border);
  border-radius: 6px;
  padding: 0.9em 1.1em;
  overflow-x: auto;
  font-size: 0.84em;
  line-height: 1.55;
  margin: 0.8em 0;
}
pre code {
  background: none;
  padding: 0;
  border: 0;
  color: var(--ink);
  font-size: 1em;
}
.highlight .err { color: inherit; background: none; }
.highlight .k, .highlight .kd, .highlight .kn, .highlight .kr { color: #1E5BFC; font-weight: 600; }
.highlight .s, .highlight .s1, .highlight .s2 { color: #16A34A; }
.highlight .c, .highlight .c1, .highlight .cm { color: #94A3B8; font-style: italic; }
.highlight .n, .highlight .nx { color: var(--ink); }
.highlight .nb, .highlight .bp { color: #F36F3E; }
.highlight .mi, .highlight .mf { color: #E85D5D; }
img { max-width: 100%; height: auto; border-radius: 4px; }
.checkbox-item input[type="checkbox"] { margin-right: 0.4em; }
input[type="checkbox"] { accent-color: var(--primary); }

/* Mermaid diagram container */
.mermaid {
  background: var(--bg-soft);
  border: 1px solid var(--border);
  border-radius: 6px;
  padding: 1.2em 1em;
  margin: 1em 0;
  text-align: center;
  overflow-x: auto;
}
.mermaid svg { max-width: 100%; height: auto; }

/* Pretty up the TOC list rendered by python-markdown */
.toc-rendered > ul { list-style: none; padding-left: 0; }
.toc-rendered ul ul { padding-left: 1.2em; }

/* Print: hide sidebar, single column */
@media print {
  .layout { grid-template-columns: 1fr; }
  aside.toc { display: none; }
  main.content { max-width: none; padding: 1.5em; }
  pre, table { page-break-inside: avoid; }
  h1, h2, h3 { page-break-after: avoid; }
}

@media (max-width: 900px) {
  .layout { grid-template-columns: 1fr; }
  aside.toc { position: relative; height: auto; border-right: 0; border-bottom: 1px solid var(--border); }
  main.content { padding: 2em 1.5em 4em; }
}
"""

HTML_TEMPLATE = """<!DOCTYPE html>
<html lang="zh-Hant">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Noto+Sans+TC:wght@400;500;700&display=swap" rel="stylesheet">
<style>{css}</style>
<script type="module">
  import mermaid from "https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs";
  mermaid.initialize({{
    startOnLoad: true,
    theme: "base",
    themeVariables: {{
      primaryColor: "#E8EFFF",
      primaryTextColor: "#0F172A",
      primaryBorderColor: "#1E5BFC",
      lineColor: "#94A3B8",
      secondaryColor: "#FFEFE6",
      tertiaryColor: "#F8FAFC",
      fontFamily: "Noto Sans TC, sans-serif"
    }}
  }});
</script>
</head>
<body>
<div class="layout">
  <aside class="toc">
    <div class="toc-eyebrow">OneAD Account Management</div>
    <div class="toc-title">{title}</div>
    <div class="toc-rendered">{toc_html}</div>
  </aside>
  <main class="content">
    <div class="doc-header">
      <div class="eyebrow">{kind}</div>
      <h1>{title}</h1>
      <div class="meta">{meta}</div>
    </div>
    {body_html}
  </main>
</div>
</body>
</html>
"""


def extract_title_and_meta(md_text: str, fallback: str) -> tuple[str, str, str]:
    """Pull title from first H1; first ~3 blockquote/meta lines after as meta."""
    lines = md_text.splitlines()
    title = fallback
    meta_lines: list[str] = []
    in_meta = False
    for idx, line in enumerate(lines):
        if line.startswith("# ") and title == fallback:
            title = line[2:].strip()
            in_meta = True
            continue
        if in_meta:
            stripped = line.strip()
            if stripped.startswith(">"):
                meta_lines.append(stripped.lstrip("> ").strip())
            elif stripped == "":
                if meta_lines:
                    break
            else:
                break
    return title, " · ".join(meta_lines[:4]), title


def render(md_path: Path) -> Path:
    md_text = md_path.read_text(encoding="utf-8")
    title, meta, _ = extract_title_and_meta(md_text, md_path.stem)

    # Detect kind for eyebrow
    name = md_path.name.lower()
    if "vision" in name:
        kind = "願景版規格書"
    elif "design" in name:
        kind = "技術詳規格"
    elif "plan" in name or "/plans/" in str(md_path):
        kind = "實作計畫"
    else:
        kind = "文件"

    # ---- Pre-process: extract ```mermaid blocks before markdown converts them ----
    # codehilite/Pygments would treat them as plain code; we want raw text passed
    # through to <div class="mermaid"> so mermaid.js can render in browser.
    mermaid_blocks: list[str] = []

    def _stash_mermaid(match: "re.Match") -> str:
        mermaid_blocks.append(match.group(1))
        return f"<!--MERMAID_PLACEHOLDER_{len(mermaid_blocks) - 1}-->"

    md_text_processed = re.sub(
        r"^```mermaid\n(.*?)\n```$",
        _stash_mermaid,
        md_text,
        flags=re.DOTALL | re.MULTILINE,
    )

    md = markdown.Markdown(extensions=EXTENSIONS, extension_configs=EXT_CONFIGS)
    body_html = md.convert(md_text_processed)

    # markdown TOC is on md.toc / md.toc_tokens
    toc_html = md.toc

    # Strip the first <h1> in the body since the doc-header already shows the title
    body_html = re.sub(r"^<h1[^>]*>.*?</h1>\s*", "", body_html, count=1, flags=re.DOTALL)

    # Convert markdown checkboxes "- [ ]" / "- [x]" — python-markdown doesn't do them by default
    body_html = body_html.replace(
        "<li>[ ]", '<li class="checkbox-item"><input type="checkbox" disabled>'
    ).replace(
        "<li>[x]", '<li class="checkbox-item"><input type="checkbox" disabled checked>'
    )

    # ---- Restore mermaid blocks ----
    for i, raw in enumerate(mermaid_blocks):
        body_html = body_html.replace(
            f"<!--MERMAID_PLACEHOLDER_{i}-->",
            f'<div class="mermaid">\n{raw}\n</div>',
        )

    html = HTML_TEMPLATE.format(
        title=title,
        css=CSS,
        toc_html=toc_html,
        body_html=body_html,
        kind=kind,
        meta=meta,
    )

    out = md_path.with_suffix(".html")
    out.write_text(html, encoding="utf-8")
    return out


def main(args: list[str]) -> int:
    files = [Path(a).resolve() for a in args] if args else DEFAULT_FILES
    for f in files:
        if not f.exists():
            print(f"!! skip (not found): {f}")
            continue
        out = render(f)
        size_kb = out.stat().st_size / 1024
        print(f"✓ {f.name} -> {out.name} ({size_kb:.1f} KB)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
