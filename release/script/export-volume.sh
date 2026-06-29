#!/usr/bin/env bash
# export-volume.sh — archive a Docker volume to an oracle-volume tar.gz seed file.
# Usage: ./export-volume.sh <docker-volume-name> [--tenancy CODE] [--out DIR]
set -euo pipefail

VOLUME=""
TENANCY="default"
OUT_DIR="${FRUGAL_RI_STORE:-$HOME/.frugal-ri}/volumes"
PLATFORM="linux/amd64"

usage() {
  cat <<'USAGE'
Usage:
  ./export-volume.sh <docker-volume-name> [options]

Options:
  --tenancy CODE   Tenancy tag embedded in filename (default: "default", e.g. IN, SG)
  --out DIR        Output directory (default: ~/.frugal-ri/volumes)
  -h, --help

Output filename:  oracle-volume-<tenancy>-v<YYYYMMDD>.tar.gz
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tenancy) TENANCY="${2:?}"; shift 2 ;;
    --out)     OUT_DIR="${2:?}";  shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)  VOLUME="$1"; shift ;;
  esac
done

[[ -z "$VOLUME" ]] && { echo "ERROR: volume name required." >&2; usage >&2; exit 1; }

# Verify volume exists
docker volume inspect "$VOLUME" >/dev/null 2>&1 || {
  echo "ERROR: Docker volume '$VOLUME' not found." >&2; exit 1; }

DATE="$(date '+%Y%m%d')"
FNAME="oracle-volume-${TENANCY}-v${DATE}.tar.gz"
mkdir -p "$OUT_DIR"
DEST="$OUT_DIR/$FNAME"

echo "Exporting volume: $VOLUME"
echo "Destination     : $DEST"

docker run --rm --platform "$PLATFORM" \
  -v "${VOLUME}:/opt/oracle/oradata:ro" \
  debian:bookworm-slim \
  tar czf - /opt/oracle/oradata > "$DEST"

SIZE=$(du -sh "$DEST" | cut -f1)
echo "Done: $DEST  ($SIZE)"
echo
echo "To use as a release artifact, copy or symlink into release/volume/ then run push-lite-db.sh."
