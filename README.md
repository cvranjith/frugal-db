# frugal-db: Oracle 19c Slim Docker Image + Minimal Volume Seed

Reduces the Oracle 19c Enterprise Docker image and its data volume for faster provisioning in CI/dev environments.

## Results

| Artifact | Original | Slim | Savings |
|----------|----------|------|---------|
| Docker image (loaded) | 9.14 GB | 2.58 GB | 72% |
| Docker image (tar.gz) | — | 571 MB | — |
| Volume seed (tar.gz) | 453 MB (exp1) | 438 MB (exp6) | 3% |

### What was removed from the image (r3 → r5)

- Oracle Spatial / MDSYS (`$OH/md/`) — not used
- Oracle Multimedia / ORDIM (`$OH/ord/`) — not used
- Intel MKL AVX (`libmkl_avx.so`, `libmkl_vml_avx.so`) — AVX2-only host
- Oracle Text engine libraries (`$OH/ctx/lib/`) — CTX_DDL not used
- Java JARs for OEM/WS client (`$OH/jlib/`) — server-side only
- SQL admin scripts (`$OH/rdbms/admin/`) — install/upgrade only
- OPatch history (`$OH/sqlpatch/`)
- RAC/grid/optional dirs (`has/`, `racg/`, `dv/`, `wwg/`, `mgw/`, `demo/`, `slax/`)
- UCP + Instant Client (`$OH/ucp/`, `$OH/instantclient/`)
- Install-time tools (`addnode/`, `clone/`, `diagnostics/`, `QOpatch/`, `css/`)
- Multi-layer squash: all iterations exported as single flat layer

### Volume seed changes (exp1 → exp6)

- Dropped MDSYS (Oracle Spatial) from CDB$ROOT, OBPMDB, and PDB$SEED
- Recreated UNDOTBS (CDB$ROOT: 6 MB, OBPMDB: 5 MB, PDB$SEED: 5 MB)
- Resized TEMP tablespaces to 10 MB each
- Redo logs: 3 × 4 MB (12 MB total)
- Cleared `pdb_plug_in_violations` so OBPMDB opens non-restricted

## Image

```
smbc/oracle-db-slim:19.3.0-r5
```

Available as tar.gz archives in this directory:
- `oracle-db-slim-r3.tar.gz` (967 MB)
- `oracle-db-slim-r4.tar.gz` (722 MB)
- `oracle-db-slim-r5.tar.gz` (571 MB) ← use this

Load the image:
```bash
docker load < oracle-db-slim-r5.tar.gz
```

## Volume Seed

Seed archive: `~/.frugal-ri/volumes/smbc-lite-seed-oradata-exp6-20260629.tar.gz` (438 MB)

| Seed | Size | Notes |
|------|------|-------|
| exp1 | 453 MB | Baseline (UT passes) |
| exp5 | 439 MB | MDSYS dropped from ROOT only; UT fails (PDB restricted) |
| exp6 | 438 MB | MDSYS dropped from all containers; UT passes ✓ |

Restore volume from tarball:
```bash
docker volume create oracle-oradata
docker run --rm --platform linux/amd64 \
  -v oracle-oradata:/opt/oracle/oradata \
  -v /path/to/smbc-lite-seed-oradata-exp6-20260629.tar.gz:/backup.tar.gz:ro \
  debian:bookworm-slim \
  tar xzf /backup.tar.gz -C /
```

Or copy from an existing volume (preferred — avoids SSHFS timeout on Colima):
```bash
docker volume create oracle-oradata-target
docker run --rm --platform linux/amd64 \
  -v oracle-oradata-source:/source:ro \
  -v oracle-oradata-target:/dest \
  debian:bookworm-slim \
  sh -c "cp -a /source/. /dest/"
```

## Running

```bash
docker run -d --name oracle-db \
  -e ORACLE_SID=OBCDB \
  -e ORACLE_PDB=OBPMDB \
  -e ORACLE_PWD=Oracle123 \
  -e INIT_SGA_SIZE=2G \
  -e INIT_PGA_SIZE=1G \
  --shm-size=2g \
  -v oracle-oradata:/opt/oracle/oradata \
  smbc/oracle-db-slim:19.3.0-r5
```

Wait for OBPMDB to open (typically 30–40 s with exp6 seed):
```bash
docker exec oracle-db bash -c \
  "echo \"select open_mode from v\\\$pdbs where name='OBPMDB';\" | sqlplus -s / as sysdba"
```

Expected output: `READ WRITE`

## Mini Unit Test

Validates schema creation, expdp, impdp, and row counts:
```bash
bash /tmp/mini-ut-vol2.sh smbc/oracle-db-slim:19.3.0-r5 <source-volume>
```

## Notes on Colima (Apple Silicon)

Use the x86 QEMU profile:
```bash
colima start --profile x86 --arch x86_64 --vm-type qemu --memory 6 --cpu 4 --disk 80
export DOCKER_HOST="unix://${HOME}/.colima/x86/docker.sock"
```

All docker commands must use `DOCKER_HOST` pointing to the x86 profile.
Scripts that mount Mac paths (`-v ~/...`) may time out due to SSHFS; use volume-to-volume copies instead.
