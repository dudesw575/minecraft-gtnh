#!/bin/sh
set -eu

MEMORY="${MEMORY:-6G}"
IMAGE_SERVER_DIR="/opt/gtnh"
STATE_DIR="/minecraft"

case "$MEMORY" in
  *[!0-9MmGgKkTt]*) echo "MEMORY must be a Java heap size such as 6G or 12288M" >&2; exit 2 ;;
esac

# Keep the downloaded server distribution immutable in the image. Only state
# and configuration that Minecraft normally mutates are redirected to the
# persistent /minecraft volume. This means an image upgrade replaces mods and
# libraries without replacing the world.
mkdir -p "$STATE_DIR"

link_state_dir() {
  name="$1"
  image_path="$IMAGE_SERVER_DIR/$name"
  state_path="$STATE_DIR/$name"
  if [ -d "$image_path" ] && [ ! -e "$state_path" ]; then
    cp -a "$image_path" "$state_path"
  elif [ ! -e "$state_path" ]; then
    mkdir -p "$state_path"
  fi
  if [ -d "$image_path" ] && [ ! -L "$image_path" ]; then
    rm -rf "$image_path"
    ln -s "$state_path" "$image_path"
  fi
}

link_state_file() {
  name="$1"
  image_path="$IMAGE_SERVER_DIR/$name"
  state_path="$STATE_DIR/$name"
  if [ -f "$image_path" ] && [ ! -e "$state_path" ]; then
    cp -a "$image_path" "$state_path"
  fi
  if [ -f "$image_path" ] && [ ! -L "$image_path" ]; then
    rm -f "$image_path"
    ln -s "$state_path" "$image_path"
  fi
}

for dir in config world world_nether world_the_end logs crash-reports serverutilities; do
  link_state_dir "$dir"
done

for file in \
  eula.txt server.properties ops.json whitelist.json banned-ips.json \
  banned-players.json usercache.json server-icon.png; do
  link_state_file "$file"
done

cd "$IMAGE_SERVER_DIR"

if [ "${EULA:-FALSE}" = "TRUE" ] || [ "${EULA:-FALSE}" = "true" ]; then
  printf 'eula=true\n' > "$STATE_DIR/eula.txt"
fi

if ! grep -Eq '^eula=true$' "$STATE_DIR/eula.txt" 2>/dev/null; then
  echo "EULA has not been accepted. Set EULA=TRUE or accept it in $STATE_DIR/eula.txt." >&2
  exit 1
fi

START_SCRIPT="$(find "$IMAGE_SERVER_DIR" -maxdepth 1 -type f \( -name 'startserver-java9.sh' -o -name 'startserver.sh' \) -print | sort | head -n 1)"
if [ -z "$START_SCRIPT" ]; then
  echo "No GTNH Linux server startup script was found in the official server pack." >&2
  exit 1
fi

START_CMD="$(tr '\n' ' ' < "$START_SCRIPT" | sed 's/\\\\//g')"
JAR="$(printf '%s\n' "$START_CMD" | sed -n 's/.*-jar[[:space:]]\+\([^[:space:]]*\.jar\).*/\1/p' | tail -n 1)"

if [ -z "$JAR" ]; then
  # Fallback for an upstream launcher format that does not put the jar after
  # a literal -jar token. Still require a server-specific jar name.
  JAR="$(find "$IMAGE_SERVER_DIR" -maxdepth 2 -type f \( -name '*forgePatches.jar' -o -name 'forge-*.jar' \) ! -name '*sources*' ! -name '*javadoc*' -print | sort | head -n 1)"
fi

if [ -z "$JAR" ] || [ ! -f "$IMAGE_SERVER_DIR/${JAR#./}" ]; then
  echo "Unable to locate the server jar from the packaged GTNH launcher." >&2
  exit 1
fi

# Preserve the official pack's Java arguments while replacing its hard-coded
# heap settings with the runtime MEMORY value.
JAVA_ARGS="$(printf '%s\n' "$START_CMD" | sed -n 's/.*[[:space:]]java[[:space:]]\+\(.*\)[[:space:]]-jar[[:space:]].*/\1/p' | sed -E 's/-Xms[0-9]+[KMGkmgTt][[:space:]]*//g; s/-Xmx[0-9]+[KMGkmgTt][[:space:]]*//g')"

if [ -z "$JAVA_ARGS" ] && [ -f java9args.txt ]; then
  JAVA_ARGS='-Dfml.readTimeout=180 @java9args.txt'
fi

# shellcheck disable=SC2086
exec java -Xms"$MEMORY" -Xmx"$MEMORY" $JAVA_ARGS -jar "${JAR#./}" nogui
