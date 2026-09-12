#!/usr/bin/env python3
"""Download the content of an authenticated extranet to a local directory.

Two steps, on purpose:

  1. ``login``  opens a real browser window, you sign in by hand (so 2FA,
     captchas and any unusual form all just work), and the session is saved
     to a state file. Credentials are never written to disk.
  2. ``crawl``  replays that session headlessly, walks the site and mirrors
     pages and files locally. It is resumable: interrupt it and run it again.

Only use this against an account you are entitled to use, and check the
portal's terms of service first -- bulk mirroring is often restricted.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import time
from collections import deque
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urljoin, urlsplit, urlunsplit

try:
    from playwright.sync_api import Error as PlaywrightError
    from playwright.sync_api import TimeoutError as PlaywrightTimeout
    from playwright.sync_api import sync_playwright
except ImportError:  # pragma: no cover - dependency hint
    sys.exit(
        "Playwright is missing. Install it with:\n"
        "    pip install -r requirements.txt\n"
        "    playwright install chromium"
    )

DEFAULT_START_URL = "https://extranet.nobilia.de/"
DEFAULT_USER_AGENT = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"
)

# Links that would end the session, or that lead nowhere useful.
LOGOUT_RE = re.compile(
    r"log[-_]?out|log[-_]?off|sign[-_]?out|abmeld|ausloggen|d[ée]connex|disconnect", re.I
)
LOGIN_RE = re.compile(r"login|anmeld|sign[-_]?in|/auth|sso", re.I)
SKIP_SCHEMES = {"mailto", "tel", "javascript", "data", "blob", "about", "ftp"}

# Extensions fetched directly through the HTTP client instead of the renderer.
BINARY_EXTENSIONS = {
    ".pdf", ".zip", ".rar", ".7z", ".gz", ".tgz", ".tar",
    ".doc", ".docx", ".xls", ".xlsx", ".xlsm", ".ppt", ".pptx", ".csv", ".rtf", ".txt",
    ".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp", ".tif", ".tiff", ".svg", ".ico",
    ".mp4", ".mov", ".avi", ".wmv", ".mp3", ".wav",
    ".dwg", ".dxf", ".step", ".stp", ".iges", ".igs", ".3ds", ".obj", ".skp",
    ".xml", ".json", ".eps", ".ai", ".indd", ".psd", ".exe", ".msi", ".dat",
}
EXTENSION_BY_CONTENT_TYPE = {
    "application/pdf": ".pdf",
    "application/zip": ".zip",
    "application/msword": ".doc",
    "application/vnd.ms-excel": ".xls",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document": ".docx",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": ".xlsx",
    "application/vnd.openxmlformats-officedocument.presentationml.presentation": ".pptx",
    "application/json": ".json",
    "text/csv": ".csv",
    "text/plain": ".txt",
    "text/xml": ".xml",
    "image/jpeg": ".jpg",
    "image/png": ".png",
    "image/gif": ".gif",
    "image/webp": ".webp",
    "image/svg+xml": ".svg",
}
HTML_CONTENT_TYPES = ("text/html", "application/xhtml+xml")


INSPECT_PROBE = """
() => {
  const d = document, w = window;
  const abs = (els, attr) => [...els].map(e => e[attr]).filter(Boolean);
  const navSel = 'nav a[href], [role=navigation] a[href], header a[href],'
               + ' .nav a[href], .menu a[href], #menu a[href], aside a[href],'
               + ' .sidebar a[href], ul.navigation a[href]';
  return {
    title: d.title || '',
    links: abs(d.querySelectorAll('a[href]'), 'href'),
    navLinks: abs(d.querySelectorAll(navSel), 'href'),
    downloadLinks: abs(d.querySelectorAll('a[download]'), 'href'),
    iframes: abs(d.querySelectorAll('iframe[src]'), 'src'),
    forms: d.querySelectorAll('form').length,
    buttons: d.querySelectorAll('button, input[type=button], input[type=submit]').length,
    tables: d.querySelectorAll('table').length,
    selects: d.querySelectorAll('select').length,
    textLength: d.body ? (d.body.innerText || '').length : 0,
    frameworks: {
      react: !!(w.React || d.querySelector('[data-reactroot], #root, #react-root')),
      angular: !!(w.angular || d.querySelector('[ng-version], [ng-app], app-root')),
      vue: !!(w.Vue || d.querySelector('[data-v-app], #app[data-v-app]')),
      next: !!d.querySelector('#__NEXT_DATA__'),
      nuxt: !!w.__NUXT__,
      jquery: !!w.jQuery,
      sharepoint: !!(w._spPageContextInfo || d.querySelector('#s4-workspace')),
    },
  };
}
"""

LINK_EXTRACTOR = """
() => {
  const out = [];
  const push = (v) => { if (v) out.push(v); };
  document.querySelectorAll('a[href], area[href]').forEach(e => push(e.href));
  document.querySelectorAll('iframe[src], embed[src], frame[src]').forEach(e => push(e.src));
  document.querySelectorAll('object[data]').forEach(e => push(e.data));
  return out;
}
"""


def log(message: str, logfile: Path | None = None) -> None:
    line = f"[{datetime.now().strftime('%H:%M:%S')}] {message}"
    print(line, flush=True)
    if logfile is not None:
        with logfile.open("a", encoding="utf-8") as handle:
            handle.write(line + "\n")


def normalize_url(url: str) -> str:
    """Drop the fragment and normalise host casing so we visit each URL once."""
    parts = urlsplit(url)
    netloc = parts.netloc.lower()
    if netloc.endswith(":443") and parts.scheme == "https":
        netloc = netloc[:-4]
    elif netloc.endswith(":80") and parts.scheme == "http":
        netloc = netloc[:-3]
    path = parts.path or "/"
    return urlunsplit((parts.scheme.lower(), netloc, path, parts.query, ""))


def sanitize_segment(segment: str) -> str:
    cleaned = re.sub(r'[<>:"\\|?*\x00-\x1f]', "_", segment).strip(" .")
    if len(cleaned) > 120:
        digest = hashlib.sha1(segment.encode("utf-8")).hexdigest()[:8]
        cleaned = f"{cleaned[:100]}__{digest}"
    return cleaned or "_"


def local_path_for(url: str, root: Path, kind: str) -> Path:
    """Map a URL onto a local file path that mirrors the site structure."""
    parts = urlsplit(url)
    path = parts.path
    if not path or path.endswith("/"):
        path += "index.html"
    segments = [sanitize_segment(s) for s in path.lstrip("/").split("/") if s not in ("", ".", "..")]
    if not segments:
        segments = ["index.html"]

    name = segments[-1]
    if parts.query:
        # Two URLs differing only by query string must not collide on disk.
        digest = hashlib.sha1(parts.query.encode("utf-8")).hexdigest()[:8]
        stem, dot, ext = name.partition(".")
        name = f"{stem}__q{digest}{dot}{ext}" if dot else f"{name}__q{digest}"
    if kind == "page" and not name.lower().endswith((".html", ".htm")):
        name += ".html"
    segments[-1] = name

    return root.joinpath(parts.netloc.lower(), *segments)


def make_writable(path: Path) -> Path:
    """Resolve file/directory clashes (``/a`` as both a page and a folder)."""
    parts = path.parts
    current = Path(parts[0])
    for segment in parts[1:-1]:
        candidate = current / segment
        if candidate.exists() and not candidate.is_dir():
            candidate = current / (segment + ".d")
        current = candidate
    target = current / path.name
    if target.exists() and target.is_dir():
        target = target / "index.html"
    target.parent.mkdir(parents=True, exist_ok=True)
    return target


def looks_binary(url: str) -> bool:
    return Path(urlsplit(url).path).suffix.lower() in BINARY_EXTENSIONS


class Manifest:
    """Crawl state on disk, so an interrupted run can pick up where it stopped."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self.done: dict[str, dict] = {}
        self.queue: deque[tuple[str, int]] = deque()
        self.started_at = datetime.now(timezone.utc).isoformat(timespec="seconds")
        if path.exists():
            data = json.loads(path.read_text(encoding="utf-8"))
            self.done = data.get("done", {})
            self.queue = deque((u, int(d)) for u, d in data.get("queue", []))
            self.started_at = data.get("started_at", self.started_at)

    def save(self) -> None:
        payload = {
            "started_at": self.started_at,
            "updated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "done": self.done,
            "queue": [[u, d] for u, d in self.queue],
        }
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(payload, indent=2, ensure_ascii=False), encoding="utf-8")
        tmp.replace(self.path)

    def record(self, url: str, **fields) -> None:
        fields["ts"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
        self.done[url] = fields

    @property
    def ok_count(self) -> int:
        return sum(1 for v in self.done.values() if v.get("status") == "ok")


def build_context(playwright, args, headless: bool):
    launch_kwargs = {"headless": headless}
    browser_path = args.browser_path or os.environ.get("PLAYWRIGHT_CHROMIUM_PATH")
    if browser_path:
        launch_kwargs["executable_path"] = browser_path
    browser = playwright.chromium.launch(**launch_kwargs)
    state = Path(args.state)
    context = browser.new_context(
        storage_state=str(state) if state.exists() else None,
        user_agent=args.user_agent,
        accept_downloads=True,
        ignore_https_errors=False,
        locale="de-DE",
    )
    context.set_default_timeout(args.timeout * 1000)
    return browser, context


def cmd_login(args) -> int:
    state = Path(args.state)
    state.parent.mkdir(parents=True, exist_ok=True)

    with sync_playwright() as playwright:
        browser, context = build_context(playwright, args, headless=False)
        page = context.new_page()
        log(f"Opening {args.url}")
        page.goto(args.url, wait_until="domcontentloaded")

        if args.auto:
            user = os.environ.get("EXTRANET_USER")
            password = os.environ.get("EXTRANET_PASSWORD")
            if not user or not password:
                log("EXTRANET_USER / EXTRANET_PASSWORD not set - falling back to manual login.")
            else:
                try:
                    password_field = page.locator("input[type=password]").first
                    password_field.wait_for(state="visible", timeout=15000)

                    # Prefer the user field belonging to the password field's own form.
                    user_selector = "input[type=text], input[type=email], input:not([type])"
                    form = password_field.locator("xpath=ancestor::form[1]")
                    text_field = form.locator(user_selector).first
                    if text_field.count() == 0:
                        text_field = page.locator(user_selector).first

                    text_field.fill(user)
                    password_field.fill(password)
                    password_field.press("Enter")
                    page.wait_for_timeout(3000)
                    log(f"Login submitted - now at {page.url}")
                    log("Finish anything left (2FA, cookie banner) in the browser window.")
                except (PlaywrightError, PlaywrightTimeout) as err:
                    log(f"Could not autofill the login form ({err.__class__.__name__}) - do it by hand.")

        print()
        print("=" * 72)
        print("  Sign in inside the browser window, navigate to the logged-in")
        print("  home page, then come back here and press ENTER to save the session.")
        print("=" * 72)
        print()
        try:
            input("Press ENTER once you are logged in... ")
        except (EOFError, KeyboardInterrupt):
            log("Aborted - session not saved.")
            browser.close()
            return 1

        try:
            landing = page.url
        except PlaywrightError:
            landing = args.url
        context.storage_state(path=str(state))
        browser.close()

    log(f"Session saved to {state} (landing page: {landing})")
    log("It holds cookies, not your password. Keep it private and delete it when done.")
    return 0


class Crawler:
    def __init__(self, args, context, manifest: Manifest, logfile: Path) -> None:
        self.args = args
        self.context = context
        self.manifest = manifest
        self.logfile = logfile
        self.pages_root = Path(args.out) / "pages"
        self.files_root = Path(args.out) / "files"
        self.allowed_hosts = {urlsplit(args.url).netloc.lower()} | {
            h.lower() for h in args.allow_host
        }
        self.include_re = re.compile(args.include) if args.include else None
        self.exclude_re = re.compile(args.exclude) if args.exclude else None
        self.login_redirects = 0
        self.saved_this_run = 0
        self.downloaded_bytes = 0
        context.on("download", self._on_download)

    def _log(self, message: str) -> None:
        log(message, self.logfile)

    def _on_download(self, download) -> None:
        """Catch downloads triggered by navigation or by in-page buttons."""
        try:
            target = make_writable(local_path_for(normalize_url(download.url), self.files_root, "file"))
            if not target.suffix and download.suggested_filename:
                target = target.with_name(sanitize_segment(download.suggested_filename))
            download.save_as(str(target))
            size = target.stat().st_size
            self.downloaded_bytes += size
            self.manifest.record(
                normalize_url(download.url), status="ok", kind="file",
                path=str(target.relative_to(self.args.out)), bytes=size,
            )
            self._log(f"  file  {target.relative_to(self.args.out)} ({size / 1024:.0f} KB)")
        except PlaywrightError as err:
            self._log(f"  download failed: {err}")

    def should_follow(self, url: str) -> bool:
        parts = urlsplit(url)
        if parts.scheme in SKIP_SCHEMES or parts.scheme not in ("http", "https"):
            return False
        if parts.netloc.lower() not in self.allowed_hosts:
            return False
        if LOGOUT_RE.search(url):
            return False
        if self.exclude_re and self.exclude_re.search(url):
            return False
        if self.include_re and not self.include_re.search(url):
            return False
        return True

    def enqueue(self, url: str, depth: int) -> None:
        if depth > self.args.max_depth:
            return
        if url in self.manifest.done or any(url == q for q, _ in self.manifest.queue):
            return
        self.manifest.queue.append((url, depth))

    def fetch_binary(self, url: str) -> bool:
        response = self.context.request.get(url, timeout=self.args.timeout * 1000)
        if not response.ok:
            self.manifest.record(url, status="error", http=response.status)
            self._log(f"  HTTP {response.status} on {url}")
            return False

        content_type = (response.headers.get("content-type") or "").split(";")[0].strip().lower()
        if content_type in HTML_CONTENT_TYPES:
            # Mislabelled by the extension - store it as a page instead.
            body = response.body()
            target = make_writable(local_path_for(url, self.pages_root, "page"))
            target.write_bytes(body)
            self.manifest.record(url, status="ok", kind="page",
                                 path=str(target.relative_to(self.args.out)), bytes=len(body))
            return True

        body = response.body()
        target = make_writable(local_path_for(url, self.files_root, "file"))
        if not target.suffix:
            target = target.with_suffix(EXTENSION_BY_CONTENT_TYPE.get(content_type, ".bin"))
        target.write_bytes(body)
        self.downloaded_bytes += len(body)
        self.manifest.record(url, status="ok", kind="file",
                             path=str(target.relative_to(self.args.out)), bytes=len(body))
        self._log(f"  file  {target.relative_to(self.args.out)} ({len(body) / 1024:.0f} KB)")
        return True

    def fetch_page(self, page, url: str, depth: int) -> bool:
        try:
            response = page.goto(url, wait_until=self.args.wait_until)
        except PlaywrightError as err:
            if "ERR_ABORTED" in str(err):
                # Navigation turned into a download; the handler already saved it.
                return True
            raise

        if response is not None and response.status >= 400:
            self.manifest.record(url, status="error", http=response.status)
            self._log(f"  HTTP {response.status} on {url}")
            return False

        content_type = ""
        if response is not None:
            content_type = (response.headers.get("content-type") or "").split(";")[0].strip().lower()
        if content_type and content_type not in HTML_CONTENT_TYPES:
            # Chromium wraps JSON/plain text in a viewer; fetch the real bytes instead.
            return self.fetch_binary(url)

        final_url = normalize_url(page.url)
        if LOGIN_RE.search(final_url) and not LOGIN_RE.search(url):
            self.login_redirects += 1
            self.manifest.record(url, status="redirected_to_login")
            self._log(f"  redirected to a login page ({final_url})")
            return False
        self.login_redirects = 0

        if self.args.settle:
            page.wait_for_timeout(self.args.settle * 1000)

        html = page.content()
        target = make_writable(local_path_for(url, self.pages_root, "page"))
        target.write_text(html, encoding="utf-8")
        self.manifest.record(url, status="ok", kind="page",
                             path=str(target.relative_to(self.args.out)),
                             bytes=len(html), final_url=final_url)
        self._log(f"  page  {target.relative_to(self.args.out)}")
        if final_url != url and final_url not in self.manifest.done:
            self.manifest.record(final_url, status="duplicate", of=url,
                                 path=str(target.relative_to(self.args.out)))

        found = 0
        for raw in page.evaluate(LINK_EXTRACTOR):
            try:
                candidate = normalize_url(urljoin(page.url, raw))
            except ValueError:
                continue
            if self.should_follow(candidate):
                before = len(self.manifest.queue)
                self.enqueue(candidate, depth + 1)
                found += len(self.manifest.queue) - before
        if found:
            self._log(f"        +{found} new link(s)")
        return True

    def run(self) -> int:
        page = self.context.new_page()
        processed = 0

        while self.manifest.queue:
            if self.args.max_pages and processed >= self.args.max_pages:
                self._log(f"Reached --max-pages ({self.args.max_pages}); stopping.")
                break

            url, depth = self.manifest.queue.popleft()
            if url in self.manifest.done:
                continue

            processed += 1
            remaining = len(self.manifest.queue)
            self._log(f"[{processed}] d{depth} {url}  (queue: {remaining})")
            try:
                if looks_binary(url):
                    self.fetch_binary(url)
                else:
                    self.fetch_page(page, url, depth)
            except PlaywrightTimeout:
                self.manifest.record(url, status="timeout")
                self._log("  timeout")
            except PlaywrightError as err:
                self.manifest.record(url, status="error", error=str(err)[:200])
                self._log(f"  error: {str(err)[:160]}")

            if self.manifest.done.get(url, {}).get("status") == "ok":
                self.saved_this_run += 1
            self.manifest.save()

            # Bail out early rather than mirroring a wall of login pages.
            if self.login_redirects >= 3 or (self.login_redirects and not self.saved_this_run):
                self._log("Session looks expired: the portal is redirecting to its login page.")
                self._log("Run the 'login' command again, then re-run this command to resume.")
                return 2

            if self.args.delay:
                time.sleep(self.args.delay)

        self.manifest.save()
        return 0


def cmd_crawl(args) -> int:
    state = Path(args.state)
    if not state.exists():
        log(f"No session file at {state}. Run the 'login' command first.")
        return 1

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    logfile = out / "crawl.log"
    manifest = Manifest(out / "manifest.json")

    with sync_playwright() as playwright:
        browser, context = build_context(playwright, args, headless=not args.headed)
        crawler = Crawler(args, context, manifest, logfile)

        start = normalize_url(args.url)
        if not manifest.queue and start not in manifest.done:
            manifest.queue.append((start, 0))
        if manifest.done:
            log(f"Resuming: {manifest.ok_count} item(s) already saved, "
                f"{len(manifest.queue)} queued.", logfile)

        try:
            code = crawler.run()
        except KeyboardInterrupt:
            manifest.save()
            log("Interrupted - progress saved. Re-run the same command to resume.", logfile)
            code = 130
        finally:
            context.storage_state(path=str(state))  # refresh rotated cookies
            browser.close()

    ok = manifest.ok_count
    pages = sum(1 for v in manifest.done.values() if v.get("kind") == "page")
    files = sum(1 for v in manifest.done.values() if v.get("kind") == "file")
    total = sum(v.get("bytes", 0) for v in manifest.done.values())
    failed = [u for u, v in manifest.done.items() if v.get("status") not in ("ok", "duplicate")]

    log("-" * 60, logfile)
    log(f"Saved {ok} item(s): {pages} page(s), {files} file(s), {total / 1e6:.1f} MB", logfile)
    log(f"Output: {out.resolve()}", logfile)
    if failed:
        log(f"{len(failed)} item(s) failed - see manifest.json (status != ok).", logfile)
    if manifest.queue:
        log(f"{len(manifest.queue)} URL(s) still queued - re-run to continue.", logfile)
    return code



def _path_prefix(url: str, depth: int = 2) -> str:
    segments = [s for s in urlsplit(url).path.split("/") if s]
    if not segments:
        return "/"
    return "/" + "/".join(segments[:depth])


def cmd_inspect(args) -> int:
    """Probe the portal and write a structural report, without mirroring it."""
    state = Path(args.state)
    if not state.exists():
        log(f"No session file at {state}. Run the 'login' command first.")
        return 1

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    start = normalize_url(args.url)
    start_host = urlsplit(start).netloc.lower()

    with sync_playwright() as playwright:
        browser, context = build_context(playwright, args, headless=not args.headed)
        page = context.new_page()
        visited: list[dict] = []
        queue: deque[tuple[str, int]] = deque([(start, 0)])
        seen = {start}

        while queue and len(visited) < args.sample:
            url, depth = queue.popleft()
            log(f"probing {url}")
            entry: dict = {"url": url, "depth": depth}
            try:
                response = page.goto(url, wait_until=args.wait_until)
                if args.settle:
                    page.wait_for_timeout(int(args.settle * 1000))
                entry["http"] = response.status if response else None
                entry["final_url"] = normalize_url(page.url)
                if LOGIN_RE.search(entry["final_url"]) and not LOGIN_RE.search(url):
                    entry["note"] = "redirected to login - session expired?"
                    visited.append(entry)
                    log("  redirected to the login page; stopping.")
                    break

                probe = page.evaluate(INSPECT_PROBE)
                rendered_links = [normalize_url(urljoin(page.url, u)) for u in probe["links"]]
                entry.update({
                    "title": probe["title"],
                    "rendered_link_count": len(rendered_links),
                    "nav_link_count": len(probe["navLinks"]),
                    "forms": probe["forms"],
                    "buttons": probe["buttons"],
                    "tables": probe["tables"],
                    "selects": probe["selects"],
                    "iframes": probe["iframes"][:10],
                    "download_attr_links": probe["downloadLinks"][:10],
                    "text_length": probe["textLength"],
                    "frameworks": [k for k, v in probe["frameworks"].items() if v],
                    "links": rendered_links,
                })

                # Compare the served HTML with the rendered DOM: a big gap means
                # the navigation only exists after JavaScript runs.
                try:
                    raw = context.request.get(url, timeout=args.timeout * 1000)
                    raw_body = raw.text()
                    entry["raw_bytes"] = len(raw_body)
                    entry["raw_anchor_count"] = raw_body.lower().count("<a ")
                    entry["js_rendered"] = (
                        len(rendered_links) > max(5, entry["raw_anchor_count"] * 2)
                    )
                except PlaywrightError:
                    entry["raw_bytes"] = None
                    entry["js_rendered"] = None

                for link in rendered_links:
                    if link in seen or looks_binary(link) or LOGOUT_RE.search(link):
                        continue
                    if urlsplit(link).netloc.lower() != start_host:
                        continue
                    seen.add(link)
                    if depth + 1 <= args.depth:
                        queue.append((link, depth + 1))

            except PlaywrightTimeout:
                entry["error"] = "timeout"
                log("  timeout")
            except PlaywrightError as err:
                entry["error"] = str(err)[:200]
                log(f"  error: {str(err)[:120]}")

            visited.append(entry)
            if args.delay:
                time.sleep(args.delay)

        context.storage_state(path=str(state))
        browser.close()

    # ---- aggregate -----------------------------------------------------
    all_links: list[str] = []
    for entry in visited:
        all_links.extend(entry.get("links", []))

    sections: dict[str, int] = {}
    subsections: dict[str, int] = {}
    extensions: dict[str, int] = {}
    hosts: dict[str, int] = {}
    for link in all_links:
        parts = urlsplit(link)
        host = parts.netloc.lower()
        if host:  # mailto:/javascript: links have no host
            hosts[host] = hosts.get(host, 0) + 1
        if host != start_host:
            continue
        top = _path_prefix(link, 1)
        sections[top] = sections.get(top, 0) + 1
        sub = _path_prefix(link, 2)
        subsections[sub] = subsections.get(sub, 0) + 1
        suffix = Path(parts.path).suffix.lower()
        if suffix:
            extensions[suffix] = extensions.get(suffix, 0) + 1

    frameworks = sorted({f for e in visited for f in e.get("frameworks", [])})
    js_rendered = any(e.get("js_rendered") for e in visited)
    unique_internal = sorted({l for l in all_links
                              if urlsplit(l).netloc.lower() == start_host})

    report = {
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "start_url": start,
        "pages_probed": len(visited),
        "unique_internal_links": len(unique_internal),
        "frameworks_detected": frameworks,
        "javascript_rendered": js_rendered,
        "sections": dict(sorted(sections.items(), key=lambda kv: -kv[1])),
        "subsections": dict(sorted(subsections.items(), key=lambda kv: -kv[1])),
        "internal_links": unique_internal[:3000],
        "file_extensions": dict(sorted(extensions.items(), key=lambda kv: -kv[1])),
        "hosts": dict(sorted(hosts.items(), key=lambda kv: -kv[1])),
        "pages": visited,
    }
    (out / "report.json").write_text(
        json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")

    # ---- human-readable summary ---------------------------------------
    lines = [
        "# Structure report",
        "",
        f"- Start URL: `{start}`",
        f"- Pages probed: {len(visited)}",
        f"- Unique internal links seen: {len(unique_internal)}",
        f"- JavaScript-rendered navigation: {'yes' if js_rendered else 'no'}",
        f"- Frameworks detected: {', '.join(frameworks) if frameworks else 'none'}",
        "",
        "## Sections (link count by first path segment)",
        "",
    ]
    lines += [f"- `{k}` — {v}" for k, v in list(report["sections"].items())[:40]] or ["- none"]
    lines += ["", "## Subsections (two path segments)", ""]
    lines += [f"- `{k}` — {v}" for k, v in list(report["subsections"].items())[:40]] or ["- none"]
    lines += ["", "## File types linked", ""]
    lines += [f"- `{k}` — {v}" for k, v in list(report["file_extensions"].items())[:30]] or ["- none"]
    lines += ["", "## Hosts referenced", ""]
    lines += [f"- `{k}` — {v}" for k, v in list(report["hosts"].items())[:20]]
    lines += ["", "## Pages probed", ""]
    for entry in visited:
        lines.append(
            f"- `{entry['url']}` — {entry.get('title', '?')!r} "
            f"(HTTP {entry.get('http')}, {entry.get('rendered_link_count', 0)} links, "
            f"{entry.get('nav_link_count', 0)} nav, {entry.get('tables', 0)} tables"
            + (f", {entry['error']}" if entry.get("error") else "") + ")"
        )

    # ---- suggested crawl command ---------------------------------------
    suggestion = ["python3 download_extranet.py", f"  --url {start}", "  crawl --out download"]
    if js_rendered:
        suggestion.append("  --settle 2")
    if len(unique_internal) > 500:
        suggestion.append("  --max-pages 200   # large site: mirror it in batches")
    extra_hosts = [h for h in hosts if h != start_host and h.endswith(
        ".".join(start_host.split(".")[-2:]))]
    for host in extra_hosts[:3]:
        suggestion.append(f"  --allow-host {host}")
    lines += ["", "## Suggested crawl command", "", "```bash", " \\\n".join(suggestion), "```"]

    (out / "report.md").write_text("\n".join(lines) + "\n", encoding="utf-8")

    print()
    print("\n".join(lines[:60]))
    print()
    log(f"Full report: {(out / 'report.md').resolve()} and report.json")
    log("The report lists URLs and page titles, no page content - but review it "
        "before sharing, URLs alone can be revealing.")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Mirror an authenticated extranet locally.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("--url", default=DEFAULT_START_URL, help="start URL (default: %(default)s)")
    parser.add_argument("--state", default="state.json", help="session file (default: %(default)s)")
    parser.add_argument("--timeout", type=int, default=45, help="per-request timeout in seconds")
    parser.add_argument("--user-agent", default=DEFAULT_USER_AGENT, help="browser user agent")
    parser.add_argument("--browser-path", default=None,
                        help="path to an existing Chromium binary (else Playwright's own)")

    sub = parser.add_subparsers(dest="command", required=True)

    login = sub.add_parser("login", help="open a browser, sign in by hand, save the session")
    login.add_argument("--auto", action="store_true",
                       help="pre-fill from EXTRANET_USER / EXTRANET_PASSWORD (you still submit)")
    login.set_defaults(func=cmd_login)

    crawl = sub.add_parser("crawl", help="mirror the site using the saved session")
    crawl.add_argument("--out", default="download", help="output directory (default: %(default)s)")
    crawl.add_argument("--max-depth", type=int, default=6, help="link depth limit (default: %(default)s)")
    crawl.add_argument("--max-pages", type=int, default=0, help="stop after N items (0 = no limit)")
    crawl.add_argument("--delay", type=float, default=1.5,
                       help="seconds between requests (default: %(default)s)")
    crawl.add_argument("--settle", type=float, default=0,
                       help="extra seconds to wait after load, for slow JS pages")
    crawl.add_argument("--wait-until", default="networkidle",
                       choices=["load", "domcontentloaded", "networkidle", "commit"],
                       help="navigation wait condition (default: %(default)s)")
    crawl.add_argument("--include", help="only follow URLs matching this regex")
    crawl.add_argument("--exclude", help="never follow URLs matching this regex")
    crawl.add_argument("--allow-host", action="append", default=[],
                       help="extra host to crawl (repeatable, e.g. a CDN)")
    crawl.add_argument("--headed", action="store_true", help="show the browser while crawling")
    crawl.set_defaults(func=cmd_crawl)

    inspect = sub.add_parser(
        "inspect", help="probe the site structure and write a report (downloads nothing)")
    inspect.add_argument("--out", default="recon", help="report directory (default: %(default)s)")
    inspect.add_argument("--sample", type=int, default=12,
                         help="how many pages to probe (default: %(default)s)")
    inspect.add_argument("--depth", type=int, default=2,
                         help="how deep to follow links while sampling (default: %(default)s)")
    inspect.add_argument("--delay", type=float, default=1.0, help="seconds between probes")
    inspect.add_argument("--settle", type=float, default=2.0,
                         help="extra seconds to wait after load (default: %(default)s)")
    inspect.add_argument("--wait-until", default="networkidle",
                         choices=["load", "domcontentloaded", "networkidle", "commit"],
                         help="navigation wait condition (default: %(default)s)")
    inspect.add_argument("--headed", action="store_true", help="show the browser while probing")
    inspect.set_defaults(func=cmd_inspect)

    return parser


def main() -> int:
    args = build_parser().parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
