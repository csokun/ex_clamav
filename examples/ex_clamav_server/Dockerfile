# =============================================================================
# Stage 1: Build
# =============================================================================
FROM hexpm/elixir:1.18.3-erlang-27.3.1-debian-trixie-20260202-slim AS builder

ARG MIX_ENV=prod

ENV MIX_ENV=${MIX_ENV} \
    LANG=C.UTF-8

# Install build dependencies including libclamav-dev for NIF compilation
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    git \
    ca-certificates \
    libclamav-dev \
    pkg-config \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Install hex and rebar
RUN mix local.hex --force && mix local.rebar --force

# ---------------------------------------------------------------------------
# Copy the parent ex_clamav library first (it's a path dependency)
# ---------------------------------------------------------------------------
COPY lib/ /build/ex_clamav/lib/
COPY mix.exs mix.lock Makefile /build/ex_clamav/

# ---------------------------------------------------------------------------
# Copy the server application
# ---------------------------------------------------------------------------
COPY examples/ex_clamav_server/mix.exs examples/ex_clamav_server/mix.lock* /build/ex_clamav/examples/ex_clamav_server/
COPY examples/ex_clamav_server/config/ /build/ex_clamav/examples/ex_clamav_server/config/

WORKDIR /build/ex_clamav/examples/ex_clamav_server

# Fetch and compile dependencies (cached layer)
RUN mix deps.get --only ${MIX_ENV}
RUN mix deps.compile

# Copy the rest of the server application source
COPY examples/ex_clamav_server/lib/ /build/ex_clamav/examples/ex_clamav_server/lib/
COPY examples/ex_clamav_server/priv/ /build/ex_clamav/examples/ex_clamav_server/priv/

# Compile the application
RUN mix compile

# Build the release
RUN mix release

# =============================================================================
# Stage 2: Runtime
# =============================================================================
FROM debian:trixie-slim AS runtime

ARG MIX_ENV=prod

ENV MIX_ENV=${MIX_ENV} \
    LANG=C.UTF-8 \
    # Default runtime configuration (override via env vars or ConfigMap)
    PORT=4000 \
    CLAMAV_DB_PATH=/var/lib/clamav \
    UPLOAD_PATH=/data/uploads \
    CLAMAV_UPDATE_INTERVAL_HOURS=1 \
    CLAMAV_UPDATE_ON_START=true

# Install runtime dependencies:
#   - libclamav: ClamAV shared library needed by the NIF
#   - clamav-freshclam: for updating virus definitions
#   - tini: lightweight init for proper signal handling in containers
#   - ca-certificates: for HTTPS connections (freshclam mirrors)
RUN apt-get update && apt-get install -y --no-install-recommends \
    libclamav12 \
    clamav-freshclam \
    clamav \
    tini \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Create a non-root user for running the application
RUN groupadd --system clamav_server && \
    useradd --system --gid clamav_server --home /app --shell /bin/false clamav_server

# Create required directories with proper ownership
RUN mkdir -p /var/lib/clamav /data/uploads /app /var/log/clamav && \
    chown -R clamav_server:clamav_server /var/lib/clamav /data/uploads /app /var/log/clamav

# Configure freshclam
# The default freshclam.conf may need adjustment for container usage
RUN sed -i 's/^NotifyClamd/#NotifyClamd/' /etc/clamav/freshclam.conf 2>/dev/null || true

# Copy the release from the builder stage
COPY --from=builder --chown=clamav_server:clamav_server \
    /build/ex_clamav/examples/ex_clamav_server/_build/${MIX_ENV}/rel/ex_clamav_server/ \
    /app/

# Copy the migration files for ecto.migrate
COPY --from=builder --chown=clamav_server:clamav_server \
    /build/ex_clamav/examples/ex_clamav_server/priv/repo/migrations/ \
    /app/priv/repo/migrations/

# Add entrypoint script
COPY examples/ex_clamav_server/docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

# Create a healthcheck script
RUN echo '#!/bin/sh\ncurl -sf http://localhost:${PORT:-4000}/health || exit 1' > /healthcheck.sh && \
    chmod +x /healthcheck.sh

WORKDIR /app

USER clamav_server

EXPOSE 4000

HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
    CMD ["/healthcheck.sh"]

ENTRYPOINT ["tini", "--", "/docker-entrypoint.sh"]
CMD ["start"]
