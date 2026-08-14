#!/bin/sh
set -eu

MEMORY="${MEMORY:-6G}"
IMAGE_SERVER_DIR="/opt/gtnh"
STATE_DIR="/minecraft"

ONLINE_MODE="${ONLINE_MODE:-true}"
WHITELIST_ENABLED="${WHITELIST_ENABLED:-false}"
OPS_ENABLED="${OPS_ENABLED:-false}"
WHITELIST="${WHITELIST:-}"
OPS="${OPS:-}"

SERVER_PID=""
COMMAND_FIFO=""
COMMAND_FD_OPEN="false"

case "$MEMORY" in
  *[!0-9MmGgKkTt]*)
    echo "MEMORY must be a Java heap size such as 6G or 12288M" >&2
    exit 2
    ;;
esac

case "$ONLINE_MODE" in
  true|TRUE|false|FALSE) ;;
  *)
    echo "ONLINE_MODE must be true or false" >&2
    exit 2
    ;;
esac

case "$WHITELIST_ENABLED" in
  true|TRUE|false|FALSE) ;;
  *)
    echo "WHITELIST_ENABLED must be true or false" >&2
    exit 2
    ;;
esac

case "$OPS_ENABLED" in
  true|TRUE|false|FALSE) ;;
  *)
    echo "OPS_ENABLED must be true or false" >&2
    exit 2
    ;;
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

for dir in \
  config \
  world \
  world_nether \
  world_the_end \
  logs \
  crash-reports \
  serverutilities; do
  link_state_dir "$dir"
done

for file in \
  eula.txt \
  server.properties \
  ops.json \
  whitelist.json \
  banned-ips.json \
  banned-players.json \
  usercache.json \
  server-icon.png; do
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

#
# Update a server.properties setting while preserving everything else.
#
set_server_property() {
  key="$1"
  value="$2"
  properties="$STATE_DIR/server.properties"

  if [ ! -f "$properties" ]; then
    touch "$properties"
  fi

  if grep -Eq "^${key}=" "$properties"; then
    sed -i "s/^${key}=.*/${key}=${value}/" "$properties"
  else
    printf '%s=%s\n' "$key" "$value" >> "$properties"
  fi
}

#
# Configure authentication and whitelist mode BEFORE Minecraft starts.
#
case "$ONLINE_MODE" in
  true|TRUE)
    ONLINE_MODE_VALUE="true"
    ;;
  false|FALSE)
    ONLINE_MODE_VALUE="false"
    ;;
esac

case "$WHITELIST_ENABLED" in
  true|TRUE)
    WHITELIST_ENABLED_VALUE="true"
    ;;
  false|FALSE)
    WHITELIST_ENABLED_VALUE="false"
    ;;
esac

set_server_property "online-mode" "$ONLINE_MODE_VALUE"
set_server_property "white-list" "$WHITELIST_ENABLED_VALUE"

if [ "$ONLINE_MODE_VALUE" = "false" ]; then
  echo "WARNING: ONLINE_MODE=false"
  echo "         Mojang/Microsoft authentication is disabled."
  echo "         Players can potentially impersonate other usernames."
fi

if [ "$WHITELIST_ENABLED_VALUE" = "true" ]; then
  echo "Whitelist is enabled."
else
  echo "Whitelist is disabled."
fi

START_SCRIPT="$(find "$IMAGE_SERVER_DIR" -maxdepth 1 -type f \
  \( -name 'startserver-java9.sh' -o -name 'startserver.sh' \) \
  -print | sort | head -n 1)"

if [ -z "$START_SCRIPT" ]; then
  echo "No GTNH Linux server startup script was found in the official server pack." >&2
  exit 1
fi

START_CMD="$(tr '\n' ' ' < "$START_SCRIPT" | sed 's/\\\\//g')"

JAR="$(printf '%s\n' "$START_CMD" |
  sed -n 's/.*-jar[[:space:]]\+\([^[:space:]]*\.jar\).*/\1/p' |
  tail -n 1)"

if [ -z "$JAR" ]; then
  JAR="$(find "$IMAGE_SERVER_DIR" -maxdepth 2 -type f \
    \( -name '*forgePatches.jar' -o -name 'forge-*.jar' \) \
    ! -name '*sources*' \
    ! -name '*javadoc*' \
    -print | sort | head -n 1)"
fi

if [ -z "$JAR" ] || [ ! -f "$IMAGE_SERVER_DIR/${JAR#./}" ]; then
  echo "Unable to locate the server jar from the packaged GTNH launcher." >&2
  exit 1
fi

# Preserve the official pack's Java arguments while replacing its hard-coded
# heap settings with the runtime MEMORY value.
JAVA_ARGS="$(printf '%s\n' "$START_CMD" |
  sed -n 's/.*java[[:space:]]\+\(.*\)[[:space:]]-jar[[:space:]].*/\1/p' |
  sed -E 's/-Xms[0-9]+[KMGkmgTt][[:space:]]*//g; s/-Xmx[0-9]+[KMGkmgTt][[:space:]]*//g')"

if [ -z "$JAVA_ARGS" ] && [ -f java9args.txt ]; then
  JAVA_ARGS='-Dfml.readTimeout=180 @java9args.txt'
fi

#
# Normalize a player list.
#
# Both comma-separated and newline-separated values are accepted:
#
#   WHITELIST="Alice,Bob,Charlie"
#
# or:
#
#   WHITELIST="
#   Alice
#   Bob
#   Charlie
#   "
#
normalize_players() {
  value="$1"

  printf '%s\n' "$value" |
    tr ',' '\n' |
    sed 's/^[[:space:]]*//;s/[[:space:]]*$//' |
    while IFS= read -r player; do
      [ -z "$player" ] && continue

      if ! printf '%s' "$player" | grep -Eq '^[A-Za-z0-9_]{1,16}$'; then
        echo "Invalid Minecraft player name: '$player'" >&2
        exit 2
      fi

      printf '%s\n' "$player"
    done
}

has_players() {
  value="$1"
  normalized="$(normalize_players "$value")"
  [ -n "$normalized" ]
}

send_command() {
  command="$1"

  if [ "$COMMAND_FD_OPEN" != "true" ]; then
    echo "Internal error: Minecraft command FIFO is not open." >&2
    return 1
  fi

  printf '%s\n' "$command" >&3
}

shutdown_server() {
  signal="$1"

  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "Received $signal; stopping GTNH server..."

    if [ "$COMMAND_FD_OPEN" = "true" ]; then
      send_command "stop" 2>/dev/null || true
    else
      kill -TERM "$SERVER_PID" 2>/dev/null || true
    fi

    i=0
    while kill -0 "$SERVER_PID" 2>/dev/null && [ "$i" -lt 30 ]; do
      sleep 1
      i=$((i + 1))
    done

    if kill -0 "$SERVER_PID" 2>/dev/null; then
      echo "GTNH server did not stop gracefully; sending SIGTERM." >&2
      kill -TERM "$SERVER_PID" 2>/dev/null || true
    fi
  fi
}

trap 'shutdown_server TERM' TERM
trap 'shutdown_server INT' INT

#
# Only start the console FIFO machinery if we actually have commands to send.
#
NEEDS_CONSOLE="false"

if [ "$WHITELIST_ENABLED_VALUE" = "true" ] && has_players "$WHITELIST" 2>/dev/null; then
  NEEDS_CONSOLE="true"
fi

if [ "$OPS_ENABLED" = "true" ] || [ "$OPS_ENABLED" = "TRUE" ]; then
  if has_players "$OPS" 2>/dev/null; then
    NEEDS_CONSOLE="true"
  fi
fi

if [ "$NEEDS_CONSOLE" = "false" ]; then
  echo "Starting GTNH server..."

  # shellcheck disable=SC2086
  exec java -Xms"$MEMORY" -Xmx"$MEMORY" $JAVA_ARGS \
    -jar "${JAR#./}" nogui
fi

#
# A whitelist/OP configuration was supplied. Minecraft needs to be running
# before `whitelist add` / `op` can resolve player profiles.
#
COMMAND_FIFO="$STATE_DIR/.gtnh-console"

rm -f "$COMMAND_FIFO"
mkfifo "$COMMAND_FIFO"

exec 3<>"$COMMAND_FIFO"
COMMAND_FD_OPEN="true"

echo "Starting GTNH server..."

# shellcheck disable=SC2086
java -Xms"$MEMORY" -Xmx"$MEMORY" $JAVA_ARGS \
  -jar "${JAR#./}" nogui < "$COMMAND_FIFO" &

SERVER_PID="$!"

echo "GTNH server PID: $SERVER_PID"
echo "Waiting for GTNH server to finish startup..."

READY_TIMEOUT="${READY_TIMEOUT:-900}"
elapsed=0
ready="false"

while [ "$elapsed" -lt "$READY_TIMEOUT" ]; do
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "GTNH server exited before startup completed." >&2
    wait "$SERVER_PID" || true
    rm -f "$COMMAND_FIFO"
    exec 3>&-
    exit 1
  fi

  if [ -f "$STATE_DIR/logs/latest.log" ] &&
     grep -Fq 'Done (' "$STATE_DIR/logs/latest.log"; then
    ready="true"
    break
  fi

  sleep 2
  elapsed=$((elapsed + 2))
done

if [ "$ready" != "true" ]; then
  echo "GTNH server did not reach the ready state within ${READY_TIMEOUT}s." >&2
  echo "Check the server logs for startup errors." >&2

  shutdown_server TIMEOUT
  wait "$SERVER_PID" || true

  rm -f "$COMMAND_FIFO"
  exec 3>&-
  exit 1
fi

echo "GTNH server is ready."

#
# Apply whitelist configuration.
#
if [ "$WHITELIST_ENABLED_VALUE" = "true" ]; then
  send_command "whitelist on"

  if [ -n "$WHITELIST" ]; then
    echo "Ensuring configured players are whitelisted..."

    normalize_players "$WHITELIST" |
      while IFS= read -r player; do
        [ -z "$player" ] && continue
        echo "  Adding '$player' to whitelist"
        send_command "whitelist add $player"
      done
  fi
fi

#
# Apply OP configuration.
#
if [ "$OPS_ENABLED" = "true" ] || [ "$OPS_ENABLED" = "TRUE" ]; then
  if [ -n "$OPS" ]; then
    echo "Ensuring configured players are operators..."

    normalize_players "$OPS" |
      while IFS= read -r player; do
        [ -z "$player" ] && continue
        echo "  Opping '$player'"
        send_command "op $player"
      done
  fi
else
  echo "OP configuration is disabled."
fi

echo "GTNH server configuration applied."
echo "Server is running."

wait "$SERVER_PID"
SERVER_STATUS="$?"

COMMAND_FD_OPEN="false"
exec 3>&-
rm -f "$COMMAND_FIFO"

exit "$SERVER_STATUS"