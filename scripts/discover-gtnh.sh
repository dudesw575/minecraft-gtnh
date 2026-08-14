#!/usr/bin/env bash
set -euo pipefail

CHANNEL="${1:-stable}"
REQUESTED_VERSION="${2:-}"
DOWNLOADS_URL="https://www.gtnewhorizons.com/downloads/"
VERSION_HISTORY_URL="https://www.gtnewhorizons.com/version-history/"
DOWNLOAD_BASE="https://downloads.gtnewhorizons.com/ServerPacks/"

case "$CHANNEL" in stable|beta|nightly) ;; *) echo "Unsupported channel: $CHANNEL" >&2; exit 2;; esac

# Extract links from the official GTNH page using an HTML parser. We keep the
# href attached to the visible link text so we never reconstruct a server-pack
# filename ourselves.
parse_links() {
  python3 -c '
from html.parser import HTMLParser
import json, sys
class P(HTMLParser):
    def __init__(self): super().__init__(); self.a=None; self.links=[]
    def handle_starttag(self, tag, attrs):
        if tag=="a": self.a=[dict(attrs).get("href"), []]
    def handle_data(self, data):
        if self.a: self.a[1].append(data)
    def handle_endtag(self, tag):
        if tag=="a" and self.a:
            self.links.append({"href":self.a[0],"text":" ".join("".join(self.a[1]).split())})
            self.a=None
p=P(); p.feed(sys.stdin.read()); print(json.dumps(p.links))
' <<<"$1"
}

select_server_link() {
  local html="$1" version="$2" mode="$3"
  python3 -c '
import json, sys, re
links=json.loads(sys.stdin.read()); version,mode=sys.argv[1:]

def official(h): return h and h.startswith("https://downloads.gtnewhorizons.com/ServerPacks/")
# Exact-version selection: the official history page exposes the actual server
# ZIP href, so we select the Java 17-25 Server ZIP rather than guessing it.
if mode == "version":
    for i,l in enumerate(links):
        if l["text"].lower() == "java 17-25 zip" and official(l["href"]):
            # The link order is stable within each release: Prism 17-25, Prism
            # 8, Server 17-25, Server 8, Vanilla. Match the filename's version
            # when available, otherwise the caller's page/section filtering
            # prevents cross-release selection.
            if version in l["href"]:
                print(l["href"]); raise SystemExit
    raise SystemExit(f"No official Java 17-25 Server ZIP found for GTNH {version}")

# The downloads page labels the current Server ZIP explicitly as Latest.
needle=f"Latest ({version}) for Java 17-25"
for l in links:
    if l["text"] == needle and official(l["href"]): print(l["href"]); raise SystemExit
raise SystemExit(f"No official Server ZIP link found for {needle}")
' <<<"$(parse_links "$html")" "$version" "$mode"
}

DOWNLOADS="$(curl -fsSL --retry 3 --retry-all-errors "$DOWNLOADS_URL")"
HISTORY="$(curl -fsSL --retry 3 --retry-all-errors "$VERSION_HISTORY_URL")"

if [ -n "$REQUESTED_VERSION" ]; then
  VERSION="$REQUESTED_VERSION"
elif [ "$CHANNEL" = stable ]; then
  VERSION="$(python3 -c '
from html.parser import HTMLParser
import re,sys
class P(HTMLParser):
 def __init__(self): super().__init__(); self.a=None; self.links=[]
 def handle_starttag(self,t,a):
  if t=="a": self.a=[dict(a).get("href"),[]]
 def handle_data(self,d):
  if self.a:self.a[1].append(d)
 def handle_endtag(self,t):
  if t=="a" and self.a:self.links.append((" ".join("".join(self.a[1]).split()),self.a[0]));self.a=None
p=P();p.feed(sys.stdin.read())
for text,href in p.links:
 m=re.fullmatch(r"Latest \(([^)]+)\) for Java 17-25",text)
 if m and href and "/ServerPacks/" in href: print(m.group(1));break
else: raise SystemExit("No latest stable Server ZIP was found on the official GTNH downloads page")
' <<<"$DOWNLOADS")"
elif [ "$CHANNEL" = beta ]; then
  VERSION="$(python3 -c '
from html.parser import HTMLParser
import re,sys
class P(HTMLParser):
 def __init__(self):super().__init__();self.text="";self.in_h2=False;self.rels=[]
 def handle_starttag(self,t,a):
  if t=="h2":self.in_h2=True;self.text=""
 def handle_data(self,d):
  if self.in_h2:self.text+=d
 def handle_endtag(self,t):
  if t=="h2":
   x=" ".join(self.text.split());m=re.match(r"(.+?) Beta release$",x)
   if m:self.rels.append(m.group(1));self.in_h2=False
for _ in [0]:
 p=P();p.feed(sys.stdin.read())
 if p.rels: print(p.rels[0])
 else: raise SystemExit("No beta release found on official GTNH version-history page")
' <<<"$HISTORY")"
elif [ "$CHANNEL" = nightly ]; then
  echo "Nightly discovery is not yet mapped to an official GTNH Server ZIP; refusing to guess a filename." >&2
  exit 1
fi

if [ -n "$REQUESTED_VERSION" ]; then
  # Explicit versions are always resolved against the official version history.
  SERVER_URL="$(select_server_link "$HISTORY" "$VERSION" version)"
elif [ "$CHANNEL" = stable ]; then
  SERVER_URL="$(select_server_link "$DOWNLOADS" "$VERSION" latest)"
else
  SERVER_URL="$(select_server_link "$HISTORY" "$VERSION" version)"
fi

curl -fsSIL --retry 3 --retry-all-errors "$SERVER_URL" >/dev/null
FILENAME="${SERVER_URL##*/}"
EXPECTED_SHA256=""
for suffix in .sha256 .sha256sum; do
 if checksum="$(curl -fsSL --retry 2 --retry-all-errors "${SERVER_URL}${suffix}" 2>/dev/null)"; then
  EXPECTED_SHA256="$(printf '%s\n' "$checksum" | awk 'match($0, /[0-9a-fA-F]{64}/){print substr($0,RSTART,RLENGTH);exit}')"; [ -n "$EXPECTED_SHA256" ] && break
 fi
done
[ -n "$EXPECTED_SHA256" ] || echo "No upstream checksum sidecar found; recording archive SHA-256 after download." >&2
printf 'version=%s\nchannel=%s\nserver_url=%s\nfilename=%s\nexpected_sha256=%s\n' "$VERSION" "$CHANNEL" "$SERVER_URL" "$FILENAME" "$EXPECTED_SHA256"
