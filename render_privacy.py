"""Render the checked-in Memlib policy as a static page for the public site."""

from html import escape
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parent
source = (ROOT / "PRIVACY.md").read_text(encoding="utf-8")


def inline(value: str) -> str:
    value = escape(value)
    value = re.sub(r"\[([^]]+)\]\((https?://[^)]+)\)", r'<a href="\2" rel="noopener noreferrer">\1</a>', value)
    value = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", value)
    return value


parts: list[str] = []
paragraph: list[str] = []
in_list = False


def flush_paragraph() -> None:
    if paragraph:
        parts.append("<p>" + inline(" ".join(paragraph)) + "</p>")
        paragraph.clear()


for raw in source.splitlines():
    line = raw.strip()
    if not line:
        flush_paragraph()
        if in_list:
            parts.append("</ul>")
            in_list = False
    elif line.startswith("# "):
        flush_paragraph()
        parts.append(f"<h1>{inline(line[2:])}</h1>")
    elif line.startswith("## "):
        flush_paragraph()
        parts.append(f"<h2>{inline(line[3:])}</h2>")
    elif line.startswith("- "):
        flush_paragraph()
        if not in_list:
            parts.append("<ul>")
            in_list = True
        parts.append(f"<li>{inline(line[2:])}</li>")
    else:
        paragraph.append(line)
flush_paragraph()
if in_list:
    parts.append("</ul>")

body = "\n".join(parts)
body = body.replace("<p><strong>Effective September 26, 2026</strong></p>", '<p class="effective">Effective September 26, 2026</p>')
html = f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="theme-color" content="#6845cc">
  <meta name="description" content="Privacy policy for the Memlib Windows and Android sticker and GIF library.">
  <title>Privacy policy — Memlib</title>
  <link rel="icon" type="image/svg+xml" href="/icon.svg">
  <link rel="stylesheet" href="/style.css">
</head>
<body>
  <div class="site-shell">
    <header class="site-header"><a class="brand" href="/" aria-label="Memlib home"><img src="/icon.svg" alt="" width="42" height="42"><span>Memlib</span></a><nav aria-label="Main navigation"><a href="/">Home</a><a href="https://github.com/sheepkill15/MemLib" rel="noopener noreferrer">Source code</a></nav></header>
    <main class="policy">{body}</main>
    <footer class="site-footer"><span>Memlib · Windows and Android</span><div><a href="/">Home</a><a href="https://github.com/sheepkill15/MemLib/issues/new" rel="noopener noreferrer">Contact via GitHub Issues</a></div></footer>
  </div>
</body>
</html>
"""
target = ROOT / "dist" / "privacy" / "index.html"
target.parent.mkdir(parents=True, exist_ok=True)
target.write_text(html, encoding="utf-8")
print(target)
