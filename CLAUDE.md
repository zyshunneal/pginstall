# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repository is a flat Ansible project for bootstrapping a PostgreSQL cluster, then configuring replication, PgBouncer, and cron jobs on the target hosts.

The repo does not use Ansible roles. The main logic is split across playbooks in `script/` and Jinja templates in `templates/`.

## Common commands

Run Ansible from `script/` so `ansible.cfg` is picked up automatically, or set `ANSIBLE_CONFIG=script/ansible.cfg`.

Full cluster bootstrap (the only required vars are `pgversion` and `servername`):

```bash
cd script && ansible-playbook cluster_init.yml -e "pgversion=17 servername=mydb"
```

Syntax-check before changing or committing playbooks/templates:

```bash
cd script && ansible-playbook cluster_init.yml --syntax-check -e "pgversion=17 servername=mydb"
```

Run only one stage of the workflow by tag (orchestrator is tag-driven):

```bash
cd script && ansible-playbook cluster_init.yml --tags prepare -e "pgversion=17 servername=mydb"
cd script && ansible-playbook cluster_init.yml --tags postf   -e "pgversion=17 servername=mydb"
```

Run a single phase playbook directly when iterating:

```bash
cd script && ansible-playbook init_master.yml -e "pgversion=17 servername=mydb"
```

Lightweight smoke / post-deploy validation:

```bash
cd script && ansible-playbook test.yml
cd script && ansible-playbook postf_check.yml -e "pgversion=17 servername=mydb"
```

Destructive cluster wipe (purges packages, data, pgbouncer state — never run in prod):

```bash
cd script && ansible-playbook clean_test_cluster.yml
```

There is no `ansible-lint`, `yamllint`, Molecule, or unit-test suite configured. Validation is playbook-driven.

## Inventory and execution assumptions

- Default inventory is `~/test.host`, configured in `script/ansible.cfg`. Host key checking is off; Ansible logs to `/tmp/cluster_init.log` on the control machine.
- Inventory groups: `master` (required, exactly one host), `slave` (optional), `offline` (optional, downstream tier of `slave`).
- New `when:` conditionals must use `groups.get('slave', [])` / `groups.get('offline', [])` style — direct `groups['offline']` will throw when the group is absent.
- `master` must contain exactly one host; `init_prepare.yml` fails early otherwise.

## Target host platform constraints

`postgres_install.sh::detect_os` hard-rejects anything that is not Debian 12, and `validate_pgversion` only accepts PostgreSQL 17 or 18. Anything else exits before touching the host.

The PGDG APT source uses the Aliyun mirror; the signing key is downloaded online from `https://mirrors.aliyun.com/postgresql/repos/apt/ACCC4CF8.asc` and dearmored into `/etc/apt/trusted.gpg.d/pgdg.gpg`. Hosts must be able to reach `mirrors.aliyun.com`. Stale `/etc/apt/sources.list.d/pgdg*.list` files are removed on each run before the first `apt-get update`.

## High-level architecture

### Main orchestration flow

`script/cluster_init.yml` statically imports the full bootstrap pipeline in this order:

1. `init_prepare.yml` — connectivity and topology prechecks; allows a `postgres -D /mnt/storage00/pg/data` process to exist (idempotent rerun) but fails if any other PG datadir is running.
2. `init_postgresql.yml` — OS / package install via `postgres_install.sh`.
3. `init_master.yml` — initialize the primary, run `user_init.sh`, render PG and PgBouncer config, restart services.
4. `init_slaveandoffline.yml` — build `slave` from `master` and `offline` from the first `slave` using `pg_basebackup`.
5. `reset_pghba.yml` — only re-aligns slave `pg_hba.conf` when the `offline` group is non-empty.
6. `start_slave_and_pgbouncer.yml` — restart replicas, fetch master-side PgBouncer config, propagate to non-master nodes, start their PgBouncer.
7. `postf_check.yml` — verify PG, PgBouncer, business-user connectivity, read/write, replication.
8. `deploy_cron.yml` — install maintenance/backup scripts and cron entries.

### Repository structure

- `script/`: all operational playbooks and helper shell scripts.
- `templates/postgresql_initialize/`: PostgreSQL config and `pg_hba.conf` templates.
- `templates/pgbouncer_initialize/`: PgBouncer config templates.
- `templates/script_template/`: maintenance scripts and cron file templates.

### Core scripts

`script/postgres_install.sh` is the install backbone: enforces Debian 12 + PG 17/18, sets up the Aliyun PGDG source, installs packages, ensures `postgres` / `pgbouncer` / `pgpool` system accounts and `/home/postgres` exist (some shipped packages on internal mirrors do not run their postinst user creation), creates the directory tree, applies sysctl/limits tuning, and symlinks `/usr/pgsql` to the chosen version's binary path.

`script/user_init.sh` runs only on the master:

- creates the standard roles (DO-block conditional, idempotent),
- creates database `${servername}` (idempotent via `\gexec`),
- enables `vector` and `vectorscale` extensions inside the business DB; the matching `postgresql-${major_version}-pgvector` and `postgresql-${major_version}-pgvectorscale` packages are installed by `postgres_install.sh`,
- creates schema `yay` and `yay.init_result_check_table`,
- generates the business user `${servername}`, only resetting its password via `ALTER USER` when the role pre-existed without a matching `.userinfo.conf` (steady-state reruns short-circuit and never rotate the password),
- writes `/home/postgres/.userinfo.conf`, which `init_master.yml` later reads back.

### Topology model

Inventory group membership drives behavior more than variables:

- `master`: the primary database host.
- `slave`: streaming replicas cloned from `master`.
- `offline`: optional downstream tier cloned from `groups['slave'][0]`.

Many playbooks refer to `groups['master'][0]` / `groups['slave'][0]`, so inventory shape matters.

### Configuration rendering

`init_master.yml` selects a PostgreSQL config template based on memory:

- ≥ 200000 MB → `postgresql.conf.12.j2`
- < 200000 MB → `postgresql.conf.test.12.j2`

Because `validate_pgversion` rejects anything below PG 17, the legacy `postgresql.conf.j2` / `postgresql.conf.test.j2` (the `< 12` branch templates) are not reached today. PG runtime config changes belong in the two `.12.j2` files; mirror to the legacy ones only if you intend to re-enable older versions.

`pg_hba.conf.master.j2` is rendered with the Jinja `template` module (not `copy`); a `{% for h in (groups.get('slave', []) + groups.get('offline', [])) | unique %}` loop emits per-host `host replication replication <ip>/32 scram-sha-256` rows, so master always trusts the current inventory's replicas.

PgBouncer config is rendered once on the master, then `fetch`ed to the control node and `copy`'d out to non-master hosts in `start_slave_and_pgbouncer.yml`.

## On-host paths and authentication

- Cluster data root is `/mnt/storage00/pg`. The data directory is the absolute path `/mnt/storage00/pg/data`. `/pg` is kept as a compat symlink to `/mnt/storage00/pg` so legacy templates (`/pg/bin/*.sh`, `/pg/arcwal`, `/pg/tlog`) keep resolving.
- Sibling dirs: `/mnt/storage00/{arcwal,backup,remote}`.
- The master `pg_hba.conf` enforces `local all postgres peer`. Anything that needs to run `psql -U postgres` on the local socket must do so as the `postgres` OS user — either via `become_user: postgres` on the task or, inside `user_init.sh`, via the `run_psql()` wrapper that `sudo -u postgres`-prefixes when not already postgres.
- `.pgpass` is rendered to **two** locations: `/home/postgres/.pgpass` (legacy convention) and `$(getent passwd postgres | cut -d: -f6)/.pgpass` (the actual postgres home — `/var/lib/postgresql` on Debian — which is what libpq reads as `~/.pgpass`). On master, `pgpass.master.j2` includes both replication and business-user entries; on slave/offline, `pgpass.j2` includes only the replication entry. Do not let replica setup overwrite the master's business `.pgpass`.

## Idempotency and safety boundaries

The pipeline is designed so that a failed mid-run can be re-driven by re-invoking `cluster_init.yml`. Specific guards:

- `postgres_install.sh::dir_init` reuses an existing `/mnt/storage00/pg` only when `/mnt/storage00/pg/data/PG_VERSION` is present; otherwise it cleans the stale shell and rebuilds. It never auto-deletes a real cluster.
- `init_master.yml` `initdb` has `creates: /mnt/storage00/pg/data/PG_VERSION`; `pg_ctl start` is gated by `pg_ctl status`; PgBouncer is killed by PID before being re-launched.
- `init_slaveandoffline.yml` introspects each replica's data dir before `pg_basebackup`: an existing standby is stopped and re-cloned cleanly; an existing **non-standby** PG cluster on a slave/offline host is treated as an unexpected production state and the play `fail`s rather than overwriting.
- `init_prepare.yml` lets a `postgres -D /mnt/storage00/pg/data` process keep running (so reruns don't trip on themselves) but still rejects PG processes pointing at any other datadir.
- `user_init.sh` short-circuits when `.userinfo.conf` + the database + the business role all already exist; otherwise every role / DB / schema / user statement is conditional, and the business user's password is reset every run so a partially-failed previous run can never desync.
- `sysctl -p` failures are tolerated (some keys are gone in newer kernels); kernel sysctl tweaks are advisory, not load-bearing.

## Working conventions for changes

- Prefer modifying the imported stage playbook or template that owns a behavior over wrapping it with another playbook.
- When changing a PostgreSQL runtime setting, update both `postgresql.conf.12.j2` and `postgresql.conf.test.12.j2` (mem-tiered branches). Don't bother with the non-`.12` templates unless you also relax `validate_pgversion`.
- When changing PgBouncer behavior, check master-side rendering in `init_master.yml` and replica-side propagation in `start_slave_and_pgbouncer.yml`.
- New `psql` calls executed locally on the master must run as the `postgres` OS user (either task-level `become_user: postgres` or `run_psql` in `user_init.sh`); `local all postgres peer` will reject anything else.
- Treat `clean_test_cluster.yml` as destructive infrastructure cleanup, not a normal test command — it `apt-get purge`s the PG packages.
- Git history uses short Chinese commit subjects ending in a full stop (`。`); match that style.
