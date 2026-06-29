# Oracle Runtime Image Slimming Progress

Date: 2026-06-27

Goal: create a smaller runtime-only Oracle 19c image for CI/dev that starts an existing supplied database volume. Fresh database creation remains the job of the original full image.

Base image:

`ofss-mum-4980.snbomprshared2.gbucdsint02bom.oraclevcn.com:5000/oracle/database/oracle-db:19.3.0-ee`

Stable test volume source:

`outputs/oracle-lite-seed/smbc-lite-seed-oradata-exp1-20260627.tar.gz`

## Baseline

- Base Docker image size: `7,729,553,212` bytes, about `7.20 GiB` / `7.73 GB`
- Base image reported size: `7.73GB`
- Base DB seed volume archive: `453M`
- Base DB seed raw volume: about `2.9G`

## Round 1

Status: built and mini-UT validated.

Strategy: remove low-risk runtime-unneeded Oracle Home assets, flatten the filesystem with `docker export` / `docker import`, restore runtime image metadata, and validate against a disposable restored copy of the v1 seed volume.

Planned removal set:

- `/opt/oracle/product/19c/dbhome_1/assistants`
- `/opt/oracle/product/19c/dbhome_1/apex`
- `/opt/oracle/product/19c/dbhome_1/ords`
- `/opt/oracle/product/19c/dbhome_1/sqldeveloper`
- `/opt/oracle/product/19c/dbhome_1/dmu`
- `/opt/oracle/product/19c/dbhome_1/R`
- `/opt/oracle/product/19c/dbhome_1/suptools`
- `/opt/oracle/product/19c/dbhome_1/OPatch`
- `/opt/oracle/product/19c/dbhome_1/oui`
- `/opt/oracle/product/19c/dbhome_1/install`
- `/opt/oracle/product/19c/dbhome_1/cv`
- `/opt/oracle/product/19c/dbhome_1/deinstall`

Expected filesystem reduction before flattening: about `1.91 GiB`.

Actual removal inside work container:

- Oracle Home before removal: `7144 MiB`
- Oracle Home after removal: `5197 MiB`
- Removed: `1947 MiB`, about `1.90 GiB`

Build result:

- Flattened filesystem image: `smbc/oracle-db-runtime:19.3.0-ee-r1-fs`
- Runtime metadata image: `smbc/oracle-db-runtime:19.3.0-ee-r1`
- Round 1 image size: `5,704,675,645` bytes, about `5.31 GiB` / `5.70 GB`
- Base image size: `7,729,553,212` bytes, about `7.20 GiB` / `7.73 GB`
- Docker image saving: `2,024,877,567` bytes, about `1.89 GiB` / `2.02 GB`

Disk note:

- First flatten import failed because Colima root filesystem was nearly full.
- Removed Docker build cache: about `1.049GB`.
- Removed unused image `container-registry.oracle.com/database/adb-free:latest-23ai`: about `5.04GB`.
- Retried flatten import successfully.

Startup validation:

- Container: `smbc-oracle-runtime-r1-test`
- Image: `smbc/oracle-db-runtime:19.3.0-ee-r1`
- Volume: `smbc-lite-seed-oradata-exp1`
- Ports: `3521:1521`, `3500:5500`
- Runtime used `--shm-size=2g` and `--tmpfs /dev/shm:rw,exec,size=2g`.
- Container reached Docker health status: `healthy`.
- `OBPMDB` opened read-write.

Known startup warning:

- Original Oracle script checks cgroup v1 path `/sys/fs/cgroup/memory/memory.limit_in_bytes`.
- On this Colima/cgroup v2 runtime that path does not exist, producing a warning and a unary operator message.
- This warning was also tolerated by the full image path and did not block startup.

Mini UT:

- Created throwaway source schema `CODEX_UT_SRC`.
- Created table `UT_ORDER`.
- Inserted two direct rows.
- Created procedure `ADD_UT_ORDER`.
- Ran procedure to insert row 3.
- Verified source row count: `3`.
- Verified source procedure status: `VALID`.
- Ran `expdp` from the slim image.
- Export completed successfully with 3 rows.
- Ran `impdp` using `REMAP_SCHEMA=CODEX_UT_SRC:CODEX_UT_TGT`.
- Import completed successfully.
- Verified target row count: `3`.
- Verified target amount sum: `138.24`.
- Verified target procedure status: `VALID`.
- Ran imported target procedure to insert row 4.
- Verified target row count after procedure: `4`.
- Verified row 4: `UT-IMPDP-PROC`, amount `42.42`.
- Dropped `CODEX_UT_SRC`, `CODEX_UT_TGT`, and directory object `CODEX_UT_DIR` after the test.

Mini UT note:

- First import attempt produced `ORA-39082` because the test procedure body hard-coded `CODEX_UT_SRC.UT_ORDER`.
- This was a useful test-design catch: schema-remap-safe PL/SQL should avoid hard-coded source schema references unless intentionally required.
- The UT was corrected to use unqualified `UT_ORDER` inside the procedure and then passed cleanly.

Evidence files:

- `round1.Dockerfile`
- `round1-mini-ut-setup.sql`
- `round1-mini-ut-verify.sql`
- `round1-mini-ut-cleanup.sql`
- `round1-mini-ut-expdp.log`
- `round1-mini-ut-impdp.log`

## Round 2

Status: built and mini-UT validated.

Strategy: start from round 1 and remove medium-risk optional filesystem assets while keeping `javavm`, `ctx`, XDB/XML-related files, core runtime, Data Pump, SQLPlus, and networking.

Removed paths:

- `/opt/oracle/product/19c/dbhome_1/md`
- `/opt/oracle/product/19c/dbhome_1/jdk`
- `/opt/oracle/product/19c/dbhome_1/perl`
- `/opt/oracle/product/19c/dbhome_1/sdk`
- `/opt/oracle/product/19c/dbhome_1/olap`
- `/opt/oracle/product/19c/dbhome_1/ord`
- `/opt/oracle/product/19c/dbhome_1/inventory`

Actual removal inside work container:

- Oracle Home before removal: `5197 MiB`
- Oracle Home after removal: `4058 MiB`
- Removed: `1139 MiB`, about `1.11 GiB`

Build result:

- Flattened filesystem image: `smbc/oracle-db-runtime:19.3.0-ee-r2-fs`
- Runtime metadata image: `smbc/oracle-db-runtime:19.3.0-ee-r2`
- Round 2 image size: `4,531,509,750` bytes, about `4.22 GiB` / `4.53 GB`
- Base image size: `7,729,553,212` bytes, about `7.20 GiB` / `7.73 GB`
- Round 2 saving vs base: `3,198,043,462` bytes, about `2.98 GiB` / `3.20 GB`
- Round 2 saving vs round 1: `1,173,165,895` bytes, about `1.09 GiB` / `1.17 GB`

Disk note:

- Removed unused image `container-registry.oracle.com/database/adb-free:latest`: about `4.26GB`.
- This was needed because Colima had only about `2.1G` free after round 1.

Startup validation:

- Container: `smbc-oracle-runtime-r2-test`
- Image: `smbc/oracle-db-runtime:19.3.0-ee-r2`
- Volume: `smbc-lite-seed-oradata-exp1`
- Ports: `3621:1521`, `3600:5500`
- Runtime used `--shm-size=2g` and `--tmpfs /dev/shm:rw,exec,size=2g`.
- Container reached Docker health status: `healthy`.
- `OBPMDB` opened read-write.

Component status after round 2:

- `XDB` was `VALID` in `CDB$ROOT` and `OBPMDB`.
- `XML` was `VALID` in `CDB$ROOT` and `OBPMDB`.
- `CONTEXT` was `VALID` in `CDB$ROOT` and `OBPMDB`.
- `JAVAVM` was `VALID` in `CDB$ROOT` and `OBPMDB`.
- `ORDIM` and `OWM` also reported `VALID` in both containers.

Mini UT:

- Created throwaway source schema `CODEX_UT_SRC`.
- Created table `UT_ORDER`.
- Inserted two direct rows.
- Created procedure `ADD_UT_ORDER`.
- Ran procedure to insert row 3.
- Verified source row count: `3`.
- Verified source procedure status: `VALID`.
- Ran `expdp` from the round 2 image.
- Export completed successfully with 3 rows.
- Export elapsed time: `0 00:09:01`.
- Ran `impdp` using `REMAP_SCHEMA=CODEX_UT_SRC:CODEX_UT_TGT`.
- Import completed successfully.
- Import elapsed time: `0 00:03:14`.
- Verified target row count: `3`.
- Verified target amount sum: `138.24`.
- Verified target procedure status: `VALID`.
- Ran imported target procedure to insert row 4.
- Verified target row count after procedure: `4`.
- Verified row 4: `UT-IMPDP-PROC`, amount `42.42`.
- Dropped `CODEX_UT_SRC`, `CODEX_UT_TGT`, and directory object `CODEX_UT_DIR` after the test.

Shutdown validation:

- `docker stop -t 120 smbc-oracle-runtime-r2-test` completed.
- Logs showed database closed, dismounted, redo thread closed, `ORACLE instance shut down`, and `Instance shutdown complete`.

Evidence files:

- `round2.Dockerfile`
- `round2-mini-ut-expdp.log`
- `round2-mini-ut-impdp.log`

Temporary containers removed:

- `smbc-oracle-runtime-slim-r2-work`
- `smbc-oracle-runtime-r1-test`
- `smbc-oracle-runtime-r2-test`

Image artifact:

- Saved image tarball: `smbc-oracle-db-runtime-19.3.0-ee-r2.image.tar.gz`
- Compressed size: `1,686,093,829` bytes, about `1.57 GiB` / `1.69 GB`
- Gzip integrity: passed
- SHA-256: `4f342d3ffeab7590ec20f2c218ea3b8459a0714ac05e95cbbfefc376513fb6ac`

Save/export note:

- First `docker save | gzip` failed because Docker needed temporary space inside Colima under `/var/lib/docker`.
- Removed superseded round 1 images:
  - `smbc/oracle-db-runtime:19.3.0-ee-r1`
  - `smbc/oracle-db-runtime:19.3.0-ee-r1-fs`
- Removed unused zero-container image `ghcr.io/open-webui/open-webui:main`, about `3.87GB`, to give Docker save enough VM-side workspace.
- Retried image save successfully.
- Removed internal tag `smbc/oracle-db-runtime:19.3.0-ee-r2-fs` after the final tarball was verified.

Current kept slim image:

- `smbc/oracle-db-runtime:19.3.0-ee-r2`

## OCI PAR Distribution Layout

Chosen object layout under the PAR object prefix `ci/`:

- `ci/manifest.json`
- `ci/image/smbc-oracle-db-runtime-19.3.0-ee-r2.image.tar.gz`
- `ci/volume/smbc-lite-seed-oradata-exp1-20260627.tar.gz`
- `ci/script/start-lite-db.sh`

There is one manifest file only: `manifest.json`. It carries the current opinionated channel value, Docker image tag, object names, sizes, SHA-256 values, and DB identifiers.

The build/publish machine uses `push-lite-db.sh` with the read-write PAR. The publisher assumes an opinionated local release folder with this structure:

- `image/`
- `volume/`
- `script/`

It downloads the existing remote `manifest.json` first when available, upserts every file found under those three local folders, skips files whose SHA-256 already matches the remote manifest, uploads changed files, and uploads the updated manifest last.

Developer/CI machines use the read-only PAR with:

```sh
curl -fsSL "<read-only-prefix-url>/script/start-lite-db.sh" | bash -s -- --tag smbc-001
```

`start-lite-db.sh` stores downloaded artifacts under `~/.frugal-ri` by default:

- `~/.frugal-ri/images/`
- `~/.frugal-ri/volumes/`

Use `--store-dir /path/to/store` to override it. If a cached artifact already has the expected SHA-256, the launcher skips the download.

`push-lite-db.sh` defaults to the current directory as the release folder. Use `--release-dir DIR` when publishing from another directory. If a file under `image/` or `volume/` is not gzip-compressed, the script creates `FILE.gz` next to it and publishes that gzip artifact. Files under `script/` are published as plain scripts. For `script/start-lite-db.sh`, the publisher bakes in the read-only PAR prefix URL so developer machines can use the one-line `curl | bash` flow.

Large uploads and downloads use curl's progress bar. Runtime container logs are captured under:

- `~/.frugal-ri/log/`

The startup monitor prints only newly appended log lines in grey and exits when Docker health becomes `healthy`. Pressing `Ctrl-C` exits the foreground monitor while leaving the DB container running.
