# syntax=docker/dockerfile:1
FROM eclipse-temurin:21-jre-alpine

ARG GTNH_VERSION
ARG GTNH_SERVER_URL
ARG GTNH_SERVER_SHA256
ARG GTNH_SERVER_FILENAME
ARG VCS_REF=unknown
ARG BUILD_DATE=unknown

LABEL org.opencontainers.image.title="GT New Horizons Minecraft Server" \
      org.opencontainers.image.description="GTNH Minecraft 1.7.10 server" \
      org.opencontainers.image.source="https://github.com/dudesw575/minecraft-gtnh" \
      org.opencontainers.image.revision="$VCS_REF" \
      org.opencontainers.image.created="$BUILD_DATE" \
      org.opencontainers.image.version="$GTNH_VERSION" \
      org.opencontainers.image.vendor="dudesw575" \
      org.gtnh.version="$GTNH_VERSION" \
      org.gtnh.server-pack="$GTNH_SERVER_FILENAME" \
      org.gtnh.server-pack-sha256="$GTNH_SERVER_SHA256" \
      org.gtnh.server-pack-url="$GTNH_SERVER_URL"

RUN apk add --no-cache ca-certificates unzip \
 && addgroup -S app \
 && adduser -S app -G app

COPY --chown=app:app scripts/entrypoint.sh /usr/local/bin/gtnh-entrypoint
RUN chmod 0755 /usr/local/bin/gtnh-entrypoint \
 && mkdir -p /opt/gtnh /minecraft \
 && chown -R app:app /opt/gtnh /minecraft

VOLUME ["/minecraft"]
EXPOSE 25565/tcp

# The workflow downloads the official GTNH server ZIP. BuildKit keeps the
# archive out of the image history and final image layers.
RUN --mount=type=secret,id=gtnh_server_pack,target=/tmp/gtnh-server.zip \
    test -s /tmp/gtnh-server.zip \
 && echo "$GTNH_SERVER_SHA256  /tmp/gtnh-server.zip" | sha256sum -c - \
 && unzip -q /tmp/gtnh-server.zip -d /opt/gtnh \
 && rm -f /tmp/gtnh-server.zip \
 && START_SCRIPT="$(find /opt/gtnh -maxdepth 2 -type f \( -name 'startserver-java9.sh' -o -name 'startserver.sh' \) -print | sort | head -n 1)" \
 && test -n "$START_SCRIPT" \
 && START_CMD="$(tr '\\n' ' ' < "$START_SCRIPT" | sed 's/\\\\//g')" \
 && SERVER_JAR="$(printf '%s\\n' "$START_CMD" | sed -n 's/.*-jar[[:space:]]\\+\\([^[:space:]]*\\.jar\\).*/\\1/p' | tail -n 1)" \
 && test -n "$SERVER_JAR" \
 && test -f "/opt/gtnh/${SERVER_JAR#./}" \
 && test -n "$(find /opt/gtnh -maxdepth 4 -type f -name 'server.properties' -print -quit)" \
 && test -n "$(find /opt/gtnh -maxdepth 4 -type f -name 'eula.txt' -print -quit)" \
 && chown -R app:app /opt/gtnh

USER app
ENV MEMORY=6G

ENTRYPOINT ["/usr/local/bin/gtnh-entrypoint"]
