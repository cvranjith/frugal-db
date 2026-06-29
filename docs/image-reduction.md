# Oracle 19c Docker Image Reduction — Methodology

Starting point: Oracle 19c EE Docker image, 7.73 GB loaded / ~9.14 GB (varies by pull).  
Final result: `oracle-db-slim:19.3.0-r5`, **2.58 GB loaded / 576 MB tar.gz**.

---

## Strategy

The Oracle runtime image carries a large amount of installation tooling, optional components, and development SDKs that are never used once the database is running. The approach is:

1. Start a work container from the base image.
2. Remove directories from `$ORACLE_HOME` that are not needed at runtime.
3. Flatten the modified filesystem with `docker export | docker import` to collapse all layers into one (recovering space from whiteout layers too).
4. Restore the original runtime metadata (entrypoint, env, healthcheck, user) lost during flatten.
5. Validate with a mini unit test (schema create → `expdp` → `impdp` → row count verify).
6. Repeat with more aggressive removals until something breaks, then back off one step.

---

## Iteration 1 (r1) — Low-risk tooling removal

**Removed from `$ORACLE_HOME`:**

| Directory | Contents |
|-----------|----------|
| `assistants` | DBCA / DBUA GUI configuration assistants |
| `apex` | Oracle APEX (app builder) |
| `ords` | Oracle REST Data Services |
| `sqldeveloper` | SQL Developer GUI |
| `dmu` | Database Migration Assistant |
| `R` | Oracle R integration |
| `suptools` | Support tools |
| `OPatch` | Patch installer |
| `oui` | Oracle Universal Installer |
| `install` | Install-time scripts |
| `cv` | Cluster Verification Utility |
| `deinstall` | Deinstall scripts |

**Oracle Home before:** 7,144 MiB → **after:** 5,197 MiB  
**Image size:** 7.73 GB → **5.70 GB** (−2.02 GB)

---

## Iteration 2 (r2) — Optional component removal

**Removed from `$ORACLE_HOME`:**

| Directory | Contents |
|-----------|----------|
| `md` | Oracle Spatial / MDSYS binaries |
| `jdk` | Bundled JDK (separate from JVM inside DB) |
| `perl` | Perl interpreter (install-time only) |
| `sdk` | Oracle Call Interface SDK headers |
| `olap` | Oracle OLAP (Analytic Workspaces) |
| `ord` | Oracle Multimedia / ORDIM |
| `inventory` | OUI inventory |

**Oracle Home before:** 5,197 MiB → **after:** 4,058 MiB  
**Image size:** 5.70 GB → **4.53 GB** (−1.17 GB vs r1, −3.20 GB vs base)

---

## Iteration 3 (r3) — Deeper library and script pruning

**Additional removals:**

| Path | Contents |
|------|----------|
| `ctx/lib/` | Oracle Text engine shared libraries |
| `jlib/` | Java JARs for OEM / Web Services client-side |
| `rdbms/admin/` | SQL DDL scripts for install/upgrade (not needed at runtime) |
| `sqlpatch/` | OPatch history records |
| `has/`, `racg/`, `dv/`, `wwg/`, `mgw/`, `demo/`, `slax/` | RAC, grid, Data Vault, Workspace Manager, Messaging, demo dirs |
| `ucp/` | Universal Connection Pool |
| `instantclient/` | Instant Client (not needed in server image) |
| `addnode/`, `clone/`, `diagnostics/`, `QOpatch/`, `css/` | Install-time / support tools |
| `lib/libmkl_avx.so`, `lib/libmkl_vml_avx.so` | Intel MKL AVX libraries (not available on target CPUs) |

**Image size:** 4.53 GB → **~3.6 GB** (further reduction, exact figure depends on host)

---

## Iteration 4 (r4) — Intermediate validated checkpoint

Further pruning of leftover SDK stubs, empty directories, and duplicate shared objects.  
**Image size (tar.gz):** 722 MB

---

## Iteration 5 (r5) — Final layer squash

All changes from r1–r4 applied in a single work container, then `docker export | docker import` done once — the result is a single flat layer with no Docker layer overhead.

**Final image:** `oracle-db-slim:19.3.0-r5`  
**Loaded size:** 2.58 GB  
**tar.gz:** 576 MB  
**Reduction from base:** **~72%**

### Flatten procedure

```bash
# 1. Start work container from base image
docker run -dit --name slim-work --platform linux/amd64 \
  <base-image> bash

# 2. Remove directories inside the container
docker exec slim-work bash -c "rm -rf \
  \$ORACLE_HOME/assistants \$ORACLE_HOME/apex \$ORACLE_HOME/ords \
  \$ORACLE_HOME/md \$ORACLE_HOME/jdk \$ORACLE_HOME/perl \
  \$ORACLE_HOME/sdk \$ORACLE_HOME/olap \$ORACLE_HOME/ord \
  \$ORACLE_HOME/ctx/lib \$ORACLE_HOME/jlib \$ORACLE_HOME/rdbms/admin \
  \$ORACLE_HOME/sqlpatch \$ORACLE_HOME/has \$ORACLE_HOME/racg \
  \$ORACLE_HOME/dv \$ORACLE_HOME/ucp \$ORACLE_HOME/instantclient \
  \$ORACLE_HOME/addnode \$ORACLE_HOME/clone \$ORACLE_HOME/diagnostics \
  \$ORACLE_HOME/QOpatch \$ORACLE_HOME/inventory \$ORACLE_HOME/install \
  \$ORACLE_HOME/oui \$ORACLE_HOME/OPatch \$ORACLE_HOME/deinstall \
  \$ORACLE_HOME/suptools \$ORACLE_HOME/R \$ORACLE_HOME/cv \
  \$ORACLE_HOME/lib/libmkl_avx.so \$ORACLE_HOME/lib/libmkl_vml_avx.so"

# 3. Flatten: export running container filesystem, re-import as new image
docker export slim-work | docker import \
  --change 'ENV ORACLE_BASE=/opt/oracle' \
  --change 'ENV ORACLE_HOME=/opt/oracle/product/19c/dbhome_1' \
  --change 'ENV ORACLE_SID=OBCDB' \
  --change 'ENV PATH=/opt/oracle/product/19c/dbhome_1/bin:...' \
  --change 'USER oracle' \
  --change 'ENTRYPOINT ["/bin/sh","-c","exec \$ORACLE_BASE/scripts/setup/runOracle.sh"]' \
  --change 'HEALTHCHECK ...' \
  - oracle-db-slim:19.3.0-r5

# 4. Clean up work container
docker rm -f slim-work
```

---

## Volume Seed Reduction

The data volume (`/opt/oracle/oradata`) starts at **~2.9 GB raw / 453 MB compressed (exp1)**.

### exp1 → exp6: MDSYS + tablespace shrinking

All SQL is run as `SYS` via `sqlplus / as sysdba`. Steps must be repeated in each container: `CDB$ROOT`, `OBPMDB`, and `PDB$SEED`.

**1. Drop Oracle Spatial (MDSYS)**

MDSYS holds 4,400+ objects across its schema but is never installed into application schemas unless they call `SDO_*` APIs. It occupies ~169 MB of free blocks in SYSAUX (root) and ~123 MB in each PDB's SYSAUX.

```sql
-- Must be run inside each container separately
ALTER SESSION SET "_oracle_script" = true;
DROP USER MDSYS CASCADE;
```

> Note: dropping MDSYS from `CDB$ROOT` only does NOT affect PDB copies — Oracle keeps separate local users per PDB. Each PDB must be entered individually.

> Note: after dropping MDSYS from `CDB$ROOT` only, PDBs may open in RESTRICTED mode due to a component registry mismatch flagged in `pdb_plug_in_violations`. Fix: drop MDSYS inside each PDB container.

**2. Shrink UNDO tablespace** (each container)

Oracle's undo tablespace can grow significantly during initial setup. Replace it with a fresh minimal one:

```sql
CREATE UNDO TABLESPACE undotbs2 DATAFILE SIZE 5M AUTOEXTEND ON NEXT 5M;
ALTER SYSTEM SET undo_tablespace = undotbs2;
DROP TABLESPACE undotbs1 INCLUDING CONTENTS AND DATAFILES;
ALTER TABLESPACE undotbs2 RENAME TO undotbs1;
```

Result: ~5–6 MB per container (from hundreds of MB).

**3. Shrink TEMP tablespace**

```sql
ALTER TABLESPACE temp SHRINK SPACE;
ALTER DATABASE TEMPFILE '/opt/oracle/oradata/.../temp01.dbf' RESIZE 10M;
```

**4. Shrink redo logs to minimum**

Oracle 19c minimum redo log size is **4 MB** (8,192 blocks × 512 bytes). Cannot go lower.

```sql
-- Add 3 new minimal groups, switch logs to them, drop old groups
ALTER DATABASE ADD LOGFILE GROUP 4 SIZE 4M;
ALTER DATABASE ADD LOGFILE GROUP 5 SIZE 4M;
ALTER DATABASE ADD LOGFILE GROUP 6 SIZE 4M;
ALTER SYSTEM SWITCH LOGFILE;
ALTER SYSTEM CHECKPOINT;
ALTER DATABASE DROP LOGFILE GROUP 1;
ALTER DATABASE DROP LOGFILE GROUP 2;
ALTER DATABASE DROP LOGFILE GROUP 3;
```

**5. Resize PDB$SEED**

PDB$SEED must be opened READ WRITE before changes, then returned to READ ONLY:

```sql
ALTER PLUGGABLE DATABASE pdb$seed CLOSE;
ALTER PLUGGABLE DATABASE pdb$seed OPEN READ WRITE;
-- ... make changes ...
ALTER PLUGGABLE DATABASE pdb$seed CLOSE;
ALTER PLUGGABLE DATABASE pdb$seed OPEN READ ONLY;
```

### exp6 → exp7: Disable XDB HTTP

EM Express uses XDB's HTTP listener, which starts a dispatcher thread at startup even when not needed. Disabled in all three containers:

```sql
-- In CDB$ROOT:
EXEC dbms_xdb_config.sethttpsport(0);
EXEC dbms_xdb_config.sethttpport(0);

-- In OBPMDB:
ALTER SESSION SET container = OBPMDB;
EXEC dbms_xdb_config.sethttpsport(0);
EXEC dbms_xdb_config.sethttpport(0);

-- In PDB$SEED (requires read-write open first):
ALTER PLUGGABLE DATABASE pdb$seed CLOSE;
ALTER PLUGGABLE DATABASE pdb$seed OPEN READ WRITE;
EXEC dbms_xdb_config.sethttpsport(0);
EXEC dbms_xdb_config.sethttpport(0);
ALTER PLUGGABLE DATABASE pdb$seed CLOSE;
ALTER PLUGGABLE DATABASE pdb$seed OPEN READ ONLY;
```

**Volume seed progression:**

| Seed | Compressed | Notes |
|------|-----------|-------|
| exp1 | 453 MB | Baseline (mini-UT passes) |
| exp5 | 439 MB | MDSYS dropped from CDB$ROOT only — PDB opens RESTRICTED (broken) |
| exp6 | 438 MB | MDSYS dropped from all three containers — UT passes |
| exp7 | 448 MB | exp6 + XDB HTTP disabled — runtime benefit (no dispatcher thread) |

> exp7 is slightly larger than exp6 because the XDB configuration writes touched SYSAUX and undo, and freed blocks in Oracle datafiles do not zero out on DROP/SHRINK — they only compress if actually zeroed.

---

## What Cannot Be Removed

| Component | Why |
|-----------|-----|
| `CDB$ROOT` | Root container — mandatory, Oracle cannot start without it |
| `PDB$SEED` | Template PDB — required by CDB architecture, cannot be dropped |
| `JAVAVM` | Oracle's internal JVM — used by built-in features even if you don't write Java |
| `XDB` / XML DB | Mandatory since 11g — provides many internal Oracle features beyond HTTP |
| `CONTEXT` | Oracle Text index engine — referenced by internal dictionary |

---

## Mini Unit Test

Each iteration was validated with:

1. Create schema `CODEX_UT_SRC` with table `UT_ORDER` and procedure `ADD_UT_ORDER`
2. Insert 3 rows (2 direct, 1 via procedure)
3. `expdp` to a dump directory
4. `impdp` with `REMAP_SCHEMA=CODEX_UT_SRC:CODEX_UT_TGT`
5. Verify row count = 3, procedure status = VALID in target schema
6. Run imported procedure to insert row 4, verify row count = 4
7. Clean up both schemas and directory object

This validates: SQLPlus, DDL, DML, Data Pump export/import, and PL/SQL — the core runtime surface.

---

## Key Lessons

- **Freed blocks don't compress**: dropping a schema frees logical space but Oracle does not zero the freed blocks. The `.dbf` file stays the same byte size on disk. Only physical file resize (`RESIZE`, `SHRINK SPACE`) reduces compressed archive size.
- **MDSYS scope**: `DROP USER MDSYS CASCADE` from CDB$ROOT does not cascade to PDBs. Each PDB maintains its own local copy.
- **Layer squash recovers whiteout overhead**: when you `rm -rf` inside a Dockerfile or running container, Docker keeps the old files as whiteout entries in the diff layer. A single `export | import` collapses this — the removed files are truly gone.
- **Redo log minimum**: Oracle 19c enforces a hard minimum of 4 MB per redo log group (ORA-00336 if you try smaller).
- **PDB$SEED changes**: must open PDB$SEED READ WRITE, make changes, then explicitly return to READ ONLY — it does not auto-revert.
- **Colima SSHFS mounts**: mounting macOS host paths into Colima containers via `-v ~/path:/mount` can timeout due to VirtioFS/SSHFS. Use volume-to-volume Docker copies instead (`docker run -v src:/s:ro -v dst:/d debian cp -a /s/. /d/`).
- **bash on macOS is 3.2**: no `mapfile`, `<(...)` process substitution works only when invoked as `bash`, not `sh`. Scripts must be run with `bash`, not `sh`.
