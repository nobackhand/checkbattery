#!/usr/bin/env python3
"""
Static validation of docs/index.html for BatteryPill.

Runs anywhere (stdlib only). Designed to catch the regressions that would
otherwise reach production:

  * DANGLING-LINK CHECK   - a root-relative href/src ("/foo") that has no file
                            under docs/ (this is the check that would have
                            caught the original download 404). A path that is a
                            vercel.json redirect `source` is NOT dangling — it
                            is served by a redirect, not a missing file.
  * DOWNLOAD CTA CHECK    - the nav `.dl` and hero `.hero-dl` must point at an
                            https URL OR an existing local file under docs/ OR a
                            vercel.json redirect `source` whose `destination` is
                            an https URL.
  * DOWNLOAD REDIRECT     - every CTA href that is a vercel redirect `source`
                            must resolve to an https `destination` (and that
                            destination should look like a GitHub Releases
                            asset).
  * VERSION PARITY        - every version token in index.html must equal
                            $script:appVersion from BatteryWidget.ps1.
  * OG IMAGE              - og:image / twitter:image filename must exist
                            under docs/.
  * META PRESENCE         - og:title, twitter:card, canonical, theme-color,
                            description must all be present.
  * MOBILE-NAV REGRESSION - the @media (max-width: 520px) block must exist and
                            must NOT contain the dead `.nav-right span` rule;
                            it must handle `.nav-anchor` instead.

Exit code is non-zero if any check FAILs.
"""

import json
import os
import re
import sys
from html.parser import HTMLParser
from urllib.parse import urlparse

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOCS_DIR = os.path.join(REPO_ROOT, "docs")
INDEX_HTML = os.path.join(DOCS_DIR, "index.html")
WIDGET_PS1 = os.path.join(REPO_ROOT, "BatteryWidget.ps1")
VERCEL_JSON = os.path.join(REPO_ROOT, "vercel.json")


# ---------------------------------------------------------------------------
# Result tracking
# ---------------------------------------------------------------------------
class Results:
    def __init__(self):
        self.rows = []  # (name, ok, detail)

    def add(self, name, ok, detail=""):
        self.rows.append((name, bool(ok), detail))

    def passed(self):
        return all(ok for _, ok, _ in self.rows)

    def report(self):
        print("=" * 64)
        print("docs/index.html static checks")
        print("=" * 64)
        for name, ok, detail in self.rows:
            tag = "PASS" if ok else "FAIL"
            line = f"[{tag}] {name}"
            if detail:
                line += f"\n        {detail}"
            print(line)
        print("-" * 64)
        n_fail = sum(1 for _, ok, _ in self.rows if not ok)
        if n_fail:
            print(f"RESULT: {n_fail} check(s) FAILED")
        else:
            print("RESULT: all checks PASSED")
        print("=" * 64)


# ---------------------------------------------------------------------------
# HTML parsing
# ---------------------------------------------------------------------------
class LinkExtractor(HTMLParser):
    """Collect every href/src plus the attribute dict of the tag carrying it,
    and collect all <meta>/<link> tags for the meta-presence checks."""

    URL_ATTRS = ("href", "src")

    def __init__(self):
        super().__init__()
        self.links = []   # list of (url, tag, attrs_dict)
        self.metas = []   # list of attrs_dict for <meta>
        self.link_tags = []  # list of attrs_dict for <link>

    def handle_starttag(self, tag, attrs):
        attrs_d = {k: (v if v is not None else "") for k, v in attrs}
        if tag == "meta":
            self.metas.append(attrs_d)
        if tag == "link":
            self.link_tags.append(attrs_d)
        for a in self.URL_ATTRS:
            if a in attrs_d:
                self.links.append((attrs_d[a], tag, attrs_d))


def read_text(path):
    with open(path, "r", encoding="utf-8") as fh:
        return fh.read()


def load_vercel_redirects():
    """Parse vercel.json and return (sources, src_to_dest).

    `sources` is the set of redirect `source` paths; `src_to_dest` maps each
    source to its `destination`. Tolerates vercel.json being absent, the
    `redirects` key being absent, or individual entries lacking source/dest.
    """
    sources = set()
    src_to_dest = {}
    if not os.path.isfile(VERCEL_JSON):
        return sources, src_to_dest
    try:
        with open(VERCEL_JSON, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (ValueError, OSError):
        return sources, src_to_dest
    redirects = data.get("redirects", []) if isinstance(data, dict) else []
    if not isinstance(redirects, list):
        return sources, src_to_dest
    for entry in redirects:
        if not isinstance(entry, dict):
            continue
        src = entry.get("source")
        if not isinstance(src, str) or not src:
            continue
        sources.add(src)
        dest = entry.get("destination")
        src_to_dest[src] = dest if isinstance(dest, str) else None
    return sources, src_to_dest


def is_remote(url):
    """True if url is an absolute http(s) URL or protocol-relative."""
    p = urlparse(url)
    if p.scheme in ("http", "https"):
        return True
    if url.startswith("//"):
        return True
    return False


def is_data_or_anchor(url):
    if not url:
        return True
    if url.startswith("#"):
        return True
    if url.startswith("data:"):
        return True
    if url.startswith("mailto:") or url.startswith("tel:"):
        return True
    return False


def docs_path_for_root_relative(url):
    """Map a root-relative URL ("/foo/bar.png") to a filesystem path under
    docs/. Strips query string and fragment. '/' maps to docs/index.html."""
    path = url.split("#", 1)[0].split("?", 1)[0]
    path = path.lstrip("/")
    if path == "" or path.endswith("/"):
        path = path + "index.html"
    return os.path.join(DOCS_DIR, path)


# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------
def get_app_version():
    txt = read_text(WIDGET_PS1)
    m = re.search(r'\$script:appVersion\s*=\s*"([0-9]+\.[0-9]+\.[0-9]+)"', txt)
    if not m:
        return None
    return m.group(1)


def check_dangling_links(results, links, redirect_sources):
    bad = []
    for url, tag, _attrs in links:
        if is_data_or_anchor(url) or is_remote(url):
            continue
        if url.startswith("/"):
            # A root-relative href that exactly matches a vercel redirect
            # source is served by that redirect, not a file under docs/ —
            # it is NOT dangling.
            if url in redirect_sources:
                continue
            fs = docs_path_for_root_relative(url)
            if not os.path.isfile(fs):
                bad.append(f"{tag} -> {url} (expected {os.path.relpath(fs, REPO_ROOT)})")
    if bad:
        results.add("dangling root-relative links", False,
                    "; ".join(bad))
    else:
        results.add("dangling root-relative links", True,
                    "all root-relative paths resolve to files under docs/ "
                    "or to a vercel.json redirect source")


def find_cta(links, cls):
    """Find the href of the first <a> whose class attr contains cls as a token."""
    for url, tag, attrs in links:
        if tag != "a":
            continue
        classes = attrs.get("class", "").split()
        if cls in classes:
            return url
    return None


def check_download_ctas(results, links, redirect_sources, src_to_dest):
    targets = {"nav .dl": "dl", "hero .hero-dl": "hero-dl"}
    problems = []
    found_any = False
    for label, cls in targets.items():
        href = find_cta(links, cls)
        if href is None:
            problems.append(f"{label}: no <a class='{cls}'> found")
            continue
        found_any = True
        # (a) https URL -> OK (direct GitHub Releases link)
        if is_remote(href):
            continue
        if is_data_or_anchor(href):
            problems.append(f"{label}: href '{href}' is not a download target")
            continue
        # (c) vercel redirect source whose destination is an https URL -> OK
        if href in redirect_sources:
            dest = src_to_dest.get(href)
            if isinstance(dest, str) and is_remote(dest):
                continue
            problems.append(
                f"{label}: href '{href}' is a vercel redirect source but its "
                f"destination is {dest!r} (not an https URL)"
            )
            continue
        # (b) local path: root-relative or relative — must exist under docs/
        if href.startswith("/"):
            fs = docs_path_for_root_relative(href)
        else:
            fs = os.path.join(DOCS_DIR, href.split("#")[0].split("?")[0])
        if not os.path.isfile(fs):
            problems.append(
                f"{label}: local href '{href}' has no file "
                f"({os.path.relpath(fs, REPO_ROOT)} missing) and is not a "
                "vercel.json redirect source."
            )
    if problems:
        results.add("download CTAs (nav .dl / hero .hero-dl)", False,
                    "; ".join(problems))
    elif found_any:
        results.add("download CTAs (nav .dl / hero .hero-dl)", True,
                    "both CTAs are https URLs, existing local files, or "
                    "vercel redirects to an https destination")
    else:
        results.add("download CTAs (nav .dl / hero .hero-dl)", False,
                    "neither CTA element was found")


def check_download_redirect_resolves(results, links, redirect_sources,
                                     src_to_dest):
    """For every CTA whose href is a vercel redirect source, assert the
    redirect destination is an https URL (bonus: looks like a GitHub Releases
    asset). If no CTA uses a redirect, the check is informational (PASS)."""
    targets = {"nav .dl": "dl", "hero .hero-dl": "hero-dl"}
    problems = []
    resolved = []
    used_redirect = False
    for label, cls in targets.items():
        href = find_cta(links, cls)
        if href is None or href not in redirect_sources:
            continue
        used_redirect = True
        dest = src_to_dest.get(href)
        if not isinstance(dest, str) or not dest:
            problems.append(
                f"{label}: redirect source '{href}' has no destination "
                "in vercel.json"
            )
            continue
        if not is_remote(dest):
            problems.append(
                f"{label}: redirect '{href}' -> '{dest}' is not an https URL"
            )
            continue
        note = ""
        if not re.search(r'github\.com/.+/releases/', dest):
            note = " (warning: destination does not look like a GitHub "
            note += "Releases asset)"
        resolved.append(f"{href} -> {dest}{note}")
    if problems:
        results.add("download redirect resolves", False, "; ".join(problems))
    elif used_redirect:
        results.add("download redirect resolves", True, "; ".join(resolved))
    else:
        results.add("download redirect resolves", True,
                    "no CTA uses a vercel redirect source (direct https or "
                    "local file)")


def check_version_parity(results, html_text, app_version):
    if app_version is None:
        results.add("version parity", False,
                    "could not read $script:appVersion from BatteryWidget.ps1")
        return
    # Find every version token: optional leading 'v', X.Y.Z
    tokens = set(re.findall(r'v?\d+\.\d+\.\d+', html_text))
    if not tokens:
        results.add("version parity", False,
                    "no version string found in index.html")
        return
    mismatches = sorted(t for t in tokens if t.lstrip("v") != app_version)
    if mismatches:
        results.add("version parity", False,
                    f"appVersion={app_version} but index.html has: "
                    f"{', '.join(mismatches)}")
    else:
        results.add("version parity", True,
                    f"all {len(tokens)} version token(s) match appVersion "
                    f"{app_version}")


def check_og_image(results, metas):
    filenames = []
    for m in metas:
        key = m.get("property", "") or m.get("name", "")
        if key in ("og:image", "twitter:image"):
            content = m.get("content", "")
            if content:
                # take the basename of the URL/path
                fname = content.split("#")[0].split("?")[0].rstrip("/")
                fname = fname.rsplit("/", 1)[-1]
                filenames.append((key, content, fname))
    if not filenames:
        results.add("og:image / twitter:image exists", False,
                    "no og:image or twitter:image meta tag found")
        return
    missing = []
    for key, content, fname in filenames:
        fs = os.path.join(DOCS_DIR, fname)
        if not os.path.isfile(fs):
            missing.append(f"{key} -> {content} (no docs/{fname})")
    if missing:
        results.add("og:image / twitter:image exists", False,
                    "; ".join(missing))
    else:
        results.add("og:image / twitter:image exists", True,
                    "image filename(s) exist under docs/: "
                    + ", ".join(sorted({f for _, _, f in filenames})))


def check_meta_presence(results, metas, link_tags):
    have = set()
    for m in metas:
        prop = m.get("property", "")
        name = m.get("name", "")
        if prop == "og:title":
            have.add("og:title")
        if name == "twitter:card":
            have.add("twitter:card")
        if name == "theme-color":
            have.add("theme-color")
        if name == "description" and m.get("content", "").strip():
            have.add("description")
    for lt in link_tags:
        rels = lt.get("rel", "").split()
        if "canonical" in rels:
            have.add("canonical")
    required = ["og:title", "twitter:card", "canonical", "theme-color",
                "description"]
    missing = [r for r in required if r not in have]
    if missing:
        results.add("required meta tags present", False,
                    "missing: " + ", ".join(missing))
    else:
        results.add("required meta tags present", True,
                    "found: " + ", ".join(required))


def check_mobile_nav(results, html_text):
    # Locate the @media (max-width: 520px) { ... } block.
    m = re.search(r'@media\s*\(\s*max-width:\s*520px\s*\)\s*\{', html_text)
    if not m:
        results.add("mobile-nav @media(520px) block", False,
                    "no '@media (max-width: 520px)' block found")
        return
    # Walk braces from the opening brace to find the matching close.
    start = m.end() - 1  # index of the '{'
    depth = 0
    end = None
    for i in range(start, len(html_text)):
        c = html_text[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                end = i
                break
    block = html_text[start:end + 1] if end else html_text[start:]

    problems = []
    # Old dead rule must be gone.
    if re.search(r'\.nav-right\s+span\b', block):
        problems.append("contains dead '.nav-right span' rule")
    # New handling must be present.
    if not re.search(r'\.nav-anchor\b', block):
        problems.append("does not handle '.nav-anchor'")

    if problems:
        results.add("mobile-nav regression guard", False,
                    "; ".join(problems))
    else:
        results.add("mobile-nav regression guard", True,
                    "520px block handles .nav-anchor and has no dead "
                    ".nav-right span rule")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    if not os.path.isfile(INDEX_HTML):
        print(f"FATAL: {INDEX_HTML} not found", file=sys.stderr)
        return 2
    if not os.path.isfile(WIDGET_PS1):
        print(f"FATAL: {WIDGET_PS1} not found", file=sys.stderr)
        return 2

    html_text = read_text(INDEX_HTML)
    parser = LinkExtractor()
    parser.feed(html_text)

    app_version = get_app_version()
    redirect_sources, src_to_dest = load_vercel_redirects()
    results = Results()

    check_dangling_links(results, parser.links, redirect_sources)
    check_download_ctas(results, parser.links, redirect_sources, src_to_dest)
    check_download_redirect_resolves(results, parser.links, redirect_sources,
                                     src_to_dest)
    check_version_parity(results, html_text, app_version)
    check_og_image(results, parser.metas)
    check_meta_presence(results, parser.metas, parser.link_tags)
    check_mobile_nav(results, html_text)

    results.report()
    return 0 if results.passed() else 1


if __name__ == "__main__":
    sys.exit(main())
