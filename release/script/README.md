# oracle lite-db scripts

Scripts for provisioning, managing, and publishing the Oracle lite-db artifacts.

## Quick start (on any machine)

```bash
curl -fsSL '<read-only-prefix-url>/script/start-lite-db.sh' | bash -s -- --tag mydb-001
```

Requires: `docker` (with linux/amd64 support), `jq`, `curl`, `gzip`, `shasum` or `sha256sum`.  
Works on macOS, Linux, and Windows Git Bash.

---

## Scripts

### `start-lite-db.sh` — spin up a lite Oracle container

Downloads image + volume seed from OCI if not cached, restores the seed volume, starts the container, and monitors startup.

```bash
./start-lite-db.sh [options]

# Common options:
--tag TAG         Container name prefix (e.g. dev-001)
--port PORT       Host port for Oracle listener/1521 (default: auto)
--sga SIZE        Oracle SGA (e.g. 1G, 2G)  — default: 40% of host RAM
--pga SIZE        Oracle PGA (e.g. 512M, 1G) — default: 20% of host RAM
--tenancy CODE    Volume tenancy filter (default, IN, SG …)
--volume VERSION  Pin to a specific volume date e.g. 20260629
--replace         Remove existing container+volume with the same tag first
--yes             Skip interactive prompts
--no-wait         Start and return without waiting for healthy
--force-download  Re-download even if local cache is valid
```

**Cache location**: `~/.frugal-ri/` (override with `$FRUGAL_RI_STORE`)

---

### `push-lite-db.sh` — publish artifacts to OCI

Reads everything from `../image/`, `../volume/`, `../script/` relative to this script, computes SHAs, skips unchanged files, updates `manifest.json`.

```bash
bash push-lite-db.sh [options]

--dry-run     Show plan without uploading
--yes         Skip confirmation prompt
--prefix      OCI object prefix (default: ci/)
```

**Volume naming convention** (required for version/tenancy parsing):
```
oracle-volume-<tenancy>-v<YYYYMMDD>.tar.gz
```

---

### `export-volume.sh` — archive a Docker volume to a seed tar.gz

Use after making changes to a running Oracle container that you want to preserve as a new seed.

```bash
# 1. Make your changes in the running container
# 2. Shut down Oracle cleanly
docker exec <container> sqlplus / as sysdba <<< "shutdown immediate;"
# 3. Stop and remove the container (volume is preserved)
docker stop <container> && docker rm <container>
# 4. Export the volume
./export-volume.sh <volume-name> [--tenancy CODE] [--out DIR]
# Output: ~/.frugal-ri/volumes/oracle-volume-<tenancy>-v<YYYYMMDD>.tar.gz

# 5. Symlink into release/volume/ and push
ln -sf ~/.frugal-ri/volumes/oracle-volume-default-v20260629.tar.gz \
       ../volume/oracle-volume-default-v20260629.tar.gz
bash push-lite-db.sh
```

---

### `export-image.sh` — save a Docker image to a tar.gz for publishing

```bash
./export-image.sh oracle-db-slim:19.3.0-r5 [--out DIR]
# Output: ~/.frugal-ri/images/oracle-db-slim--19.3.0-r5.tar.gz

# Symlink into release/image/ and push
ln -sf ~/.frugal-ri/images/oracle-db-slim--19.3.0-r5.tar.gz \
       ../image/oracle-db-slim-r5.tar.gz
bash push-lite-db.sh
```

The docker tag is read directly from the tar.gz — no `.meta.json` sidecar needed.

---

## Release directory layout

```
release/
  image/    ← docker image tarballs (symlinks ok)
  volume/   ← seed volume tarballs  (symlinks ok)
  script/   ← these scripts (this directory)
```

---

## Stopping / cleaning up

```bash
# Stop
docker stop -t 120 <tag>-db

# Full teardown
docker rm -f <tag>-db
docker volume rm <tag>-oradata
docker network rm <tag>-net
```

Logs are tailed to: `~/.frugal-ri/log/<container>-<timestamp>.log`
