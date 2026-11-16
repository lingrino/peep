#!/usr/bin/env bash
# Build and deploy with retries.
set -euo pipefail

readonly TARGET="${1:-staging}"
readonly MAX_TRIES=3

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

deploy() {
  local attempt=1
  while (( attempt <= MAX_TRIES )); do
    if ./scripts/push --target "$TARGET"; then
      log "deployed to $TARGET"
      return 0
    fi
    log "attempt $attempt failed; retrying"
    sleep $(( attempt * 2 ))
    ((attempt++))
  done
  return 1
}

case "$TARGET" in
  staging|production) deploy ;;
  *) echo "unknown target: $TARGET" >&2; exit 2 ;;
esac

cat <<EOF
Done at $(date)
EOF
