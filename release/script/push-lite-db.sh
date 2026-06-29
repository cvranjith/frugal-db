#!/usr/bin/env bash
# push-lite-db.sh — push release artifacts to OCI Object Storage
# PAR URLs are embedded; no external par.txt needed.
# Artifacts are read from {image,volume,script}/ relative to the release root.
# When this script lives in a script/ subfolder, the release root is its parent dir.
# Image files: docker tag is auto-read from the tar.gz's embedded manifest.json.
# Volume files must follow: oracle-volume-<tenancy>-v<YYYYMMDD>.tar.gz
# Optional volume sidecar <name>.meta.json overrides {"oracle_sid", "oracle_pdb"}.
set -euo pipefail

RW_PAR="https://objectstorage.ap-seoul-1.oraclecloud.com/p/WXMu3kJ6I_-J8lTFRKCshm99SdzIrx_tl6MIecGJq7t6153PTKYYrIGuqKoa0_Ra/n/cnvubmbktlyh/b/artifactory/o/"
RO_PAR="https://objectstorage.ap-seoul-1.oraclecloud.com/p/oubSLJc6Z8bkdxLeekGQCP_tFWmFPS7v4kRztFt6icRR8iaYdOFK4Kks1Tghgcny/n/cnvubmbktlyh/b/artifactory/o/"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$(basename "$SCRIPT_DIR")" == "script" ]]; then
  RELEASE_DIR="$(dirname "$SCRIPT_DIR")"
else
  RELEASE_DIR="$SCRIPT_DIR/release"
fi
PREFIX="ci/"
CHANNEL="latest"
DRY_RUN=0
ASSUME_YES=0

usage() {
  cat <<'EOF'
Usage:
  ./push-lite-db.sh [options]

Reads artifacts from {image,volume,script}/ relative to the release root.
Volume files must be named:  oracle-volume-<tenancy>-v<YYYYMMDD>.tar.gz

Options:
  --release-dir DIR   Release folder (default: parent of script dir when inside script/)
  --prefix PREFIX     OCI object prefix (default: ci/)
  --channel NAME      Manifest channel name (default: latest)
  --dry-run           Show plan without uploading
  --yes               Skip confirmation prompt
  -h, --help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release-dir) RELEASE_DIR="${2:?}"; shift 2 ;;
    --prefix)      PREFIX="${2:?}"; shift 2 ;;
    --channel)     CHANNEL="${2:?}"; shift 2 ;;
    --dry-run)     DRY_RUN=1; shift ;;
    --yes)         ASSUME_YES=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required tool: $1" >&2; exit 1; }; }
file_size()   { stat -L -f '%z' "$1" 2>/dev/null || stat -L -c '%s' "$1"; }
sha256()      { shasum -a 256 "$1" | awk '{print $1}'; }

normalize_prefix() {
  local p="${1#/}"; [[ -n "$p" && "$p" != */ ]] && p="$p/"; printf '%s' "$p"
}
obj_url() {
  local base="${1%%\?*}" q; q="${1#*\?}"; [[ "$1" != *\?* ]] && q=""
  printf '%s' "${base%/}/$2"; [[ -n "$q" ]] && printf '?%s' "$q"; printf '\n'
}
prefix_url() {
  local base="${1%%\?*}" q; q="${1#*\?}"; [[ "$1" != *\?* ]] && q=""
  printf '%s' "${base%/}/$(printf '%s' "$2" | sed 's#/$##')"; [[ -n "$q" ]] && printf '?%s' "$q"; printf '\n'
}
redact() { printf '%s\n' "$1" | sed -E 's#/p/[^/]+#/p/REDACTED#'; }

confirm_upload() {
  [[ "$ASSUME_YES" -eq 1 ]] && return 0
  local a; read -r -p "Upload to OCI now? [y/N]: " a
  case "${a:-N}" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

ensure_gz() {
  local f="$1"
  [[ -f "$f" ]] || { echo "Not found: $f" >&2; exit 1; }
  gzip -t "$f" >/dev/null 2>&1 && printf '%s\n' "$f" && return
  local gz="$f.gz"
  echo "Not gzip; compressing → $gz" >&2
  gzip -c "$f" > "$gz" && printf '%s\n' "$gz"
}

read_image_tag() {
  tar xOf "$1" manifest.json 2>/dev/null \
    | jq -r '.[0].RepoTags[0] // ""'
}

parse_volume_meta() {
  local name; name="$(basename "$1")"
  local tenancy="" version=""
  if [[ "$name" =~ ^oracle-volume-([^-]+)-v([0-9]{8}) ]]; then
    tenancy="${BASH_REMATCH[1]}"
    version="${BASH_REMATCH[2]}"
  else
    tenancy="default"
    version="$(printf '%s' "$name" | grep -oE '[0-9]{8}' | head -1 || true)"
  fi
  printf '%s\t%s\n' "$tenancy" "${version:-}"
}

fetch_remote_manifest() {
  curl -fsSL --retry 2 --connect-timeout 10 \
    -o "$1" "$(obj_url "$RO_PAR" "${PREFIX}manifest.json")" >/dev/null 2>&1
}

upload_file() {
  local f="$1" obj="$2" sz w=45
  sz="$(file_size "$f")"
  printf '  Uploading %-55s  %s bytes\n' "$obj" "$sz"
  [[ "$DRY_RUN" -eq 0 ]] || return 0
  curl --fail --show-error --no-progress-meter --retry 3 --connect-timeout 20 \
    -X PUT --upload-file "$f" "$(obj_url "$RW_PAR" "$obj")" &
  local pid=$! pos=0 dir=1
  while kill -0 "$pid" 2>/dev/null; do
    local bar="" i
    for ((i=0; i<pos-2 && i<w-3; i++)); do bar="${bar} "; done
    bar="${bar}==>"
    for ((i=${#bar}; i<w; i++)); do bar="${bar} "; done
    printf '\r  [%s]' "$bar"
    pos=$((pos+dir))
    [[ $pos -ge $((w-2)) ]] && dir=-1
    [[ $pos -le 0       ]] && dir=1
    sleep 0.08
  done
  wait "$pid"
  printf '\r  [%s] done\n' "$(printf '=%.0s' $(seq 1 $((w-1))))>"
}

require_cmd curl; require_cmd gzip; require_cmd jq; require_cmd shasum; require_cmd find

[[ -d "$RELEASE_DIR/image"  ]] || { echo "Missing: $RELEASE_DIR/image"  >&2; exit 1; }
[[ -d "$RELEASE_DIR/volume" ]] || { echo "Missing: $RELEASE_DIR/volume" >&2; exit 1; }
[[ -d "$RELEASE_DIR/script" ]] || { echo "Missing: $RELEASE_DIR/script" >&2; exit 1; }

PREFIX="$(normalize_prefix "$PREFIX")"
RO_PREFIX="$(prefix_url "$RO_PAR" "$PREFIX")"
NOW="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/oracle-push.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

REMOTE_MF="$TMP/remote.json"
LOCAL_MF="$TMP/manifest.json"
ENTRIES="$TMP/entries.jsonl"
UPLOADS="$TMP/uploads.tsv"
: > "$ENTRIES" > "$UPLOADS"

if fetch_remote_manifest "$REMOTE_MF"; then mf_state="found"; else : > "$REMOTE_MF"; mf_state="not found"; fi

# ── collect files ─────────────────────────────────────────────────────────────
n=0
latest_docker_tag=""

while IFS= read -r src; do
  rel="${src#$RELEASE_DIR/}"; topdir="${rel%%/*}"; base="$(basename "$src")"
  [[ "$base" == *.meta.json ]] && continue

  case "$topdir" in
    image)
      pub="$(ensure_gz "$src")"; pname="$(basename "$pub")"
      docker_tag="$(read_image_tag "$src")"
      [[ -z "$docker_tag" ]] && {
        echo "ERROR: no RepoTags in $src (not a valid docker image tar?)" >&2; exit 1; }
      sha="$(sha256 "$pub")"; sz="$(file_size "$pub")"
      obj="${PREFIX}image/${pname}"
      jq -n \
        --arg type "image" --arg object "${obj#$PREFIX}" --arg file_name "$pname" \
        --argjson size_bytes "$sz" --arg sha256 "$sha" --arg docker_tag "$docker_tag" \
        '{type:$type,object:$object,file_name:$file_name,size_bytes:$size_bytes,sha256:$sha256,docker_tag:$docker_tag}' \
        >> "$ENTRIES"
      latest_docker_tag="$docker_tag"
      ;;
    volume)
      pub="$(ensure_gz "$src")"; pname="$(basename "$pub")"
      IFS=$'\t' read -r vc_tenancy vc_version < <(parse_volume_meta "$pub")
      oracle_sid="OBCDB"; oracle_pdb="OBPMDB"
      if [[ -f "$src.meta.json" ]]; then
        v="$(jq -r '.oracle_sid // ""' "$src.meta.json")"; [[ -n "$v" ]] && oracle_sid="$v"
        v="$(jq -r '.oracle_pdb // ""' "$src.meta.json")"; [[ -n "$v" ]] && oracle_pdb="$v"
      fi
      sha="$(sha256 "$pub")"; sz="$(file_size "$pub")"
      obj="${PREFIX}volume/${pname}"
      jq -n \
        --arg type "volume" --arg object "${obj#$PREFIX}" --arg file_name "$pname" \
        --argjson size_bytes "$sz" --arg sha256 "$sha" \
        --arg tenancy "$vc_tenancy" --arg version "$vc_version" \
        --arg oracle_sid "$oracle_sid" --arg oracle_pdb "$oracle_pdb" \
        '{type:$type,object:$object,file_name:$file_name,size_bytes:$size_bytes,sha256:$sha256,
          tenancy:$tenancy,version:$version,oracle_sid:$oracle_sid,oracle_pdb:$oracle_pdb}' \
        >> "$ENTRIES"
      ;;
    script)
      pub="$src"
      if [[ "$base" == "start-lite-db.sh" ]]; then
        pub="$TMP/start-lite-db.sh"
        awk -v base="$RO_PREFIX" '
          /^DEFAULT_BASE_URL=/ && !done { print "DEFAULT_BASE_URL=\"" base "\""; done=1; next }
          { print }
        ' "$src" > "$pub"; chmod +x "$pub"
      fi
      sha="$(sha256 "$pub")"; sz="$(file_size "$pub")"
      obj="${PREFIX}script/${base}"
      jq -n \
        --arg type "script" --arg object "${obj#$PREFIX}" --arg file_name "$base" \
        --argjson size_bytes "$sz" --arg sha256 "$sha" \
        '{type:$type,object:$object,file_name:$file_name,size_bytes:$size_bytes,sha256:$sha256}' \
        >> "$ENTRIES"
      ;;
    *) echo "Skipping $src" >&2; continue ;;
  esac

  remote_sha=""
  if [[ -s "$REMOTE_MF" ]]; then
    remote_sha="$(jq -r --arg o "${obj#$PREFIX}" '.files[$o].sha256 // ""' "$REMOTE_MF")"
  fi
  status="upload"; [[ "$remote_sha" == "$sha" ]] && status="skip"
  printf '%s\t%s\t%s\t%s\t%s\n' "$status" "$pub" "$obj" "$sz" "$sha" >> "$UPLOADS"
  n=$((n+1))
done < <(find -L "$RELEASE_DIR/image" "$RELEASE_DIR/volume" "$RELEASE_DIR/script" \
  -maxdepth 1 -type f ! -name '.*' | sort)

[[ $n -eq 0 ]] && { echo "No files found." >&2; exit 1; }

# ── build manifest ─────────────────────────────────────────────────────────────
remote_json="{}"
[[ -s "$REMOTE_MF" ]] && remote_json="$(cat "$REMOTE_MF")"

files_json="$(jq -s 'map({(.object): .}) | add // {}' "$ENTRIES")"

launcher_json="$(jq -s '[.[] | select(.type=="script" and .file_name=="start-lite-db.sh")] | last // null' "$ENTRIES")"

jq -n \
  --argjson remote   "$remote_json" \
  --argjson files    "$files_json" \
  --argjson launcher "$launcher_json" \
  --arg channel   "$CHANNEL" \
  --arg prefix    "$PREFIX" \
  --arg now       "$NOW" \
  --arg ro_prefix "$RO_PREFIX" \
  --arg def_img   "$latest_docker_tag" \
  '
    $remote
    | del(.runtime_image, .volume_seed)
    | .name              = "oracle-lite-db"
    | .channel           = $channel
    | .published_at      = $now
    | .prefix            = $prefix
    | .read_only_prefix_url = $ro_prefix
    | if $def_img != "" then .default_image = $def_img else . end
    | .files             = ((.files // {}) * $files)
    | if $launcher != null then .launcher = $launcher else . end
  ' > "$LOCAL_MF"

# ── plan summary ───────────────────────────────────────────────────────────────
cat <<EOF
Publish plan
  Release dir : $RELEASE_DIR
  Prefix      : $PREFIX
  Remote mf   : $mf_state
  Default img : ${latest_docker_tag:-"(none)"}
  RW target   : $(redact "$(prefix_url "$RW_PAR" "$PREFIX")")
  RO prefix   : $(redact "$RO_PREFIX")

Objects:
EOF
uploads_needed=0
while IFS=$'\t' read -r status pub obj sz sha; do
  printf '  %-6s %s  (%s bytes)\n' "$status" "$obj" "$sz"
  [[ "$status" == "upload" ]] && uploads_needed=$((uploads_needed+1))
done < "$UPLOADS"

if [[ "$uploads_needed" -eq 0 ]]; then
  echo
  echo "Nothing to upload — all artifacts unchanged."
  exit 0
fi

printf '  upload %smanifest.json\n' "$PREFIX"

[[ "$DRY_RUN" -eq 1 ]] && { echo; echo "Dry run — nothing uploaded."; exit 0; }
confirm_upload || { echo "Cancelled."; exit 0; }

while IFS=$'\t' read -r status pub obj sz sha; do
  if [[ "$status" == "skip" ]]; then
    echo "  skip $obj (SHA unchanged)"
  else
    upload_file "$pub" "$obj"
  fi
done < "$UPLOADS"

upload_file "$LOCAL_MF" "${PREFIX}manifest.json"

echo
echo "Done. Download and run on another machine:"
echo "  curl -fsSL '${RO_PREFIX}script/start-lite-db.sh' | bash -s -- --tag dev-001"
