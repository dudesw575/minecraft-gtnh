#!/bin/sh
set -eu

MEMORY="${MEMORY:-6G}"
IMAGE_SERVER_DIR="/opt/gtnh"
SERVER_DIR="/minecraft"

case "$MEMORY" in
  *[!0-9MmGgKkTt]*) echo "MEMORY must be a Java heap size such as 6G or 12288M" >&2; exit 2 ;;
esac

if [ ! -f "$SERVER_DIR/.gtnh-image-initialized" ]; then
  echo "Initializing GTNH runtime volume from immutable image payload..."
  cp -a "$IMAGE_SERVER_DIR/." "$SERVER_DIR/"
  touch "$SERVER_DIR/.gtnh-image-initialized"
fi

cd "$SERVER_DIR"

if [ "${EULA:-FALSE}" = "TRUE" ] || [ "${EULA:-FALSE}" = "true" ]; then
  printf 'eula=true\n' > eula.txt
fi

if ! grep -Eq '^eula=true$' eula.txt 2>/dev/null; then
  echo "EULA has not been accepted. Set EULA=TRUE or accept it in $SERVER_DIR/eula.txt." >&2
  exit 1
fi

JAR="${FORGE_JAR:-}"
if [ -z "$JAR" ]; then
  JAR="$(find . -maxdepth 3 -type f -name 'forge-*.jar' ! -name '*sources*' ! -name '*javadoc*' -print | sort | head -n 1)"
fi

if [ -z "$JAR" ]; then
  echo "No Forge server jar found in $SERVER_DIR" >&2
  exit 1
fi

exec java \
  -Xms"$MEMORY" -Xmx"$MEMORY" \
  -XX:+UseG1GC \
  -XX:+UnlockExperimentalVMOptions \
  -XX:MaxGCPauseMillis=100 \
  -XX:+DisableExplicitGC \
  -XX:TargetSurvivorRatio=90 \
  -XX:G1NewSizePercent=50 \
  -XX:G1MaxNewSizePercent=80 \
  -XX:G1MixedGCLiveThresholdPercent=50 \
  -XX:+AlwaysPreTouch \
  -jar "$JAR" nogui
