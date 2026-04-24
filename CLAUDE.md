# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repository is a flat Ansible project for bootstrapping a PostgreSQL cluster, then configuring replication, PgBouncer, and cron jobs on the target hosts.

The repo does not use Ansible roles. The main logic is split across playbooks in `script/` and Jinja templates in `templates/`.

## Common commands

Run Ansible from `script/` so `ansible.cfg` is picked up automatically, or set `ANSIBLE_CONFIG=script/ansible.cfg`.

```bash
cd script && ansible-playbook cluster_init.yml
```

Run the full cluster bootstrap with explicit required variables:

```bash
cd script && ansible-playbook cluster_init.yml -e "pgversion=14 servername=mydb"
```

Validate playbook syntax before changing or committing playbooks/templates:

```bash
cd script && ansible-playbook cluster_init.yml --syntax-check -e "pgversion=14 servername=mydb"
```

Run only one stage of the full workflow by tag:

```bash
cd script && ansible-playbook cluster_init.yml --tags prepare -e "pgversion=14 servername=mydb"
cd script && ansible-playbook cluster_init.yml --tags postf -e "pgversion=14 servername=mydb"
```

Run a single playbook directly when iterating on one phase:

```bash
cd script && ansible-playbook init_master.yml -e "pgversion=14 servername=mydb"
```

Run the lightweight smoke playbook:

```bash
cd script && ansible-playbook test.yml
```

Run the post-deploy validation playbook:

```bash
cd script && ansible-playbook postf_check.yml -e "pgversion=14 servername=mydb"
```

Clean a disposable test environment only:

```bash
cd script && ansible-playbook clean_test_cluster.yml
```

There is no configured `ansible-lint`, `yamllint`, Molecule, or unit-test suite in this repository. Validation is playbook-driven.

## Inventory and execution assumptions

- Default inventory is `~/test.host`, configured in `script/ansible.cfg`.
- Host key checking is disabled in `script/ansible.cfg`.
- Ansible logs to `/tmp/cluster_init.log` on the control machine.
- The playbooks expect inventory groups named `master`, `slave`, and optionally `offline`.
- `master` must contain exactly one host; `init_prepare.yml` fails early otherwise.
- Most workflows also expect `pgversion` and `servername` to be provided.

## High-level architecture

### Main orchestration flow

`script/cluster_init.yml` is the entrypoint. It statically imports the full bootstrap pipeline in this order:

1. `init_prepare.yml` — connectivity and topology prechecks.
2. `init_postgresql.yml` — OS/package installation by calling `postgres_install.sh`.
3. `init_master.yml` — initialize the primary PostgreSQL instance, create users/database/schema, render PostgreSQL and PgBouncer config, start services.
4. `init_slaveandoffline.yml` — build `slave` from `master` and `offline` from the first `slave` using `pg_basebackup`.
5. `reset_pghba.yml` — realign slave `pg_hba.conf` when the topology requires it.
6. `start_slave_and_pgbouncer.yml` — restart replica instances and copy PgBouncer config from master to replicas.
7. `postf_check.yml` — verify PostgreSQL, PgBouncer, business-user connectivity, read/write behavior, and replication.
8. `deploy_cron.yml` — install maintenance and backup scripts plus cron entries.

The orchestrator is tag-driven, so partial reruns usually happen through `cluster_init.yml --tags ...` rather than editing the imported playbooks.

### Repository structure

- `script/`: all operational playbooks plus helper shell scripts.
- `templates/postgresql_initialize/`: PostgreSQL config and `pg_hba.conf` templates.
- `templates/pgbouncer_initialize/`: PgBouncer config templates.
- `templates/script_template/`: maintenance scripts and cron file templates.

### Core scripts

`script/postgres_install.sh` is the installation backbone. It detects Debian/Ubuntu vs. RHEL/CentOS, installs PostgreSQL and related packages, ensures `/usr/pgsql` points at the selected version, creates the expected directory layout, and performs host-level setup.

`script/user_init.sh` is the logical database bootstrap step used only on the master. It:

- creates the standard roles,
- creates `putong-${servername}`,
- creates schema `yay` and the `init_result_check_table` validation table,
- generates the business user,
- writes `/home/postgres/.userinfo.conf`, which later playbooks read back.

### Topology model

Inventory group membership drives behavior more than variables:

- `master`: the primary database host.
- `slave`: streaming replicas cloned from `master`.
- `offline`: optional downstream replica tier cloned from the first `slave`.

Many playbooks refer to `groups["master"][0]` and `groups["slave"][0]`, so inventory shape matters.

### Configuration rendering

`init_master.yml` selects one of four PostgreSQL config templates based on:

- PostgreSQL major version: `< 12` vs. `>= 12`
- machine memory: above or below `200000` MB

That means config changes often need to be applied consistently across:

- `templates/postgresql_initialize/postgresql.conf.j2`
- `templates/postgresql_initialize/postgresql.conf.12.j2`
- `templates/postgresql_initialize/postgresql.conf.test.j2`
- `templates/postgresql_initialize/postgresql.conf.test.12.j2`

PgBouncer config is rendered once on the master, then fetched and copied to non-master nodes by `start_slave_and_pgbouncer.yml`.

### Important operational assumptions

- PostgreSQL data directory is exposed as `/pg/data`, with `/pg` symlinked to the physical storage root under `/mnt/storage00/postgresql/...`.
- PgBouncer config lives under `/etc/pgbouncer`.
- Replication setup uses `pg_basebackup` from the master or first slave.
- Several playbooks use shell commands heavily and assume target hosts already satisfy external prerequisites like SSH reachability, sudo, package repository access, and expected service accounts.

## Working conventions for changes

- Prefer changing the imported stage playbook or template that owns a behavior instead of adding another wrapper playbook.
- When modifying PostgreSQL runtime configuration, check whether the same change must be mirrored across both versioned and test templates.
- When modifying PgBouncer behavior, check both master-side template rendering and replica-side propagation in `start_slave_and_pgbouncer.yml`.
- Treat `clean_test_cluster.yml` as destructive infrastructure cleanup, not a normal test command.
- Git history in this repository uses short Chinese commit subjects; match that style when writing commits.
