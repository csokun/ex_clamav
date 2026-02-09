#!/bin/sh
set -e

# =============================================================================
# ExClamavServer Docker Entrypoint
#
# This script handles container startup:
# 1. Optionally downloads initial virus definitions if the DB directory is empty
# 2. Runs Ecto database migrations
# 3. Starts the Elixir release
# =============================================================================

CLAMAV_DB_PATH="${CLAMAV_DB_PATH:-/var/lib/clamav}"
UPLOAD_PATH="${UPLOAD_PATH:-/data/uploads}"

log() {
  echo "[entrypoint] $(date -u '+%Y-%m-%dT%H:%M:%SZ') $*"
}

# ---------------------------------------------------------------------------
# Ensure required directories exist
# ---------------------------------------------------------------------------
ensure_directories() {
  log "Ensuring directories exist..."
  mkdir -p "${CLAMAV_DB_PATH}" "${UPLOAD_PATH}"
}

# ---------------------------------------------------------------------------
# Download initial virus definitions if the database directory is empty
# ---------------------------------------------------------------------------
init_virus_db() {
  # Check if any .cvd or .cld files exist in the database path
  cvd_count=$(find "${CLAMAV_DB_PATH}" -maxdepth 1 \( -name '*.cvd' -o -name '*.cld' \) 2>/dev/null | wc -l)

  if [ "${cvd_count}" -eq 0 ]; then
    log "No virus definitions found in ${CLAMAV_DB_PATH}. Running initial freshclam update..."

    # freshclam needs write access to the database directory
    if [ -w "${CLAMAV_DB_PATH}" ]; then
      freshclam \
        --datadir="${CLAMAV_DB_PATH}" \
        --no-dns \
        ${FRESHCLAM_CONFIG:+--config-file="${FRESHCLAM_CONFIG}"} \
        2>&1 | while IFS= read -r line; do log "[freshclam] ${line}"; done

      if [ $? -eq 0 ]; then
        log "Initial virus definitions downloaded successfully."
      else
        log "WARNING: freshclam failed. The application will start but scanning may not work until definitions are available."
      fi
    else
      log "WARNING: ${CLAMAV_DB_PATH} is not writable. Skipping initial virus definition download."
      log "Ensure virus definitions are provided via a shared volume or init container."
    fi
  else
    log "Virus definitions found in ${CLAMAV_DB_PATH} (${cvd_count} database files)."
  fi
}

# ---------------------------------------------------------------------------
# Run Ecto migrations
# ---------------------------------------------------------------------------
run_migrations() {
  log "Running database migrations..."

  # The release includes an eval command that can run Ecto migrations
  /app/bin/ex_clamav_server eval "ExClamavServer.Release.migrate()"

  if [ $? -eq 0 ]; then
    log "Migrations completed successfully."
  else
    log "ERROR: Migrations failed. Exiting."
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
case "${1}" in
  start)
    ensure_directories
    init_virus_db
    run_migrations

    log "Starting ExClamavServer..."
    exec /app/bin/ex_clamav_server start
    ;;

  start_iex)
    ensure_directories
    init_virus_db
    run_migrations

    log "Starting ExClamavServer with IEx console..."
    exec /app/bin/ex_clamav_server start_iex
    ;;

  migrate)
    log "Running migrations only..."
    run_migrations
    ;;

  freshclam)
    log "Running freshclam update only..."
    init_virus_db
    ;;

  eval)
    shift
    exec /app/bin/ex_clamav_server eval "$@"
    ;;

  remote)
    exec /app/bin/ex_clamav_server remote
    ;;

  *)
    # Pass through any other command
    exec "$@"
    ;;
esac
