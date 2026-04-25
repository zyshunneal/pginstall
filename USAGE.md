# PostgreSQL 集群部署使用文档

本文档面向实际执行人员，说明本仓库各个 Ansible playbook、辅助脚本和常用命令的使用方式。所有命令默认在控制机执行，目标机为 Debian 12。

## 1. 项目用途

本项目用于通过 Ansible 初始化 PostgreSQL 主从集群，并完成以下工作：

- 安装 PostgreSQL 17 或 18、PgBouncer、pgpool 相关包。
- 通过 Pigsty 中国镜像安装 `pgvector` 和 `pgvectorscale` 扩展包。
- 初始化 1 台 master、可选多台 slave、可选多台 offline。
- 建立 streaming replication。
- 初始化业务库、schema、业务用户和 `vector` / `vectorscale` 扩展。
- 渲染 PostgreSQL 与 PgBouncer 配置。
- 部署维护脚本和 cron。
- 执行部署后连通性、读写、复制检查。

主入口是 [script/cluster_init.yml](/Users/zhaoyueshun/project/pginstall/script/cluster_init.yml)，它按固定顺序导入各阶段 playbook。

## 2. 执行前要求

### 2.1 控制机要求

控制机需要安装：

- `ansible-playbook`，建议 Ansible 2.9 或以上。
- `python3`。
- 能通过 SSH 连接所有目标机。

推荐从 `script/` 目录执行命令，这样会自动读取 [script/ansible.cfg](/Users/zhaoyueshun/project/pginstall/script/ansible.cfg)：

```bash
cd script
```

如果不在 `script/` 目录执行，需要显式指定配置文件：

```bash
ANSIBLE_CONFIG=script/ansible.cfg ansible-playbook script/cluster_init.yml
```

### 2.2 目标机要求

目标机必须满足：

- 操作系统为 Debian 12。
- 当前 SSH 用户可以免密 `sudo`。
- 已挂载 `/mnt/storage00`，且容量满足数据库使用需求。
- 能访问 `https://mirrors.aliyun.com/postgresql/repos/apt`。
- 能访问 `https://repo.pigsty.cc`，用于安装 `pgvectorscale` 等额外扩展包。
- 不存在非本项目管理的数据目录对应的 PostgreSQL 进程。

安装脚本会拒绝非 Debian 12 系统，PostgreSQL 版本只允许 17 或 18。

## 3. Inventory 配置

默认 inventory 路径是 `~/test.host`，由 `script/ansible.cfg` 指定。

示例：

```ini
[master]
10.159.108.45

[slave]
10.159.108.46
10.159.110.30

[offline]
10.159.111.10
```

组含义：

| 组名 | 是否必需 | 说明 |
|---|---:|---|
| `master` | 必需 | 主库，只能有 1 台。 |
| `slave` | 可选 | 从库，从 master 做 `pg_basebackup`。 |
| `offline` | 可选 | 离线下游，从第一台 slave 做 `pg_basebackup`。 |

注意：

- `master` 必须有且只能有一台，否则前置检查会失败。
- 如果使用 `offline`，必须至少有一台 `slave`，因为 offline 会从 `groups["slave"][0]` 构建。
- [script/deploy_cron.yml](/Users/zhaoyueshun/project/pginstall/script/deploy_cron.yml) 会把备份脚本部署到 `groups["slave"][0]`，没有 `slave` 组时不要单独执行 `deploy_cron.yml`。

执行时可以用 `-i` 覆盖默认 inventory：

```bash
cd script
ansible-playbook cluster_init.yml -i /path/to/hosts -e "pgversion=17 servername=agent"
```

## 4. 核心变量

完整部署至少需要传入两个变量：

| 变量 | 示例 | 说明 |
|---|---|---|
| `pgversion` | `17` 或 `18` | PostgreSQL 大版本，只支持 17/18。 |
| `servername` | `agent` | 业务服务名，用于生成业务库和业务用户。 |

`servername` 的影响：

- 业务库名：`putong-${servername}`。
- 业务用户名：`dbuser_${servername}`，其中 `servername` 里的 `-` 会被移除。
- 示例：`servername=my-app` 时，业务库为 `putong-my-app`，业务用户为 `dbuser_myapp`。

## 5. 推荐执行流程

### 5.1 三步预检

推荐每次真跑前先执行：

```bash
cd script
./preflight.sh
```

默认会依次执行：

1. `syntax`：静态语法检查。
2. `state`：只读探测目标机状态。
3. `dryrun`：使用 `--check --diff` 预览整条部署流程。

可以单独执行某一步：

```bash
cd script
./preflight.sh syntax
./preflight.sh state
./preflight.sh dryrun
```

通过环境变量覆盖默认值：

```bash
cd script
PGVERSION=18 SERVERNAME=agent INVENTORY=/path/to/hosts ./preflight.sh
```

默认值：

| 环境变量 | 默认值 |
|---|---|
| `PGVERSION` | `17` |
| `SERVERNAME` | `agent` |
| `INVENTORY` | `$HOME/test.host` |

### 5.2 完整部署

执行完整初始化：

```bash
cd script
ansible-playbook cluster_init.yml -e "pgversion=17 servername=agent"
```

指定 inventory：

```bash
cd script
ansible-playbook cluster_init.yml -i ~/test.host -e "pgversion=17 servername=agent"
```

PostgreSQL 18 示例：

```bash
cd script
ansible-playbook cluster_init.yml -i ~/test.host -e "pgversion=18 servername=agent"
```

部署日志默认写到控制机当前用户的：

```text
~/cluster_init.log
```

## 6. 主编排命令

[script/cluster_init.yml](/Users/zhaoyueshun/project/pginstall/script/cluster_init.yml) 是完整入口，执行顺序如下：

| 顺序 | Playbook | Tag | 作用 |
|---:|---|---|---|
| 1 | `init_prepare.yml` | `prepare`、`check` | SSH 连通性、master 数量、已有 PG 进程检查。 |
| 2 | `gather_state.yml` | `gather`、`state` | 只读探测系统、目录、PG、PgBouncer、业务库状态。 |
| 3 | `init_postgresql.yml` | `install`、`postgresql` | 安装 PostgreSQL/PgBouncer，创建目录，调整系统参数。 |
| 4 | `init_master.yml` | `init`、`master` | 初始化主库、业务用户、PG 配置、PgBouncer 配置。 |
| 5 | `init_slaveandoffline.yml` | `init`、`slave` | 构建 slave 和 offline。 |
| 6 | `reset_pghba.yml` | `reset`、`pghba` | offline 存在时校准 slave 的 `pg_hba.conf`。 |
| 7 | `start_slave_and_pgbouncer.yml` | `start`、`slave` | 启动从库 PG，分发并启动 PgBouncer。 |
| 8 | `postf_check.yml` | `postf`、`check` | 部署后连通性、读写、复制检查。 |
| 9 | `deploy_cron.yml` | `deploy`、`cron` | 部署维护脚本和 cron。 |

只执行某个阶段：

```bash
cd script
ansible-playbook cluster_init.yml --tags prepare -e "pgversion=17 servername=agent"
ansible-playbook cluster_init.yml --tags install -e "pgversion=17 servername=agent"
ansible-playbook cluster_init.yml --tags master -e "pgversion=17 servername=agent"
ansible-playbook cluster_init.yml --tags slave -e "pgversion=17 servername=agent"
ansible-playbook cluster_init.yml --tags postf -e "pgversion=17 servername=agent"
ansible-playbook cluster_init.yml --tags cron -e "pgversion=17 servername=agent"
```

注意：`init` 和 `slave` 这两个 tag 会命中多个导入阶段。需要精确迭代时，优先直接执行对应 playbook。

## 7. 单阶段 Playbook 使用

### 7.1 前置检查

```bash
cd script
ansible-playbook init_prepare.yml -e "pgversion=17 servername=agent"
```

用途：

- 检查所有目标机是否可达。
- 检查是否存在非 `/mnt/storage00/pg/data` 的 PostgreSQL 进程。
- 检查 `master` 组是否有且只有一台机器。

这是会执行远端命令的检查，但不安装软件、不写数据库数据。

### 7.2 状态探测

```bash
cd script
ansible-playbook gather_state.yml -e "pgversion=17 servername=agent" -v
```

用途：

- 探测 OS、PGDG 源、系统用户。
- 探测 `/mnt/storage00/pg/data/PG_VERSION`。
- 探测 PostgreSQL 是否运行、是否为 recovery。
- 探测业务库、业务用户、`.userinfo.conf`。
- 探测 PgBouncer 进程和配置文件。

这是只读命令，适合部署前、部署后和重跑前使用。加 `-v` 可以看到 `cluster_state` 调试输出。

### 7.3 软件安装

```bash
cd script
ansible-playbook init_postgresql.yml -e "pgversion=17 servername=agent"
```

用途：

- 调用 `postgres_install.sh -V {{ pgversion }} -S {{ servername }}`。
- 配置 PGDG Aliyun 源和 Pigsty 中国扩展源。
- 安装 PostgreSQL、PgBouncer、pgpool、PostGIS、维护工具、`pgvector`、`pgvectorscale` 等软件包。
- 创建 `/mnt/storage00/pg` 目录树。
- 创建 `/pg` 到 `/mnt/storage00/pg` 的兼容符号链接。
- 创建 `/usr/pgsql` 到当前 PG 版本目录的符号链接。
- 调整 sysctl、limits 等系统参数。

适合在软件安装失败后单独重试。

### 7.4 主库初始化

```bash
cd script
ansible-playbook init_master.yml -e "pgversion=17 servername=agent"
```

用途：

- 执行 `initdb`。
- 启动 master PostgreSQL。
- 调用 `user_init.sh -S {{ servername }}` 初始化角色、业务库、schema、业务用户。
- 在业务库内创建 `vector` 和 `vectorscale` 扩展。
- 渲染 master 侧 `pg_hba.conf`、`postgresql.conf`。
- 渲染 PgBouncer 的 `pgb_hba.conf`、`pgbouncer.ini`、`userlist.txt`。
- 启动或重启 PgBouncer。
- 验证业务用户通过 PgBouncer 连接主库。

只有 `master` 组机器会执行。

### 7.5 从库和 offline 构建

```bash
cd script
ansible-playbook init_slaveandoffline.yml -e "pgversion=17 servername=agent"
```

用途：

- 将 `.pgpass` 分发到 postgres 用户目录。
- slave 从 master 执行 `pg_basebackup`。
- offline 从第一台 slave 执行 `pg_basebackup`。
- 分别下发 slave/offline 的 `pg_hba.conf`。
- 启动 slave/offline PostgreSQL。

安全边界：

- 如果目标机已有 standby，会先停机并重新 basebackup。
- 如果目标机已有非 standby 的 PostgreSQL 数据目录，会直接失败，避免误覆盖已有主库或未知实例。

### 7.6 offline 场景下校准 slave 的 pg_hba

```bash
cd script
ansible-playbook reset_pghba.yml -e "pgversion=17 servername=agent"
```

用途：

- 当存在 offline 下游时，校准 slave 的 `pg_hba.conf`。
- 允许 offline 从 slave 做复制。
- reload slave PostgreSQL。

该命令只针对 `slave` 组。

### 7.7 启动 slave/offline 与 PgBouncer

```bash
cd script
ansible-playbook start_slave_and_pgbouncer.yml -e "pgversion=17 servername=agent"
```

用途：

- 修正 slave/offline 数据目录权限。
- PostgreSQL 未运行时才启动。
- 从 master 拉取 PgBouncer 配置到控制机。
- 分发 PgBouncer 配置到 slave/offline。
- PgBouncer 未运行时才启动，配置变化时重启。

适合在从库构建完成后单独对齐服务状态。

### 7.8 部署后检查

```bash
cd script
ansible-playbook postf_check.yml -e "pgversion=17 servername=agent"
```

用途：

- 检查 PostgreSQL 进程。
- 检查 PostgreSQL readiness。
- 检查 PgBouncer 进程。
- 读取 master 上的业务用户名和密码。
- 通过 PgBouncer 验证业务用户连接。
- 插入并读取 `yay.init_result_check_table`。
- 检查主库复制连接和备库 recovery 状态。

这是部署完成后的主要验收命令。

### 7.9 部署 cron

```bash
cd script
ansible-playbook deploy_cron.yml -e "pgversion=17 servername=agent"
```

用途：

- master：部署 `/pg/bin/repack.sh`、`/pg/bin/vacuum.sh`。
- master：部署 `/etc/cron.d/vacuum_and_repack_cron`。
- 第一台 slave：部署 `/pg/bin/pg_backup.sh`。
- 第一台 slave：部署 `/etc/cron.d/postgres_backup_cron`。

注意：该 playbook 使用 `groups["slave"][0]`，因此单 master 无 slave 的 inventory 不适合直接执行。

### 7.10 测试 playbook

```bash
cd script
ansible-playbook test.yml
```

这是轻量测试入口，主要用于验证 playbook 执行链路或临时调试。它不是完整验收，正式部署后仍建议执行 `postf_check.yml`。

## 8. 辅助 Shell 脚本

### 8.1 preflight.sh

```bash
cd script
./preflight.sh [syntax|state|dryrun|all]
```

动作说明：

| 动作 | 实际命令 | 是否写目标机 |
|---|---|---:|
| `syntax` | `ansible-playbook cluster_init.yml --syntax-check` | 否 |
| `state` | `ansible-playbook gather_state.yml -v` | 否 |
| `dryrun` | `ansible-playbook cluster_init.yml --check --diff` | 预期不写 |
| `all` | 顺序执行上面三步 | 预期不写 |

### 8.2 postgres_install.sh

通常不要直接手工执行，推荐通过 `init_postgresql.yml` 调用。

手工用法：

```bash
cd script
sudo ./postgres_install.sh -V 17 -S agent
sudo ./postgres_install.sh --version 18 --servername agent
```

参数：

| 参数 | 说明 |
|---|---|
| `-V`、`--version` | PostgreSQL 版本，只支持 17/18。 |
| `-S`、`--servername` | 服务名。 |

这个脚本会安装包、写系统配置、创建目录和符号链接，属于会改目标机的操作。

### 8.3 user_init.sh

通常不要直接手工执行，推荐通过 `init_master.yml` 调用。

手工用法：

```bash
cd script
sudo ./user_init.sh -S agent
```

作用：

- 创建标准角色。
- 创建业务库 `putong-${servername}`。
- 创建 `vector` 和 `vectorscale` 扩展。
- 创建 `yay` schema 和检查表。
- 创建业务用户 `dbuser_${servername}`。
- 写入 `/home/postgres/.userinfo.conf`。

该脚本依赖本机 PostgreSQL 已经启动，并且本地 socket 允许 postgres OS 用户通过 peer 认证连接。

### 8.4 renamehost.sh

该脚本是辅助脚本，当前主编排不会自动调用。使用前应先阅读脚本内容并确认影响范围。

## 9. 清理测试环境

危险命令：

```bash
cd script
ansible-playbook clean_test_cluster.yml
```

执行前会出现交互确认：

```text
将开始清理所有数据和环境 Press return to continue. Press Ctrl+c and then a to abort
```

它会：

- 停止 PostgreSQL。
- 删除 `/mnt/storage00/pg`、`/mnt/storage00/postgresql`、`/mnt/storage00/arcwal`、`/mnt/storage00/backup`、`/mnt/storage00/remote`。
- 删除 `/pg`。
- kill PgBouncer 进程。
- 清空 `/etc/pgbouncer`。
- purge PostgreSQL、PgBouncer、pgpool、PostGIS 相关包。
- 执行 `apt-get autoremove -y`。

只允许在一次性测试环境执行，不要在生产或需要保留数据的机器执行。

## 10. 常用执行场景

### 10.1 第一次完整部署

```bash
cd script
./preflight.sh
ansible-playbook cluster_init.yml -i ~/test.host -e "pgversion=17 servername=agent"
ansible-playbook postf_check.yml -i ~/test.host -e "pgversion=17 servername=agent"
```

### 10.2 稳态重跑

```bash
cd script
./preflight.sh state
./preflight.sh dryrun
ansible-playbook cluster_init.yml -i ~/test.host -e "pgversion=17 servername=agent"
```

稳态重跑期望：

- `PLAY RECAP` 中 `changed=0` 或只出现预期配置变更。
- 不应出现无配置变化却重启 PostgreSQL/PgBouncer 的情况。

### 10.3 只修改 PostgreSQL 配置模板后应用

修改模板后执行：

```bash
cd script
ansible-playbook cluster_init.yml --tags master -i ~/test.host -e "pgversion=17 servername=agent"
ansible-playbook postf_check.yml -i ~/test.host -e "pgversion=17 servername=agent"
```

相关模板：

- `templates/postgresql_initialize/postgresql.conf.12.j2`
- `templates/postgresql_initialize/postgresql.conf.test.12.j2`
- `templates/postgresql_initialize/pg_hba.conf.master.j2`

### 10.4 只重新分发 PgBouncer 配置到从库

```bash
cd script
ansible-playbook start_slave_and_pgbouncer.yml -i ~/test.host -e "pgversion=17 servername=agent"
```

master 侧 PgBouncer 配置由 `init_master.yml` 渲染，从库和 offline 通过 `start_slave_and_pgbouncer.yml` 从 master 拉取后分发。

### 10.5 新增 slave 后补构建

更新 inventory 的 `[slave]` 后：

```bash
cd script
ansible-playbook init_prepare.yml -i ~/test.host -e "pgversion=17 servername=agent"
ansible-playbook init_master.yml -i ~/test.host -e "pgversion=17 servername=agent"
ansible-playbook init_slaveandoffline.yml -i ~/test.host -e "pgversion=17 servername=agent"
ansible-playbook start_slave_and_pgbouncer.yml -i ~/test.host -e "pgversion=17 servername=agent"
ansible-playbook postf_check.yml -i ~/test.host -e "pgversion=17 servername=agent"
```

其中重新执行 `init_master.yml` 是为了让 master 的 `pg_hba.conf` 包含新增 slave 的 replication 规则。

### 10.6 新增 offline 后补构建

更新 inventory 的 `[offline]` 后：

```bash
cd script
ansible-playbook init_prepare.yml -i ~/test.host -e "pgversion=17 servername=agent"
ansible-playbook init_master.yml -i ~/test.host -e "pgversion=17 servername=agent"
ansible-playbook init_slaveandoffline.yml -i ~/test.host -e "pgversion=17 servername=agent"
ansible-playbook reset_pghba.yml -i ~/test.host -e "pgversion=17 servername=agent"
ansible-playbook start_slave_and_pgbouncer.yml -i ~/test.host -e "pgversion=17 servername=agent"
ansible-playbook postf_check.yml -i ~/test.host -e "pgversion=17 servername=agent"
```

## 11. 关键路径

| 路径 | 说明 |
|---|---|
| `/mnt/storage00/pg` | PostgreSQL 集群根目录。 |
| `/mnt/storage00/pg/data` | PostgreSQL 数据目录。 |
| `/mnt/storage00/arcwal` | WAL 归档目录。 |
| `/mnt/storage00/backup` | 备份目录。 |
| `/mnt/storage00/remote` | 远端落地目录。 |
| `/pg` | 指向 `/mnt/storage00/pg` 的兼容符号链接。 |
| `/usr/pgsql` | 指向 `/usr/lib/postgresql/<version>` 的兼容符号链接。 |
| `/etc/pgbouncer` | PgBouncer 配置目录。 |
| `/var/run/pgbouncer/pgbouncer.pid` | PgBouncer pid 文件。 |
| `/home/postgres/.userinfo.conf` | 业务用户名和密码文件。 |
| `~/cluster_init.log` | 控制机 Ansible 日志。 |

## 12. 验收和排查命令

查看部署日志：

```bash
tail -f ~/cluster_init.log
```

查看目标机 PostgreSQL 状态：

```bash
sudo -u postgres /usr/pgsql/bin/pg_ctl -D /mnt/storage00/pg/data status
```

查看 PostgreSQL 是否 ready：

```bash
/usr/pgsql/bin/pg_isready -h 127.0.0.1 -p 5432
```

查看 PgBouncer 进程：

```bash
test -f /var/run/pgbouncer/pgbouncer.pid && ps -fp "$(cat /var/run/pgbouncer/pgbouncer.pid)"
```

查看主库复制连接：

```bash
sudo -u postgres psql -AXtqc "select client_addr,state,sync_state from pg_stat_replication;"
```

查看当前节点是否为 standby：

```bash
sudo -u postgres psql -AXtqc "select pg_is_in_recovery();"
```

查看向量扩展是否可用：

```bash
sudo -u postgres psql -d "putong-agent" -AXtqc "select name, default_version, installed_version from pg_available_extensions where name in ('vector','vectorscale') order by name;"
```

查看业务库是否已安装向量扩展：

```bash
sudo -u postgres psql -d "putong-agent" -AXtqc "select extname, extversion from pg_extension where extname in ('vector','vectorscale') order by extname;"
```

通过 PgBouncer 连接业务库：

```bash
source /home/postgres/.userinfo.conf
PGPASSWORD="${password}" psql -h 127.0.0.1 -p 6432 -U "${username}" -d "putong-agent" -AXtqc "select 1;"
```

如果 `source /home/postgres/.userinfo.conf` 后变量名不符合预期，直接查看文件内容：

```bash
cat /home/postgres/.userinfo.conf
```

## 13. 常见问题

| 现象 | 可能原因 | 处理方式 |
|---|---|---|
| `master` 数量检查失败 | inventory 中 master 为空或超过 1 台 | 修改 inventory，保证 `[master]` 只有一台。 |
| 目标机不可达 | SSH、sudo、inventory 地址问题 | 先用 `ansible all -m ping -i ~/test.host` 或 `./preflight.sh state` 排查。 |
| 系统版本不支持 | 目标机不是 Debian 12 | 更换目标机或调整安装脚本支持范围。 |
| PostgreSQL 版本不支持 | `pgversion` 不是 17/18 | 使用 `pgversion=17` 或 `pgversion=18`。 |
| PGDG 源访问失败 | 目标机无法访问 Aliyun mirror | 修复网络、DNS、代理或镜像访问策略。 |
| `Peer authentication failed for user "postgres"` | 本地不是 postgres OS 用户执行 `psql -U postgres` | 使用 `sudo -u postgres psql ...`。 |
| `pg_basebackup` 等密码 | `.pgpass` 未写到 postgres 真实 home | 重跑 `init_slaveandoffline.yml`，或检查 postgres home 下 `.pgpass` 权限是否为 `0600`。 |
| 从库已有非 standby 数据目录 | 目标机上已有未知 PG 实例 | 人工确认数据归属后再清理或更换机器。 |
| `deploy_cron.yml` 在无 slave 时失败 | playbook 访问 `groups["slave"][0]` | 增加 slave，或不要在单 master 环境单独执行该 playbook。 |

## 14. 修改代码后的最低验证

修改 playbook 或模板后，至少执行：

```bash
cd script
ansible-playbook cluster_init.yml --syntax-check -e "pgversion=17 servername=agent"
```

如果修改的是部署行为，继续执行：

```bash
cd script
./preflight.sh state
./preflight.sh dryrun
```

如果有测试环境，执行最小相关阶段或完整部署：

```bash
cd script
ansible-playbook cluster_init.yml -i ~/test.host -e "pgversion=17 servername=agent"
ansible-playbook postf_check.yml -i ~/test.host -e "pgversion=17 servername=agent"
```
