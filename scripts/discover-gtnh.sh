#!/usr/bin/env bash
set -euo pipefail

CHANNEL="${1:-stable}"
REQUESTED_VERSION="${2:-}"
JAVA_LINE="17-25"
VERSION_HISTORY_URL="https://www.gtnewhorizons.com/version-history/"
GITHUB_RELEASES_URL="https://api.github.com/repos/GTNewHorizons/GT-New-Horizons-Modpack/releases?per_page=100"
DOWNLOAD_BASE="https://downloads.gtnewhorizons.com/ServerPacks/"

case "$CHANNEL" in
  stable|beta|nightly) ;;
  *) echo "Unsupported channel: $CHANNEL" >&2; exit 2 ;;
esac

parse_history() {
  python3 -c '
from html.parser import HTMLParser
import re, sys

class Parser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.tag = None
        self.text = []
        self.current = None
        self.releases = []
        self.section = None
        self.link_href = None
        self.link_text = []

    def handle_starttag(self, tag, attrs):
        if tag in ("h2", "h3", "a"):
            self.tag = tag
            self.text = []
            if tag == "a":
                self.link_href = dict(attrs).get("href")
                self.link_text = []

    def handle_data(self, data):
        if self.tag == "h2":
            self.text.append(data)
        elif self.tag == "h3":
            self.text.append(data)
        elif self.tag == "a":
            self.link_text.append(data)

    def handle_endtag(self, tag):
        if tag == "h2":
            heading = re.sub(r"\\s+", " ", "".join(self.text)).strip()
            m = re.match(r"^(\\d+\\.\\d+\\.\\d+(?:-[A-Za-z0-9.-]+)?)\\s+(Stable release|Beta release)$", heading, re.I)
            if m:
                self.current = {"version": m.group(1), "channel": m.group(2).split()[0].lower(), "server_url": None}
                self.releases.append(self.current)
            else:
                self.current = None
            self.section = None
        elif tag == "h3":
            heading = re.sub(r"\\s+", " ", "".join(self.text)).strip().lower()
            self.section = heading if self.current else None
        elif tag == "a":
            text = re.sub(r"\\s+", " ", "".join(self.link_text)).strip().lower()
            if self.current and self.section == "server zips" and text == "java 17-25 zip" and self.current["server_url"] is None:
                self.current["server_url"] = self.link_href
            self.link_href = None
            self.link_text = []
        if tag in ("h2", "h3", "a"):
            self.tag = None

html = sys.stdin.read()
p = Parser()
p.feed(html)

for release in p.releases:
    if release["server_url"] and not release["server_url"].startswith("https://downloads.gtnewhorizons.com/ServerPacks/"):
        raise SystemExit(f"Refusing non-official GTNH server URL for {release['version']}: {release['server_url']}")

print(__import__("json").dumps(p.releases))
' <<<"$1"
}

HISTORY="$(curl -fsSL --retry 3 --retry-all-errors "$VERSION_HISTORY_URL")"
RELEASES="$(parse_history "$HISTORY")"

if [ -n "$REQUESTED_VERSION" ]; then
  VERSION="$REQUESTED_VERSION"
else
  VERSION="$(python3 -c '
import json, re, sys
channel, releases = sys.argv[1], json.load(sys.stdin)
for r in releases:
    if r["channel"] == channel and r["server_url"]:
        print(r["version"])
        raise SystemExit
raise SystemExit(f"No latest {channel} release with an official Server ZIP was found on the GTNH version-history page")
' "$CHANNEL" <<<"$RELEASES")"
fi

SERVER_URL="$(python3 -c '
import json, sys
version, releases = sys.argv[1], json.load(sys.stdin)
for r in releases:
    if r["version"] == version:
        if not r["server_url"]:
            raise SystemExit(f"No Java 17-25 Server ZIP found for GTNH {version}")
        print(r["server_url"])
        raise SystemExit
raise SystemExit(f"Version {version} was not found on the official GTNH version-history page")
' "$VERSION" <<<"$RELEASES")"

if [[ "$VERSION" == *-nightly-* ]]; then
  [[ "$CHANNEL" == nightly ]] || { echo "Nightly version requires channel=nightly" >&2; exit 2; }
  FILENAME="GT_New_Horizons_${VERSION}_Server_Java_${JAVA_LINE}.zip"
  SERVER_URL="${DOWNLOAD_BASE}${FILENAME}"
fi

curl -fsSIL --retry 3 --retry-all-errors "$SERVER_URL" >/dev/null

EXPECTED_SHA256=""
for suffix in .sha256 .sha256sum; do
  if checksum="$(curl -fsSL --retry 2 --retry-all-errors "${SERVER_URL}${suffix}" 2>/dev/null)"; then
    EXPECTED_SHA256="$(printf '%s\n' "$checksum" | awk 'match($0, /[0-9a-fA-F]{64}/) {print substr($0, RSTART, RLENGTH); exit}')"
    if [ -n "$EXPECTED_SHA256" ]; then break; fi
  fi
done

if [ -z "$EXPECTED_SHA256" ]; then
  echo "No checksum sidecar was published beside the official server ZIP; the workflow will record the downloaded archive SHA-256 but cannot compare it to an upstream checksum." >&2
fi

FILENAME="${SERVER_URL##*/}"
printf 'version=%s\n' "$VERSION"
printf 'channel=%s\n' "$CHANNEL"
printf 'server_url=%s\n' "$SERVER_URL"
printf 'filename=%s\n' "$FILENAME"
printf 'expected_sha256=%s\n' "$EXPECTED_SHA256"
