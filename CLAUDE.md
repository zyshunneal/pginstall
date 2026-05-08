# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repository is a flat Ansible project for bootstrapping a PostgreSQL cluster on Debian 12, then configuring replication, PgBouncer, vector extensions, and maintenance cron jobs on the target hosts.

The repo does not use Ansible roles. The main logic is split across playbooks in `script/` and Jinja templates in `templates/`.

## Common commands

Run Ansible from `script/` so `ansible.cfg` is picked up automatically, or set `ANSIBLE_CONFIG=script/ansible.cfg`.

Recommended preflight before changing deployment behavior:

```bash
cd script && ./preflight.sh
cd script && ./preflight.sh syntax
cd script && ./preflight.sh state
cd script && ./preflight.sh dryrun
```

`preflight.sh` defaults to `PGVERSION=17`, `SERVERNAME=agent`, and `INVENTORY=$HOME/test.host`; override them with environment variables when needed.

Full cluster bootstrap:

```bash
cd script && ansible-playbook cluster_init.yml -e "pgversion=17 servername=mydb"
```

Static syntax-check:

```bash
cd script && ansible-playbook cluster_init.yml --syntax-check -e "pgversion=17 servername=mydb"
```

Read-only state probe (`-v` shows the aggregated `cluster_state` fact):

```bash
cd script && ansible-playbook gather_state.yml -e "pgversion=17 servername=mydb" -v
```

Dry-run the whole pipeline:

```bash
cd script && ansible-playbook cluster_init.yml --check --diff -e "pgversion=17 servername=mydb"
```

Run only one stage of the workflow by tag:

```bash
cd script && ansible-playbook cluster_init.yml --tags prepare -e "pgversion=17 servername=mydb"
cd script && ansible-playbook cluster_init.yml --tags gather  -e "pgversion=17 servername=mydb"
cd script && ansible-playbook cluster_init.yml --tags master  -e "pgversion=17 servername=mydb"
cd script && ansible-playbook cluster_init.yml --tags postf   -e "pgversion=17 servername=mydb"
```

`init` and `slave` tags each hit more than one imported playbook; when iterating on one phase, prefer invoking that playbook directly.

Run a single phase playbook directly when iterating:

```bash
cd script && ansible-playbook init_master.yml -e "pgversion=17 servername=mydb"
cd script && ansible-playbook init_slaveandoffline.yml -e "pgversion=17 servername=mydb"
```

Post-deploy validation:

```bash
cd script && ansible-playbook postf_check.yml -e "pgversion=17 servername=mydb"
```

Lightweight smoke / ad-hoc test entrypoint:

```bash
cd script && ansible-playbook test.yml
```

Install per-host postgres_exporter (runs after cluster_init has produced `dbuser_monitor`; the prometheus-community Linux x86_64 binary ships with the repo at `pg_exporter/postgres_exporter`, expects `MONITOR_PASSWORD` in `~/.pginstall/secrets.env`):

```bash
cd script && ansible-playbook install_postgres_exporter.yml
cd script && ansible-playbook install_postgres_exporter.yml --tags exporter_verify
```

Destructive cluster wipe (purges packages, data, and PgBouncer state — never run in prod):

```bash
cd script && ansible-playbook clean_test_cluster.yml
```

There is no `ansible-lint`, `yamllint`, Molecule, or unit-test suite configured. Validation is playbook-driven.

## Inventory, secrets, and execution assumptions

- Default inventory is `~/test.host`, configured in `script/ansible.cfg`.
- Ansible logs to `~/cluster_init.log` on the control machine.
- Inventory groups: `master` (required, exactly one host), `slave` (optional), `offline` (optional, downstream tier of `slave`).
- `offline` nodes are cloned from `groups['slave'][0]`, and `deploy_cron.yml` also assumes `groups['slave'][0]` exists. Do not run those paths in a master-only inventory.
- Control-node secrets come from `~/.pginstall/secrets.env` when present, otherwise from `PGINSTALL_DBA_PASSWORD` and `PGINSTALL_REPLICATION_PASSWORD`.
- New `when:` conditionals must use `groups.get('slave', [])` / `groups.get('offline', [])` style — direct `groups['offline']` will throw when the group is absent.
- `master` must contain exactly one host; `init_prepare.yml` fails early otherwise.

## Target host platform constraints

`postgres_install.sh::detect_os` hard-rejects anything that is not Debian 12, and `validate_pgversion` only accepts PostgreSQL 17 or 18. Anything else exits before touching the host.

Package installation uses two external repos:

- PGDG APT source via the Aliyun mirror: `https://mirrors.aliyun.com/postgresql/repos/apt`
- Pigsty China mirror for extension packages such as `pgvectorscale`: `https://repo.pigsty.cc`

Hosts must be able to reach both. Stale `/etc/apt/sources.list.d/pgdg*.list` and `/etc/apt/sources.list.d/pigsty*.list` files are removed on each run before the first `apt-get update`.

## High-level architecture

### Main orchestration flow

`script/cluster_init.yml` statically imports the bootstrap pipeline in this order:

1. `init_prepare.yml` — connectivity and topology prechecks; allows a `postgres -D /mnt/storage00/pg/data` process to exist (idempotent rerun) but fails if any other PG datadir is running.
2. `gather_state.yml` — read-only probe that aggregates `cluster_state` about OS, repos, accounts, directories, PG status, business DB/user state, and PgBouncer status.
3. `init_postgresql.yml` — OS / package install via `postgres_install.sh`, split into preflight, apt-source, packages, accounts, dirs, and sysctl steps.
4. `init_master.yml` — initialize the primary, run `user_init.sh`, render PG and PgBouncer config, and verify business-user connectivity through PgBouncer.
5. `init_slaveandoffline.yml` — build `slave` from `master` and `offline` from the first `slave` using `pg_basebackup`.
6. `reset_pghba.yml` — only re-aligns slave `pg_hba.conf` when the `offline` group is non-empty.
7. `start_slave_and_pgbouncer.yml` — restart replicas if needed, fetch master-side PgBouncer config to the control node, propagate it to non-master nodes, and start their PgBouncer.
8. `postf_check.yml` — verify PG, PgBouncer, business-user connectivity, read/write, and replication.
9. `deploy_cron.yml` — install maintenance/backup scripts and cron entries.

### Repository structure

- `script/`: all operational playbooks and helper shell scripts.
- `templates/postgresql_initialize/`: PostgreSQL config, `pg_hba.conf`, and `.pgpass` templates.
- `templates/pgbouncer_initialize/`: PgBouncer config templates.
- `templates/script_template/`: maintenance scripts and cron file templates.

### Core scripts and ownership boundaries

`script/postgres_install.sh` is the install backbone: it enforces Debian 12 + PG 17/18, sets up the Aliyun PGDG source and Pigsty repo, installs packages, ensures `postgres` / `pgbouncer` / `pgpool` system accounts exist, creates the directory tree, applies sysctl/limits tuning, and symlinks `/usr/pgsql` to the chosen version's binary path.

`script/preflight.sh` is the recommended operator entrypoint before real runs. It wraps syntax-check, read-only state collection, and a full `--check --diff` dry-run.

`script/user_init.sh` runs only on the master:

- creates the standard roles (DO-block conditional, idempotent),
- creates database `${servername}` (idempotent via `\gexec`),
- enables `vector` and `vectorscale` inside the business DB,
- creates schema `yay` and `yay.init_result_check_table`,
- creates business user `${servername}` and only resets its password when the role pre-existed but `.userinfo.conf` was missing,
- writes `/home/postgres/.userinfo.conf`, which remains the authoritative source for the business username/password.

### Topology and configuration model

Inventory group membership drives behavior more than variables:

- `master`: the primary database host.
- `slave`: streaming replicas cloned from `master`.
- `offline`: optional downstream tier cloned from `groups['slave'][0]`.

Many playbooks refer to `groups['master'][0]` / `groups['slave'][0]`, so inventory shape matters.

`servername` directly determines both the business database name and the business username.

`init_master.yml` selects a PostgreSQL config template based on memory:

- `ansible_memtotal_mb >= 200000` → `postgresql.conf.12.j2`
- `ansible_memtotal_mb < 200000` → `postgresql.conf.test.12.j2`

Because `validate_pgversion` rejects anything below PG 17, the legacy `postgresql.conf.j2` / `postgresql.conf.test.j2` (the `< 12` branch templates) are not reached today.

`pg_hba.conf.master.j2` is rendered with the Jinja `template` module; a loop over `(groups.get('slave', []) + groups.get('offline', [])) | unique` emits per-host replication access rules, so master-side trust always follows the current inventory.

PgBouncer config is rendered on the master, then `start_slave_and_pgbouncer.yml` `fetch`es it to the control node and `copy`s it to non-master nodes.

## On-host paths and authentication

- Cluster data root is `/mnt/storage00/pg`. The data directory is `/mnt/storage00/pg/data`.
- `/pg` is kept as a compat symlink to `/mnt/storage00/pg` so legacy paths like `/pg/bin/*.sh` keep resolving.
- Sibling dirs: `/mnt/storage00/{arcwal,backup,remote}`.
- The master `pg_hba.conf` enforces `local all postgres peer`. Any local `psql -U postgres` call must run as the `postgres` OS user — either via `become_user: postgres` in Ansible or via `run_psql()` inside `user_init.sh`.
- `.pgpass` is rendered to **two** locations: `/home/postgres/.pgpass` (legacy path) and `$(getent passwd postgres | cut -d: -f6)/.pgpass` (the actual libpq lookup path, typically `/var/lib/postgresql/.pgpass` on Debian).
- On master, `pgpass.master.j2` includes both replication and business-user entries; on slave/offline, `pgpass.j2` includes only the replication entry. Do not let replica setup overwrite the master's business `.pgpass`.
- PgBouncer `userlist.txt` is rendered from the business user's SCRAM verifier in `pg_authid.rolpassword`; the master business `.pgpass` is rendered from `/home/postgres/.userinfo.conf`. When touching authentication, keep the DB role, `.userinfo.conf`, `.pgpass`, and PgBouncer userlist aligned.

## Idempotency and safety boundaries

The pipeline is designed so that a failed mid-run can be re-driven by re-invoking `cluster_init.yml`.

Specific guards:

- `preflight.sh state` and `gather_state.yml` are read-only probes and should stay read-only.
- `postgres_install.sh::dir_init` reuses an existing `/mnt/storage00/pg` only when `/mnt/storage00/pg/data/PG_VERSION` is present; otherwise it cleans the stale shell and rebuilds. It never auto-deletes a real cluster.
- `init_master.yml` `initdb --data-checksums` has `creates: /mnt/storage00/pg/data/PG_VERSION`; PostgreSQL starts only when `pg_ctl status` shows it is down; config changes trigger restart/reload only when the rendered files changed.
- `init_slaveandoffline.yml` introspects each replica's data dir before `pg_basebackup`: an existing standby is stopped and re-cloned cleanly; an existing **non-standby** PG cluster on a slave/offline host is treated as unexpected state and the play `fail`s rather than overwriting. Each replica uses an inventory-derived physical replication slot.
- `init_prepare.yml` lets a `postgres -D /mnt/storage00/pg/data` process keep running (so reruns do not trip on themselves) but still rejects PG processes pointing at any other datadir.
- `user_init.sh` short-circuits when `.userinfo.conf` + the database + the business role already exist; extensions are still synced, and the business password is only reset when the role pre-existed without a matching `.userinfo.conf`.
- `start_slave_and_pgbouncer.yml` only restarts replica PgBouncer when fetched master-side config changed.
- `sysctl -p` failures are tolerated in the install script; kernel sysctl tweaks are advisory, not load-bearing.

## Working conventions for changes

- Prefer modifying the imported stage playbook or template that owns a behavior over wrapping it with another playbook.
- When changing PostgreSQL runtime settings, update both `postgresql.conf.12.j2` and `postgresql.conf.test.12.j2`. Do not bother with the non-`.12` templates unless you also relax `validate_pgversion`.
- When changing PgBouncer behavior, check both master-side rendering in `init_master.yml` and replica-side propagation in `start_slave_and_pgbouncer.yml`.
- New local `psql` calls on the master must run as the `postgres` OS user; `local all postgres peer` will reject anything else.
- If you change deployment assumptions or validation expectations, update `preflight.sh` and/or `gather_state.yml` along with the main playbooks.
- Treat `clean_test_cluster.yml` as destructive infrastructure cleanup, not a normal test command — it `apt-get purge`s the PG packages and deletes the cluster directories.
- Git history uses short Chinese commit subjects ending in a full stop (`。`); match that style.
