# database_cluster_autoinit

一套用于在 **Debian 12** 主机上一键拉起 **PostgreSQL 17 / 18** 主备集群（含 PgBouncer、cron 维护脚本、流复制从库、可选 offline 下游、默认启用 **pgvector / pgvectorscale** 向量扩展）的 Ansible 项目。

整条 pipeline 设计为**可重复执行**：稳态重跑不会重启已运行的 PG / PgBouncer，配置文件无变化就不触发任何服务动作。

---

## 一、适用范围与硬约束

- 控制机：任意装有 `ansible-playbook`（≥ 2.9）和 `python3` 的 Linux/macOS。
- 目标机：**Debian 12 (bookworm)**。`script/postgres_install.sh::detect_os` 直接 `fail` 其它系统。
- PG 版本：**仅 17 或 18**。`validate_pgversion` 拒绝其它版本。
- APT 软件源：PostgreSQL 官方包使用 **阿里云镜像** `https://mirrors.aliyun.com/postgresql/repos/apt`，额外扩展包使用 **Pigsty 中国镜像** `https://repo.pigsty.cc`。目标机必须能访问 `mirrors.aliyun.com` 和 `repo.pigsty.cc`。
- 物理布局：所有 PG 数据 / 归档 / 备份都落在 `/mnt/storage00/`。挂载与剩余空间需要事先准备好。
- 拓扑：1 台 master（必选）+ N 台 slave（可选）+ N 台 offline（可选）。`master` 必须**只**有 1 台。

---

## 二、仓库结构

```
.
├── README.md                       本文档
├── CLAUDE.md / AGENTS.md           AI 协作指南
├── script/                         所有可执行入口
│   ├── cluster_init.yml            主编排，按顺序 import 9 个子 playbook
│   ├── init_prepare.yml            连通性 + 拓扑预检
│   ├── gather_state.yml            只读现场探测，注册 cluster_state fact
│   ├── init_postgresql.yml         调 postgres_install.sh 装包/调内核
│   ├── init_master.yml             initdb / 配置渲染 / pgbouncer / handler 化
│   ├── init_slaveandoffline.yml    pg_basebackup 拉从库 / offline
│   ├── reset_pghba.yml             仅当存在 offline 时校准 slave 的 pg_hba
│   ├── start_slave_and_pgbouncer.yml  从库 PG / PgBouncer 状态对齐
│   ├── postf_check.yml             部署后自检
│   ├── deploy_cron.yml             安装维护 cron
│   ├── postgres_install.sh         OS 层全部安装/调优主循环
│   ├── user_init.sh                数据库 schema / 用户初始化
│   ├── preflight.sh                语法 / 探测 / 干跑统一封装
│   ├── clean_test_cluster.yml      测试环境一键清理（destructive）
│   ├── ansible.cfg                 inventory / log_path / 互信配置
│   └── ...                         test.yml 等小工具
└── templates/
    ├── postgresql_initialize/      postgresql.conf 与 pg_hba.conf 模板
    ├── pgbouncer_initialize/       pgbouncer.ini / userlist.txt / pgb_hba.conf
    └── script_template/            cron 与 vacuum/repack/backup 脚本模板
```

---

## 三、快速开始

### 1. 准备 inventory

控制机的家目录写一个 `~/test.host`（或自定义路径）：

```ini
[master]
10.159.108.45

[slave]
10.159.108.46
10.159.110.30

# offline 可选
# [offline]
# 10.159.111.10
```

每台目标机需要：

- SSH 互信到控制机当前用户（公钥已落 `~/.ssh/authorized_keys`）。
- 当前用户能 `sudo` 免密。
- 已挂载 `/mnt/storage00`（数据目录会落在这里）。
- 能访问 `mirrors.aliyun.com`（用于安装 PG / pgbouncer 包）。

### 2. 验证（推荐）

```bash
cd script
./preflight.sh                # 默认依次跑 syntax / state / dryrun
./preflight.sh syntax         # 只静态语法
./preflight.sh state          # 只现场探测，看 cluster_state fact
./preflight.sh dryrun         # ansible --check --diff 整体干跑
```

通过环境变量调整：

```bash
PGVERSION=18 SERVERNAME=demo INVENTORY=/path/to/hosts ./preflight.sh
```

### 3. 真跑

```bash
cd script
ansible-playbook cluster_init.yml -e "pgversion=17 servername=agent" -i ~/test.host
```

`servername` 决定业务库名 `putong-${servername}` 与业务用户名 `dbuser_<servername>`（去掉 `-`）。

---

## 四、命令速查

| 目的 | 命令 |
|---|---|
| 完整安装 / 重跑 | `cd script && ansible-playbook cluster_init.yml -e "pgversion=17 servername=agent"` |
| 只跑某阶段 | `--tags prepare` / `install` / `master` / `slave` / `pghba` / `start` / `postf` / `cron` |
| 单文件迭代 | `cd script && ansible-playbook init_master.yml -e "pgversion=17 servername=agent"` |
| 仅查现场状态 | `cd script && ansible-playbook gather_state.yml -e "pgversion=17 servername=agent" -v` |
| 部署后自检 | `cd script && ansible-playbook postf_check.yml -e "pgversion=17 servername=agent"` |
| 测试环境一键清理 | `cd script && ansible-playbook clean_test_cluster.yml`（**会卸包+删数据**） |
| 三步预检 | `cd script && ./preflight.sh` |
| 静态语法 | `cd script && ./preflight.sh syntax` 或原生 `--syntax-check` |
| 修改远端日志位置 | 改 `script/ansible.cfg` 里 `log_path`，默认 `~/cluster_init.log` |

---

## 五、整条 pipeline 做了什么

`cluster_init.yml` 静态 import 顺序：

1. **init_prepare** — 连通性 ping，topology 校验。允许 `/mnt/storage00/pg/data` 自有 PG 进程存在（重跑友好）；任何指向其它 datadir 的 PG 进程会拦下。
2. **gather_state**（只读）— 探测 OS、apt 源、用户/组、目录、`PG_VERSION`、`pg_ctl status`、`pg_is_in_recovery()`、业务库 / 业务角色 / `.userinfo.conf`、pgbouncer 进程与三个配置文件 md5。结果聚合到 host fact `cluster_state`。
3. **init_postgresql** — 跑 `postgres_install.sh`：包装 PGDG 阿里云镜像 + Pigsty 中国扩展镜像、装包、补建 `postgres / pgbouncer / pgpool` 系统账号、构建数据目录树（`/mnt/storage00/pg/{bin,conf,data,tlog,tmp}`）、`/pg → /mnt/storage00/pg` 兼容软链、`/usr/pgsql → /usr/lib/postgresql/<v>`、内核与 limits 调优。`postgresql-<v>-pgvector` 与 `postgresql-<v>-pgvectorscale` 是必装包，缺失会直接失败。
4. **init_master** — `initdb`（`creates: PG_VERSION` 守卫）→ 启动 PG（`pg_ctl status` 守卫）→ `user_init.sh`（角色 / 业务库 / schema / 业务用户，并在业务库内 `CREATE EXTENSION vector/vectorscale`，密码同步策略见下文）→ 渲染 `postgresql.conf` / `pg_hba.conf` / pgbouncer 三件套，**仅当文件 changed** 才 `notify` handler 去 reload / restart。
5. **init_slaveandoffline** — `.pgpass` 同步到 `/home/postgres` 和 `getent` 取到的 postgres 真实 home；探测 standby 状态：已是 standby 则停机重做、非 standby 但有 PG_VERSION 主动 `fail`、空目录直接 basebackup。
6. **reset_pghba** — 只有 inventory 含 `offline` 时才会去校准 slave 的 `pg_hba.conf`。
7. **start_slave_and_pgbouncer** — slave / offline 上 PG 未跑才 start；从 master 拉 pgbouncer 配置 copy 到从库，**仅 changed 时**触发 pgbouncer 重启。
8. **postf_check** — 主从连通性、业务用户、读写、复制延迟自检。
9. **deploy_cron** — `repack.sh` / `vacuum.sh` / `pg_backup.sh` 与 cron 文件就位。

---

## 六、幂等与"重跑零副作用"保证

每一步的设计都遵循 **"先探测，再按差异动手"**：

| 组件 | 探测口径 | 不一致才动 | 一致时的行为 |
|---|---|---|---|
| 数据目录树 | `[ -f /mnt/storage00/pg/data/PG_VERSION ]` | 缺失或残骸 → 清理重建 | 已就绪 → 不动 |
| initdb | `creates: /mnt/storage00/pg/data/PG_VERSION` | 不存在才 initdb | 跳过 |
| PG 启动 | `pg_ctl status` | 未跑才 `pg_ctl start` | 跳过 |
| postgresql.conf | template 内置 hash 比对 | changed → handler `restart postgresql` | **不 restart** |
| pg_hba.conf | 同上 | changed → handler `reload postgresql` | **不 reload** |
| 业务用户密码 | `.userinfo.conf` 存在 + DB + role 都齐 → 短路 reuse | role 已存在但 `.userinfo.conf` 丢失才 ALTER | **不旋转密码** |
| pgbouncer 三件套 | template hash 比对 | changed → handler `restart pgbouncer` | **不 restart** |
| pgbouncer 进程 | `kill -0 $(cat .pid)` | 未跑才 start | 跳过 |
| pg_basebackup | 检查 `standby.signal` | 已是 standby 才停机重做；非 standby 主动 `fail` | 跳过 |

稳态重跑预期表现：

```
PLAY RECAP **********
hostA  : ok=N  changed=0  failed=0
hostB  : ok=N  changed=0  failed=0
```

且**不会**出现 `RUNNING HANDLER [restart ...]` / `[reload ...]`。可以在每台机器上比 `mtime` 来交叉验证：

```bash
stat -c '%y %n' /mnt/storage00/pg/data/postmaster.pid /var/run/pgbouncer/pgbouncer.pid
```

两次 cluster_init.yml 之间这两个 pid 文件的修改时间不变即 OK。

---

## 七、安全边界

脚本设计下面这些情况会**主动 `fail` 而非自动覆盖**，保护已有数据：

- `dir_init` 见 `/mnt/storage00/pg/data/PG_VERSION` 已存在，但 inventory 拓扑里这台机器是 slave / offline → `fail`，要求人工介入（防止把别人的主库当残骸清掉）。
- `init_prepare` 见 `postgres -D /<其它路径>` 的进程 → `fail`（防误中无关 PG 实例）。
- `init_postgresql.yml` 安装结束的 `systemctl stop postgresql/pgbouncer` 仅当 systemd unit `is-active` 且我们的 cluster pid 文件**不在**时才执行。
- master `pg_hba.conf` 把 `local all postgres` 设为 `peer`：所有本地 `psql -U postgres` 必须以 `postgres` OS 用户身份执行（`become_user: postgres` 或 `user_init.sh` 内的 `run_psql` 会 `sudo -u postgres`）。
- 业务用户密码：仅在"role 已存在但 `.userinfo.conf` 丢失"这一恢复路径下才 `ALTER USER`；正常重跑命中早期短路，密码完全不会被旋转。

---

## 八、路径约定

| 路径 | 用途 |
|---|---|
| `/mnt/storage00/pg/` | 真实 cluster 根（数据 / WAL / 配置）|
| `/mnt/storage00/pg/data/` | PostgreSQL `-D` 指向的物理数据目录 |
| `/mnt/storage00/{arcwal,backup,remote}/` | WAL 归档 / 备份 / 远端落地 |
| `/pg` → `/mnt/storage00/pg` | 兼容软链（cron / archive_command 中的 `/pg/bin`、`/pg/arcwal`、`/pg/tlog` 仍可解析）|
| `/usr/pgsql` → `/usr/lib/postgresql/<v>` | 当前选定 PG 大版本的 bin 路径根 |
| `/etc/pgbouncer/` | pgbouncer 配置（master 渲染，slave/offline copy）|
| `/var/run/pgbouncer/pgbouncer.pid` | pgbouncer 进程 pid 文件 |
| `/var/run/postgresql/` | PG 默认 unix socket 目录 |
| `/home/postgres/` | 脚本额外创建的目录，存 `.userinfo.conf` 与一份 `.pgpass` |
| `$(getent passwd postgres \| cut -d: -f6)/.pgpass` | libpq 真实查找的 `.pgpass`（Debian 上是 `/var/lib/postgresql/.pgpass`）|
| `~/cluster_init.log` | ansible run 日志，per-user 写在控制机当前用户家目录 |

---

## 九、故障排查（按曾经踩过的坑）

| 现象 | 根因 | 处理 |
|---|---|---|
| `apt-get update` 报 `NO_PUBKEY 7FCC7D46ACCC4CF8` | 残留 `/etc/apt/sources.list.d/pgdg*.list` 指向官方源 | 脚本已自动清理；如果还出，手动 `rm /etc/apt/sources.list.d/pgdg*.list` 后重跑 |
| 系统源 403 / 域名不可达 | `/etc/apt/sources.list` 指向不可达镜像（如 tuna） | 改成内网可达镜像；本仓库不接管系统源 |
| `sysctl -p` 失败 | 新内核已删 `tcp_tw_recycle` / `extra_free_kbytes` | 已在脚本中删除并对失败容忍，无需处理 |
| `/etc/pgbouncer/...: chown failed: failed to look up user pgbouncer` | 包 postinst 没建系统账号 | `ensure_service_accounts` 已自动兜底；如果还在，手动 `adduser --system --ingroup pgbouncer pgbouncer` |
| `Peer authentication failed for user "postgres"` | root 直接 `psql -U postgres` 撞 pg_hba 里的 `peer` | 必须 `sudo -u postgres psql ...`；`user_init.sh` 已自动；自定义 task 加 `become_user: postgres` |
| `pg_basebackup ... no pg_hba.conf entry for replication` | master 没给 slave/offline 段 IP 开 replication | `pg_hba.conf.master.j2` 自动按 inventory 列出每台 slave/offline 的 `/32`；inventory 改了重跑 master 即可 |
| `pg_basebackup` 卡住等密码 | libpq 取不到 `.pgpass`：postgres 真实 home 不是 `/home/postgres` | 脚本已同时写两份 `.pgpass`；如果跑过老版本残留旧 home，删掉重跑即可 |
| `'dict object' has no attribute 'offline'` 等 | inventory 没有该可选组 | 已统一改成 `groups.get('xxx', [])`；自定义 when 时也照此写法 |
| `Directory /mnt/storage00/postgresql/agentdb_17 exists` | 旧版（按 servername+version 隔离目录）残骸 | `mv /mnt/storage00/postgresql/<old>db_<v> /mnt/storage00/pg` 复用，或 `rm -rf` 重做 |
| `PermissionError: '/tmp/cluster_init.log'` | 旧 log 文件归属其他用户 | `log_path` 已改 `~/cluster_init.log`；可顺手 `sudo rm /tmp/cluster_init.log` |

---

## 十、清理与降级

⚠️ `clean_test_cluster.yml` **是 destructive** 的，会：

1. `pg_ctl stop` 所有 PG。
2. `rm -rf /mnt/storage00/{pg,postgresql,arcwal,backup,remote}` 与 `/pg`。
3. 杀 pgbouncer 进程并清空 `/etc/pgbouncer/`。
4. `apt-get purge` 所有 `postgresql*` / `pgbouncer` / `pgpool2` / `postgis` 包，跑 `apt-get autoremove`。

只用于一次性测试机器。生产或保留数据的环境不要用。

---

## 十一、提交 / PR 规范

- Git 历史使用**短的中文 subject**，结尾用全角句号（`。`）。例：
  - `把 PG 数据目录迁移到 /mnt/storage00/pg/data 并保留 /pg 兼容符号链接。`
  - `inventory 无 offline/slave 组时用 groups.get 兜底避免键缺失报错。`
- 每个 commit 聚焦一件事（一个 bug 修复 / 一个特性），方便 cherry-pick 与回滚。
- PR 描述里说明：影响哪些 inventory 组、跑过哪些验证（`./preflight.sh` 输出 / 真跑 PLAY RECAP）、有没有需要人工干预的回滚步骤。

---

## 十二、本地 / 控制机依赖

- `ansible-playbook` ≥ 2.9
- `python3` ≥ 3.6
- `ssh` 与对目标机的免密能力
- `git`
- 推荐：在控制机上 `pip install ansible-lint yamllint` 做改动后的额外校验（仓库里没强制配置，按需）。

---

## 十三、相关文档

- `CLAUDE.md` — 给 AI 协作者（包括 Claude Code）使用的项目结构与约定速查。
- `AGENTS.md` — 通用 agent 风格指引。
