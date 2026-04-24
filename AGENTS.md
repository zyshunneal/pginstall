# Repository Guidelines

## Project Structure & Module Organization
This repository is a flat Ansible project for PostgreSQL cluster bootstrap and post-deploy setup. Core playbooks live in `script/`, with `cluster_init.yml` orchestrating the full flow by importing `init_prepare.yml`, `init_postgresql.yml`, `init_master.yml`, `init_slaveandoffline.yml`, and follow-up deployment checks. Jinja templates are grouped under `templates/postgresql_initialize/`, `templates/pgbouncer_initialize/`, `templates/monitor_template/`, and `templates/script_template/`. Helper shell scripts such as `postgres_install.sh`, `user_init.sh`, and `renamehost.sh` also live in `script/`.

## Build, Test, and Development Commands
Run Ansible from the `script/` directory so `ansible.cfg` is picked up, or set `ANSIBLE_CONFIG=script/ansible.cfg`.

- `cd script && ansible-playbook cluster_init.yml`: run the full cluster initialization workflow.
- `cd script && ansible-playbook cluster_init.yml --tags "prepare,install"`: execute selected stages only.
- `cd script && ansible-playbook cluster_init.yml --syntax-check`: validate playbook syntax before pushing changes.
- `cd script && ansible-playbook test.yml`: run the lightweight smoke playbook.
- `cd script && ansible-playbook clean_test_cluster.yml`: destroy a test environment; use only on disposable hosts.

Default inventory points to `~/test.host`. Keep inventory groups aligned with playbook expectations such as `master`, `slave`, and `offline`.

## Coding Style & Naming Conventions
Use 2-space indentation in YAML and Jinja templates. Keep playbooks task-oriented, with clear `name` fields and lower-case file names such as `init_master.yml`. Prefer `snake_case` variable names like `monitor_result` and `config_role`. Shell scripts should stay Bash-compatible, use executable shebangs, and keep helper functions in lower snake case. Preserve the existing `.j2` suffix for templates and avoid embedding secrets directly in playbooks.

## Testing Guidelines
There is no unit-test suite in this repository; validation is playbook-based. At minimum, run `--syntax-check` on changed playbooks and execute `test.yml` or the smallest relevant tagged run against a disposable inventory. When changing templates, verify the rendered target path and service restart behavior on a non-production host first.

## Commit & Pull Request Guidelines
Git history uses short, imperative subjects, mostly in Chinese. Follow that style: one concise subject per change, scoped to the affected playbook or template set. Pull requests should state the target environment, affected host groups, commands run for validation, and any risky operations such as package removal, data cleanup, or service restarts. Screenshots are unnecessary; include command output snippets instead when useful.
