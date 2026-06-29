#!/usr/bin/env bash
# export-image.sh — export a loaded Docker image to a tar.gz file ready for push.
# Usage: ./export-image.sh <docker-tag> [--out DIR]
set -euo pipefail

IMAGE=""
OUT_DIR="${FRUGAL_RI_STORE:-$HOME/.frugal-ri}/images"

usage() {
  cat <<'USAGE'
Usage:
  ./export-image.sh <docker-tag> [options]

Options:
  --out DIR   Output directory (default: ~/.frugal-ri/images)
  -h, --help

Example:
  ./export-image.sh oracle-db-slim:19.3.0-r5

Output filename is derived from the tag: slashes and colons replaced with dashes.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)     OUT_DIR="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)  IMAGE="$1"; shift ;;
  esac
done

[[ -z "$IMAGE" ]] && { echo "ERROR: docker tag required." >&2; usage >&2; exit 1; }

docker image inspect "$IMAGE" >/dev/null 2>&1 || {
  echo "ERROR: image '$IMAGE' not found in local Docker." >&2; exit 1; }

# Derive filename: oracle-db-slim:19.3.0-r5 → oracle-db-slim-19.3.0-r5.tar.gz
FNAME="$(printf '%s' "$IMAGE" | sed 's|.*/||; s|:|--|; s|/|-|g').tar.gz"
mkdir -p "$OUT_DIR"
DEST="$OUT_DIR/$FNAME"

echo "Saving image : $IMAGE"
echo "Destination  : $DEST"

docker save "$IMAGE" | gzip > "$DEST"

SIZE=$(du -sh "$DEST" | cut -f1)
echo "Done: $DEST  ($SIZE)"
echo
echo "To use as a release artifact, copy or symlink into release/image/ then run push-lite-db.sh."
echo "The docker tag is auto-read from the tar.gz — no sidecar .meta.json needed."
