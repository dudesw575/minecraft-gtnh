FROM eclipse-temurin:8-jre-alpine

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

WORKDIR /minecraft

COPY --chown=app:app scripts/entrypoint.sh /usr/local/bin/gtnh-entrypoint
RUN chmod 0755 /usr/local/bin/gtnh-entrypoint \
 && mkdir -p /minecraft/server /minecraft/data \
 && chown -R app:app /minecraft

USER app

ENV MEMORY=6G \
    SERVER_DIR=/minecraft/data

VOLUME ["/minecraft/data"]
EXPOSE 25565/tcp

# The server archive is supplied by the workflow as a BuildKit secret so the
# Dockerfile itself never needs a hard-coded release or Forge filename.
RUN --mount=type=secret,id=gtnh_server_pack,target=/tmp/gtnh-server.zip \
    test -s /tmp/gtnh-server.zip \
 && if [ -n "$GTNH_SERVER_SHA256" ]; then \
      echo "$GTNH_SERVER_SHA256  /tmp/gtnh-server.zip" | sha256sum -c -; \
    fi \
 && unzip -q /tmp/gtnh-server.zip -d /minecraft/server \
 && rm -f /tmp/gtnh-server.zip \
 && test -n "$(find /minecraft/server -maxdepth 3 -type f -name 'forge-*.jar' ! -name '*sources*' ! -name '*javadoc*' -print -quit)" \
 && test -f /minecraft/server/eula.txt || printf 'eula=false\n' > /minecraft/server/eula.txt \
 && chown -R app:app /minecraft/server

ENTRYPOINT ["/usr/local/bin/gtnh-entrypoint"]
