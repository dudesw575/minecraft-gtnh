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

extract_server_url_from_history() {
  local version="$1"
  local page
  page="$(curl -fsSL --retry 3 --retry-all-errors "$VERSION_HISTORY_URL")"
  python3 -c '
import html, re, sys
version, page = sys.argv[1], sys.stdin.read()

blocks = re.findall(
    r"<h2[^>]*>\s*([^<]+?)\s*</h2>(.*?)(?=<h2\b|$)",
    page,
    re.I | re.S,
)

for heading, block in blocks:
    heading = html.unescape(re.sub(r"<[^>]+>", "", heading)).strip()
    if heading != version:
        continue
    server = re.search(
        r"<h3[^>]*>\s*Server ZIPs\s*</h3>(.*?)(?=<h3\b|<h2\b|$)",
        block,
        re.I | re.S,
    )
    if not server:
        raise SystemExit(f"No Server ZIPs section found for GTNH {version}")
    links = re.findall(
        r"<a[^>]+href=[\"\x27]([^\"\x27]+)[\"\x27][^>]*>\s*Java\s+17-25\s+ZIP",
        server.group(1),
        re.I | re.S,
    )
    if not links:
        raise SystemExit(f"No Java 17-25 server ZIP found for GTNH {version}")
    url = html.unescape(links[0])
    if not url.startswith("https://downloads.gtnewhorizons.com/ServerPacks/"):
        raise SystemExit(f"Refusing non-official GTNH server URL: {url}")
    print(url)
    raise SystemExit

raise SystemExit(f"Version {version} was not found on the official GTNH version-history page")
' "$version" <<<"$page"
}

latest_release_version() {
  local mode="$1"
  local page
  page="$(curl -fsSL --retry 3 --retry-all-errors "$VERSION_HISTORY_URL")"
  python3 -c '
import html, re, sys
mode, page = sys.argv[1], sys.stdin.read()

# Parse the rendered text rather than depending on the exact placement of the
# release-channel label inside the HTML. The official page currently renders
# entries such as: 2.8.4 Stable release 2025/12/23.
text = html.unescape(re.sub(r"<[^>]+>", " ", page))
text = re.sub(r"\s+", " ", text).strip()

wanted = {"stable": "Stable release", "beta": "Beta release"}[mode]
match = re.search(
    r"(\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?)\s+" + re.escape(wanted) + r"\b",
    text,
    re.I,
)
if not match:
    raise SystemExit(f"No latest {mode} release was found on the official GTNH version-history page")
print(match.group(1))
' "$mode" <<<"$page"
}

latest_nightly() {
  local json
  json="$(curl -fsSL --retry 3 --retry-all-errors -H 'Accept: application/vnd.github+json' "$GITHUB_RELEASES_URL")"
  python3 -c '
import json, re, sys
releases = json.load(sys.stdin)
nightlies = [r for r in releases if not r.get("draft") and re.fullmatch(r"2\.\d+\.\d+-nightly-\d{4}-\d{2}-\d{2}(?:-\d+)?", r.get("tag_name", ""))]
if not nightlies:
    raise SystemExit("No GTNH nightly release was found in the official GTNH Modpack GitHub releases")
nightlies.sort(key=lambda r: r.get("published_at") or "", reverse=True)
print(nightlies[0]["tag_name"])
' <<<"$json"
}

if [ -n "$REQUESTED_VERSION" ]; then
  VERSION="$REQUESTED_VERSION"
else
  case "$CHANNEL" in
    stable) VERSION="$(latest_release_version stable)" ;;
    beta) VERSION="$(latest_release_version beta)" ;;
    nightly) VERSION="$(latest_nightly)" ;;
  esac
fi

if [[ "$VERSION" == *-nightly-* ]]; then
  [[ "$CHANNEL" == nightly ]] || { echo "Nightly version requires channel=nightly" >&2; exit 2; }
  FILENAME="GT_New_Horizons_${VERSION}_Server_Java_${JAVA_LINE}.zip"
  SERVER_URL="${DOWNLOAD_BASE}${FILENAME}"
else
  case "$CHANNEL" in
    stable|beta) ;;
    nightly) echo "Requested non-nightly version '$VERSION' is incompatible with channel=nightly" >&2; exit 2 ;;
  esac
  SERVER_URL="$(extract_server_url_from_history "$VERSION")"
  FILENAME="${SERVER_URL##*/}"
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

printf 'version=%s\n' "$VERSION"
printf 'server_url=%s\n' "$SERVER_URL"
printf 'filename=%s\n' "$FILENAME"
printf 'expected_sha256=%s\n' "$EXPECTED_SHA256"
