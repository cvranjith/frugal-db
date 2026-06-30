#!/usr/bin/env bash
# start-lite-db.sh — provision and start an Oracle lite DB container.
# On first run (or when --force-download): fetches manifest from DEFAULT_BASE_URL,
# downloads the required image and volume seed, loads/restores them, starts the container.
#
# DEFAULT_BASE_URL is injected by push-lite-db.sh at publish time.
set -euo pipefail

DEFAULT_BASE_URL=""

# ── tunables ─────────────────────────────────────────────────────────────────
image_label=""        # --image LABEL       (image label/slot; default: manifest.default_image_label)
image_tar_file=""     # --image-tar FILE    (local file; bypasses manifest/download)
volume_version=""     # --volume VERSION    (version folder e.g. 20260629; default: latest)
volume_tar_file=""    # --volume-tar FILE   (local file; bypasses manifest/download)
tenancy=""            # --tenancy NAME      (entity/slot name; default: "default")

runtime_tag=""
db_port=""
oracle_pwd="Oracle123"
sga_size=""   # --sga SIZE  e.g. 1G, 2G (default: 1G)
pga_size=""   # --pga SIZE  e.g. 512M, 1G (default: 512M)

store_dir="${FRUGAL_RI_STORE:-${ORACLE_LITE_STORE_DIR:-$HOME/.frugal-ri}}"
share_dir="${ORACLE_LITE_SHARE_DIR:-}"   # resolved after container_name is known
base_url="${ORACLE_LITE_BASE_URL:-$DEFAULT_BASE_URL}"
force_download=1
replace_existing=0
assume_yes=0
wait_for_ready=1

usage() {
  cat <<'EOF'
Usage:
  ./start-lite-db.sh [options]

Artifact selection (all optional — resolved from manifest when omitted):
  --image LABEL         Image label/slot to use (default: manifest.default_image_label).
                        e.g. default, full — maps to image/<label>/ in the artifact store.
  --image-tar FILE      Use this local .tar.gz directly (skips manifest/download).
  --volume VERSION      Volume version to use (default: latest in entity folder, highest alpha).
                        e.g. 20260629 — maps to volume/<entity>/<version>/ in the artifact store.
  --volume-tar FILE     Use this local .tar.gz directly (skips manifest/download).
  --tenancy NAME        Entity/tenancy slot for volume selection (default: "default").
                        e.g. insg — only used when --volume-tar is not given.

Container options:
  --tag TAG             Runtime tag for naming the container/volume (e.g. dev-001).
  --port PORT           Host port for Oracle listener (container 1521).
  --sga SIZE            Oracle SGA size (e.g. 1G, 1536M). Default: 1G.
  --pga SIZE            Oracle PGA size (e.g. 512M, 1G).  Default: 512M.
  --share DIR           Host directory mounted as /share inside the container.
                        Default: ~/.frugal-ri/containers/<container-name>/share/
                        Override with env var ORACLE_LITE_SHARE_DIR.
  --replace             Remove any existing container/volume with the same tag.
  --yes                 Accept suggested tag/ports without prompting.
  --no-wait             Start and return without waiting for Oracle to become healthy.

Download options:
  --base-url URL        Artifact base URL (overrides DEFAULT_BASE_URL).
  --store-dir DIR       Local cache directory (default: ~/.frugal-ri).
  --use-cache           Skip re-download if manifest/image/volume already cached locally.
                        Default is always re-download to pick up the latest artifacts.

  -h, --help

Examples:
  ./start-lite-db.sh
  ./start-lite-db.sh --tag dev-001 --port 2521 --yes
  ./start-lite-db.sh --tenancy insg --tag dev-insg-01
  ./start-lite-db.sh --image full --volume 20260629
  ./start-lite-db.sh --tenancy insg --volume 20260630 --tag mydb
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image)          image_label="${2:?}";     shift 2 ;;
    --image-tar)      image_tar_file="${2:?}";  shift 2 ;;
    --volume)         volume_version="${2:?}";  shift 2 ;;
    --volume-tar)     volume_tar_file="${2:?}"; shift 2 ;;
    --tenancy)        tenancy="${2:?}";         shift 2 ;;
    --tag)            runtime_tag="${2:?}";     shift 2 ;;
    --port)           db_port="${2:?}";         shift 2 ;;
    --base-url)       base_url="${2:?}";        shift 2 ;;
    --store-dir|--cache-dir) store_dir="${2:?}"; shift 2 ;;
    --force-download) force_download=1;         shift ;;  # kept for back-compat; now the default
    --use-cache)      force_download=0;         shift ;;
    --replace)        replace_existing=1;       shift ;;
    --yes)            assume_yes=1;             shift ;;
    --sga)            sga_size="${2:?}";         shift 2 ;;
    --pga)            pga_size="${2:?}";         shift 2 ;;
    --share)          share_dir="${2:?}";        shift 2 ;;
    --no-wait)        wait_for_ready=0;         shift ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# ── utilities ────────────────────────────────────────────────────────────────
require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: required tool not found: $1" >&2; exit 1; }; }
is_tty()      { [[ -t 1 ]]; }

# Print timestamped line to console AND append to log file (if set).
log() {
  local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '[%s] %s\n' "$ts" "$*"
  [[ -n "${log_file:-}" ]] && printf '[%s] %s\n' "$ts" "$*" >> "$log_file"
}

# Cross-platform sha256: works on macOS (shasum), Linux, and Git Bash (sha256sum)
sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    echo "ERROR: no sha256 tool (need shasum or sha256sum)" >&2; exit 1
  fi
}

# Cross-platform file size
file_size_bytes() {
  stat -c '%s' "$1" 2>/dev/null || stat -f '%z' "$1" 2>/dev/null || \
    wc -c < "$1" | tr -d ' '
}


# ── preflight ─────────────────────────────────────────────────────────────────
# Set by preflight(); used in every docker run call.
# Empty on native x86_64 (--platform flag not needed and may fail on old Docker).
# "--platform linux/amd64" on Apple Silicon / non-x86 hosts.
DOCKER_PLATFORM=""

preflight() {
  local ok=1

  for cmd in docker gzip curl jq; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: missing required tool: $cmd" >&2; ok=0; }
  done
  # sha256 (shasum on macOS, sha256sum on Linux/Windows)
  { command -v shasum >/dev/null 2>&1 || command -v sha256sum >/dev/null 2>&1; } || \
    { echo "ERROR: missing sha256 tool (need shasum or sha256sum)" >&2; ok=0; }

  [[ "$ok" -eq 0 ]] && exit 1

  # Docker daemon running?
  docker info >/dev/null 2>&1 || {
    echo "ERROR: Docker daemon is not running (or DOCKER_HOST is not set correctly)." >&2; exit 1; }

  # Detect host architecture.
  # On native x86_64 we skip --platform (avoids failures on older Docker daemons).
  # On non-x86 hosts (Apple Silicon, ARM) we need --platform linux/amd64 + emulation.
  local native; native=$(docker system info --format '{{.Architecture}}' 2>/dev/null || true)
  if [[ "$native" == "x86_64" ]]; then
    DOCKER_PLATFORM=""
  else
    DOCKER_PLATFORM="--platform linux/amd64"
    docker run --rm --platform linux/amd64 --entrypoint /bin/sh \
      busybox:latest -c 'exit 0' >/dev/null 2>&1 || {
      echo "ERROR: Docker cannot run linux/amd64 images on this host." >&2
      echo "       macOS (Apple Silicon): enable Rosetta in Docker Desktop → Features in Beta." >&2
      echo "       Linux: install qemu-user-static  (apt install qemu-user-static binfmt-support)." >&2
      exit 1
    }
  fi
}

preflight

prompt_default() {
  local prompt="$1" default="$2" answer
  if [[ "$assume_yes" -eq 1 ]] || ! is_tty; then printf '%s\n' "$default"; return; fi
  read -r -p "$prompt [$default]: " answer; printf '%s\n' "${answer:-$default}"
}

confirm() {
  local prompt="$1" answer
  if [[ "$assume_yes" -eq 1 ]] || ! is_tty; then return 0; fi
  read -r -p "$prompt [Y/n]: " answer
  case "${answer:-Y}" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

validate_tag() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || {
    echo "Invalid tag '$1'. Use letters, numbers, dot, underscore, or dash." >&2; exit 1; }
}

port_in_use() {
  docker ps --format '{{.Ports}}' 2>/dev/null | grep -Eq ":$1->" && return 0
  command -v lsof >/dev/null 2>&1 && lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1 && return 0
  return 1
}

find_available_port() {
  local c
  for c in "$@"; do port_in_use "$c" || { printf '%s\n' "$c"; return; }; done
  c="${1:-2521}"
  while port_in_use "$c"; do c=$((c+1)); done
  printf '%s\n' "$c"
}

file_line_count() { [[ -f "$1" ]] && wc -l < "$1" | tr -d ' ' || printf '0\n'; }

sha256_matches() {
  [[ -n "$2" && -f "$1" ]] || return 1
  [[ "$(sha256_of "$1")" == "$2" ]]
}

# ── manifest helpers ──────────────────────────────────────────────────────────
MANIFEST_CACHE="$store_dir/manifest.json"

fetch_manifest() {
  local url="${base_url%/}/manifest.json" tmp="$MANIFEST_CACHE.tmp.$$"
  mkdir -p "$(dirname "$MANIFEST_CACHE")"
  echo "Fetching manifest from $url"
  curl --fail --location --show-error --retry 3 --connect-timeout 20 -o "$tmp" "$url"
  mv "$tmp" "$MANIFEST_CACHE"
}

need_manifest() {
  if [[ -z "$base_url" ]]; then
    echo "ERROR: --base-url (or DEFAULT_BASE_URL) is required to fetch the manifest." >&2
    echo "       Alternatively, supply --image-tar and --volume-tar directly." >&2
    exit 1
  fi
  if [[ "$force_download" -eq 1 || ! -f "$MANIFEST_CACHE" ]]; then
    fetch_manifest
  fi
}

# Returns TAB-separated: docker_tag  object  sha256  file_name
resolve_image_entry() {
  local label="$1" result
  [[ -z "$label" ]] && label="$(jq -r '.default_image_label // "default"' "$MANIFEST_CACHE" || true)"
  # Use // empty (not error()) so jq exits 0 on missing key; || true guards set -e
  # Note: "label" is a jq keyword (label-break) — use "lbl" to avoid parse error on jq 1.5
  result=$(jq -r --arg lbl "$label" '
    .images[$lbl] // empty
    | [.docker_tag, .object, (.sha256 // ""), (.file_name // "")] | @tsv
  ' "$MANIFEST_CACHE") || true
  [[ -z "$result" ]] && { echo "ERROR: no manifest entry for image label: $label" >&2; exit 1; }
  printf '%s\n' "$result"
}

# Returns TAB-separated: object  sha256  file_name  oracle_sid  oracle_pdb  version  entity
resolve_volume_entry() {
  local version="$1" entity="${2:-default}" result resolved_ver
  if [[ -z "$version" ]]; then
    resolved_ver="$(jq -r --arg e "$entity" '
      (.volumes[$e] // {}) | keys | sort | last // ""
    ' "$MANIFEST_CACHE")" || true
    [[ -z "$resolved_ver" ]] && {
      echo "ERROR: no volumes for entity=$entity in manifest" >&2; exit 1; }
  else
    resolved_ver="$version"
  fi
  result=$(jq -r --arg e "$entity" --arg v "$resolved_ver" '
    .volumes[$e][$v] // empty
    | [.object, (.sha256 // ""), (.file_name // ""),
       (.oracle_sid // "OBCDB"), (.oracle_pdb // "OBPMDB"),
       ($v), ($e)] | @tsv
  ' "$MANIFEST_CACHE") || true
  [[ -z "$result" ]] && {
    echo "ERROR: no volume for entity=$entity version=$resolved_ver" >&2; exit 1; }
  printf '%s\n' "$result"
}

_draw_bar() {
  local cur="$1" tot="$2" w=45
  local pct=0 fill=0
  [[ "$tot" -gt 0 ]] && pct=$(( cur * 100 / tot )) && fill=$(( cur * w / tot ))
  [[ $fill -gt $w ]] && fill=$w
  local bar="" i
  for ((i=1; i<fill; i++)); do bar="${bar}="; done
  [[ $fill -gt 0 ]] && bar="${bar}>"
  local speed_str="$3"
  printf '\r  [%-*s] %3d%%  %s' "$w" "$bar" "$pct" "$speed_str"
}

# Restore a tar.gz into a docker volume, showing a real percentage progress bar.
# Uses the already-loaded oracle image (no extra pull needed on air-gapped machines).
# dd reads the compressed file and reports bytes via status=progress for accurate %.
_restore_volume() {
  local src="$1" vol="$2" img="${3:-debian:bookworm-slim}"
  local sz; sz=$(file_size_bytes "$src")
  local sz_mb=$(( sz / 1024 / 1024 ))
  local vol_dir; vol_dir=$(cd "$(dirname "$src")" && pwd)
  local vol_base; vol_base=$(basename "$src")
  local progress_log; progress_log=$(mktemp)
  local w=45

  log "  Restoring $vol_base (${sz_mb}M)..."

  docker run --rm $DOCKER_PLATFORM \
    --user root --entrypoint /bin/bash \
    -v "${vol}:/opt/oracle/oradata" \
    -v "${vol_dir}:/backup:ro" \
    "$img" \
    -c "dd if='/backup/${vol_base}' bs=4M status=progress | gzip -dc | tar xf - -C /" \
    2>"$progress_log" &
  local pid=$!

  while kill -0 "$pid" 2>/dev/null; do
    local bytes=0
    bytes=$(tr '\r' '\n' < "$progress_log" 2>/dev/null | grep -oE '^[0-9]+' | tail -1) || true
    bytes=${bytes:-0}
    _draw_bar "$bytes" "$sz" "$(( bytes / 1024 / 1024 ))M / ${sz_mb}M"
    sleep 0.5
  done

  # Use || to prevent set -e from firing before we can print the error
  local rc=0
  wait "$pid" || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    _draw_bar "$sz" "$sz" "${sz_mb}M / ${sz_mb}M  done"
    printf '\n'
    log "  Restore complete: $vol_base (${sz_mb}M)"
  else
    printf '\n'
    log "  ERROR: volume restore failed (exit $rc)" >&2
    printf '  Docker output:\n' >&2
    cat "$progress_log" >&2
  fi
  rm -f "$progress_log"
  return "$rc"
}

download_artifact() {
  local url="$1" dest="$2" expected_sha="$3" label="$4"
  local tmp="$dest.tmp.$$"
  mkdir -p "$(dirname "$dest")"
  log "  Downloading $label"

  local total=0
  total=$(curl -fsSI --connect-timeout 10 "$url" 2>/dev/null \
    | grep -i '^content-length:' | tail -1 | awk '{print $2}' | tr -d '\r\n' || true)
  [[ "$total" =~ ^[0-9]+$ ]] || total=0

  curl --fail --location --silent --show-error \
    --retry 3 --connect-timeout 20 -o "$tmp" "$url" &
  local pid=$! t0=$SECONDS cur=0

  while kill -0 "$pid" 2>/dev/null; do
    cur=$(stat -c '%s' "$tmp" 2>/dev/null || stat -f '%z' "$tmp" 2>/dev/null || echo 0)
    local elapsed=$(( SECONDS - t0 + 1 )) speed=$(( cur / (SECONDS - t0 + 1) )) speed_str
    if   [[ $speed -ge 1048576 ]]; then speed_str="$(( speed/1048576 )) MB/s"
    elif [[ $speed -ge 1024    ]]; then speed_str="$(( speed/1024 )) KB/s"
    else speed_str="${speed} B/s"; fi
    _draw_bar "$cur" "$total" "$speed_str"
    sleep 1
  done
  wait "$pid" || { echo >&2; rm -f "$tmp"; return 1; }

  cur=$(stat -c '%s' "$tmp" 2>/dev/null || stat -f '%z' "$tmp" 2>/dev/null || echo 0)
  _draw_bar "$cur" "${total:-$cur}" "done"
  printf '\n'
  log "  Downloaded: $label ($(( cur / 1024 / 1024 ))M)"

  if [[ -n "$expected_sha" ]]; then
    local actual; actual="$(sha256_of "$tmp")"
    if [[ "$actual" != "$expected_sha" ]]; then
      rm -f "$tmp"
      echo "SHA mismatch for $label: expected=$expected_sha got=$actual" >&2; exit 1
    fi
  fi
  mv "$tmp" "$dest"
}

# ── wait-for-healthy ──────────────────────────────────────────────────────────
# Fixed viewport: 1 status row + _VIEW_LINES log rows.
# Each tick: go up TOTAL rows, rewrite all, cursor lands back at bottom.
_VIEW_LINES=5

wait_until_ready() {
  local container="$1" log_file="$2"
  local grey=$'\033[90m' rst=$'\033[0m' up=$'\033[A' clr=$'\033[2K'
  local state status
  local TOTAL=$((_VIEW_LINES + 1))   # status row + log rows

  trap "
    for _i in \$(seq 1 $TOTAL); do printf '${up}${clr}'; done
    printf 'Detached — container still running: $container\n'
    printf 'Log: $log_file\n'
    exit 130
  " INT

  echo
  printf 'Waiting for Oracle to become healthy (Ctrl-C to detach)\n'
  printf 'Log: %s\n' "$log_file"
  # reserve exactly TOTAL rows; cursor sits at bottom of block
  for _i in $(seq 1 $TOTAL); do printf '\n'; done

  while :; do
    state="$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || echo missing)"
    status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' \
      "$container" 2>/dev/null || echo unknown)"

    if [[ "$state" == "exited" || "$state" == "dead" ]]; then
      local exit_code; exit_code="$(docker inspect -f '{{.State.ExitCode}}' "$container" 2>/dev/null || echo ?)"
      for _i in $(seq 1 $TOTAL); do printf "${up}${clr}"; done
      printf 'Container stopped (state=%s exit=%s)\n' "$state" "$exit_code" >&2
      tail -40 "$log_file" 2>/dev/null || docker logs --tail 40 "$container" 2>/dev/null || true
      exit 1
    fi

    # jump to top of reserved block
    for _i in $(seq 1 $TOTAL); do printf "${up}"; done

    # row 1: status
    printf "${clr}${grey}[health: %-12s]  elapsed: %ss${rst}\n" "$status" "$SECONDS"

    # rows 2‥TOTAL: last _VIEW_LINES log lines, always exactly _VIEW_LINES rows
    tail -${_VIEW_LINES} "$log_file" 2>/dev/null \
      | awk -v n="$_VIEW_LINES" -v w="${COLUMNS:-120}" \
          -v g="$grey" -v r="$rst" -v c="$clr" '
        { printf "%s%s%.*s%s\n", c, g, w, $0, r; printed++ }
        END { while (printed++ < n) printf "%s\n", c }
      '
    # cursor is now back at the bottom of the block — same spot every tick

    if [[ "$status" == "healthy" ]]; then
      for _i in $(seq 1 $TOTAL); do printf "${up}${clr}"; done
      printf 'Oracle is ready (health: healthy)  [%ss]\n' "$SECONDS"
      trap - INT; return 0
    fi

    sleep 3
  done
}

# ── main ──────────────────────────────────────────────────────────────────────
# preflight already ran above — all tools verified

# ── interactive tag / log setup ──────────────────────────────────────────────
if [[ -z "$runtime_tag" ]]; then
  runtime_tag="$(prompt_default "Runtime tag" "dev-001")"
fi
validate_tag "$runtime_tag"

container_name="${runtime_tag}-db"
network_name="${runtime_tag}-net"
volume_name="${runtime_tag}-oradata"
[[ -z "$share_dir" ]] && share_dir="${store_dir}/containers/${container_name}/share"
log_dir="$store_dir/log"
log_file="$log_dir/${container_name}-$(date '+%Y%m%d-%H%M%S').log"
mkdir -p "$log_dir"

# ── resolve image ─────────────────────────────────────────────────────────────
resolved_docker_tag=""
resolved_image_file=""

if [[ -n "$image_tar_file" ]]; then
  [[ -f "$image_tar_file" ]] || { echo "Image tar not found: $image_tar_file" >&2; exit 1; }
  resolved_image_file="$image_tar_file"
  resolved_docker_tag="$(tar xOf "$image_tar_file" manifest.json 2>/dev/null \
    | jq -r '.[0].RepoTags[0] // ""')"
  log "Loading image from local file: $image_tar_file"
  gzip -dc "$resolved_image_file" | docker load
else
  need_manifest
  IFS=$'\t' read -r resolved_docker_tag img_obj img_sha img_fname \
    < <(resolve_image_entry "$image_label")
  log "Image: $resolved_docker_tag  (label: ${image_label:-default}  object: $img_obj)"

  # check if already in docker
  if [[ "$force_download" -eq 0 ]] && docker image inspect "$resolved_docker_tag" >/dev/null 2>&1; then
    log "Image already present in Docker — skipping load."
  else
    img_cache="$store_dir/images/$img_fname"
    if [[ "$force_download" -eq 0 ]] && sha256_matches "$img_cache" "$img_sha"; then
      log "Using cached image: $img_cache"
    else
      download_artifact "${base_url%/}/${img_obj}" "$img_cache" "$img_sha" "image"
    fi
    log "Loading image: $img_cache"
    gzip -dc "$img_cache" | docker load
  fi

  docker image inspect "$resolved_docker_tag" >/dev/null 2>&1 || {
    echo "ERROR: image $resolved_docker_tag not found after load." >&2; exit 1; }
fi

# ── resolve volume metadata (always needed for oracle_sid/oracle_pdb) ─────────
resolved_volume_file=""
oracle_sid="OBCDB"
oracle_pdb="OBPMDB"

if [[ -n "$volume_tar_file" ]]; then
  resolved_volume_file="$volume_tar_file"
else
  need_manifest
  IFS=$'\t' read -r vol_obj vol_sha vol_fname oracle_sid oracle_pdb vol_version vol_tenancy \
    < <(resolve_volume_entry "$volume_version" "${tenancy:-default}")
  log "Volume: $vol_fname  (entity=$vol_tenancy, version=$vol_version)"
  resolved_volume_file="$store_dir/volumes/$vol_fname"
fi

# ── ports ─────────────────────────────────────────────────────────────────────
if [[ -z "$db_port" ]]; then
  sug_db="$(find_available_port 2521 3521 4521 5521)"
  confirm "Use Oracle listener host port $sug_db" && db_port="$sug_db" \
    || db_port="$(prompt_default "Oracle listener host port" "$sug_db")"
fi

[[ "$db_port" =~ ^[0-9]+$ ]] || { echo "Port must be numeric." >&2; exit 1; }
port_in_use "$db_port" && { echo "Port $db_port already in use." >&2; exit 1; }

# ── replace existing ──────────────────────────────────────────────────────────
container_exists=0
volume_exists=0
docker ps -aq --filter "name=^/${container_name}$" 2>/dev/null | grep -q . && container_exists=1
docker volume ls -q 2>/dev/null | awk -v n="$volume_name" '$0==n' | grep -q . && volume_exists=1

if [[ "$container_exists" -eq 1 ]]; then
  if [[ "$replace_existing" -eq 1 ]]; then
    log "Removing container: $container_name"; docker rm -f "$container_name" >/dev/null
  else
    echo "Container $container_name exists. Use --replace or a different --tag." >&2; exit 1
  fi
fi

if [[ "$volume_exists" -eq 1 ]]; then
  if [[ "$replace_existing" -eq 1 ]]; then
    log "Removing volume: $volume_name"; docker volume rm "$volume_name" >/dev/null
    volume_exists=0
  fi
fi

# ── provision ─────────────────────────────────────────────────────────────────
docker network create "$network_name" >/dev/null 2>&1 || true

if [[ "$volume_exists" -eq 1 ]]; then
  log "Reusing existing volume: $volume_name"
else
  # download/verify seed only when we actually need to restore
  if [[ -n "$volume_tar_file" ]]; then
    [[ -f "$volume_tar_file" ]] || { echo "Volume tar not found: $volume_tar_file" >&2; exit 1; }
    log "Using local volume: $volume_tar_file"
  else
    if [[ "$force_download" -eq 0 ]] && sha256_matches "$resolved_volume_file" "$vol_sha"; then
      log "Using cached volume: $resolved_volume_file"
    else
      download_artifact "${base_url%/}/${vol_obj}" "$resolved_volume_file" "$vol_sha" "volume seed"
    fi
  fi
  log "Creating volume: $volume_name"
  docker volume create "$volume_name" >/dev/null
  _restore_volume "$resolved_volume_file" "$volume_name" "$resolved_docker_tag"
fi

[[ -z "$sga_size" ]] && sga_size="1G"
[[ -z "$pga_size" ]] && pga_size="512M"
# shm must be at least SGA size; parse value to MB for comparison
shm_mb=$(printf '%s' "$sga_size" | awk '/G$/{print int($0)*1024} /M$/{print int($0)}')
shm_arg="${sga_size}"

mkdir -p "$share_dir"
log "Starting container: $container_name  (SGA=$sga_size  PGA=$pga_size)"
docker run -dit $DOCKER_PLATFORM --name "$container_name" \
  --network "$network_name" \
  -p "$db_port:1521" \
  -e ORACLE_SID="$oracle_sid" \
  -e ORACLE_PDB="$oracle_pdb" \
  -e ORACLE_PWD="$oracle_pwd" \
  -e INIT_SGA_SIZE="$sga_size" \
  -e INIT_PGA_SIZE="$pga_size" \
  -v "$volume_name:/opt/oracle/oradata" \
  -v "$share_dir:/share" \
  --shm-size="$shm_arg" \
  "${resolved_docker_tag}" >/dev/null

nohup bash -c 'docker logs -f "$0" 2>&1 | while IFS= read -r line; do
  printf "[%s] %s\n" "$(date "+%Y-%m-%d %H:%M:%S")" "$line"
done' "$container_name" >> "$log_file" 2>/dev/null &
printf '%s\n' "$!" > "$log_file.pid"

[[ "$wait_for_ready" -eq 1 ]] && wait_until_ready "$container_name" "$log_file"

cat <<EOF

Oracle lite DB started.

  Tag       : $runtime_tag
  Image     : ${resolved_docker_tag:-unknown}
  SID / PDB : $oracle_sid / $oracle_pdb
  SGA / PGA : $sga_size / $pga_size
  Container : $container_name
  DB URL    : localhost:$db_port/$oracle_pdb
  Shared    : $share_dir  →  /share
  Log       : $log_file

Stop :  docker stop -t 120 $container_name
Remove: docker rm -f $container_name && docker volume rm $volume_name && docker network rm $network_name
EOF
