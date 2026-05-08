#!/bin/bash
# created by: zhaoyueshun@p1.com
# Feedback and improvements are welcome.
# date: 2019-10-02 18:29:39

set -euo pipefail

SCRIPT=$(readlink -f "$0")
cd "$(dirname "$SCRIPT")"


echo_success() {
    cat <<EOF
    {
        "result": 0,
        "info": $1,
        "data": {}
    }
EOF
}


echo_failure() {
    local rc=-1
    cat <<EOF
    {
        "result": ${rc},
        "info": "$1",
        "data": {
                    "detail_msg":"$2"
                }
    }
EOF
}


echo_log() {
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "${timestamp} $*" >&2
}


help() {
    cat << EOF
Usage: $0 [OPTIONS]
Options:
    --servername            -S  The name of the business assumed by the database user
    --dba-password              Password for dbuser_dba
    --replication-password      Password for replication role
    --monitor-password          Password for dbuser_monitor (PG metrics exporter / DB monitoring)
EOF
}


while test $# -gt 0
do case "$1" in
        --servername|-S)
            servername=$2
            shift
            ;;
        --dba-password)
            dba_password=$2
            shift
            ;;
        --replication-password)
            replication_password=$2
            shift
            ;;
        --monitor-password)
            monitor_password=$2
            shift
            ;;
        --help)
            help
            exit 0
            ;;
        *)
            echo_failure "Parameter parse error. Invalid argument: $1" ""
            exit 1
            ;;
    esac
    shift
done

if [ -z "${servername:-}" ]; then
    echo_failure "parameter parse error. Please select servername" ""
    exit 1
fi

dba_password=${dba_password:-${DBA_PASSWORD:-}}
replication_password=${replication_password:-${REPLICATION_PASSWORD:-}}
monitor_password=${monitor_password:-${MONITOR_PASSWORD:-}}

if [ -z "${dba_password:-}" ]; then
    echo_failure "parameter parse error. Please provide --dba-password or DBA_PASSWORD" ""
    exit 1
fi

if [ -z "${replication_password:-}" ]; then
    echo_failure "parameter parse error. Please provide --replication-password or REPLICATION_PASSWORD" ""
    exit 1
fi

if [ -z "${monitor_password:-}" ]; then
    echo_failure "parameter parse error. Please provide --monitor-password or MONITOR_PASSWORD" ""
    exit 1
fi

USERINFO_FILE=/home/postgres/.userinfo.conf


run_psql() {
    if [ "$(id -un)" = "postgres" ]; then
        psql "$@"
    else
        sudo -u postgres -n psql "$@"
    fi
}


ensure_role() {
    local role="$1"
    local extra="$2"
    run_psql -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${role}') THEN
        CREATE ROLE "${role}";
    END IF;
END
\$\$;
ALTER ROLE "${role}" ${extra};
SQL
}


ensure_database() {
    local dbname="$1"
    run_psql -AXtqc \
        "SELECT 'CREATE DATABASE \"${dbname}\"' WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = '${dbname}');" \
        | run_psql -v ON_ERROR_STOP=1
}


# 确保业务库内的扩展齐备（与短路与否无关都要跑，CREATE EXTENSION IF NOT EXISTS 自身幂等）。
# 之前已经初始化但向量扩展包是后期补装的场景下，这一步把扩展也拉齐。
ensure_extensions() {
    local dbname="$1"
    run_psql -v ON_ERROR_STOP=1 -d "${dbname}" <<SQL
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS vectorscale CASCADE;
SQL
}


# 监控账号 dbuser_monitor：与业务名解耦的集群级账号，密码由控制端 secrets.env 管理。
# 必须放在 user_initialization 的短路判断之前调用，确保稳态重跑时控制端轮换的
# MONITOR_PASSWORD 也能被 ALTER ROLE 同步到 PG。pg_monitor 是 PG 内置角色，
# 覆盖 pg_read_all_settings / pg_read_all_stats / pg_stat_scan_tables，足够大多
# 数 exporter（postgres_exporter / pgwatch / Pigsty）的指标采集需求。
ensure_monitor_role() {
    local password="$1"
    ensure_role dbuser_monitor "WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB LOGIN NOREPLICATION NOBYPASSRLS PASSWORD '${password}'"
    run_psql -v ON_ERROR_STOP=1 <<SQL
GRANT pg_monitor TO dbuser_monitor GRANTED BY postgres;
SQL
}


# 在业务库上给监控账号显式 GRANT CONNECT，防止后续如果对 PUBLIC 做 REVOKE
# 时把监控账号一起锁出去。短路 / 全量两条路径都要调用一次。
grant_monitor_db_connect() {
    local dbname="$1"
    run_psql -v ON_ERROR_STOP=1 -d "${dbname}" <<SQL
GRANT CONNECT ON DATABASE "${dbname}" TO dbuser_monitor;
SQL
}


function user_initialization()
{
    local raw_password
    local password
    local server_name
    local business_user
    local dbname

    server_name=$1
    business_user="${server_name}"
    dbname="${server_name}"

    # 监控账号与业务名/库无关，先于短路判断处理，确保任何路径下都同步存在性、
    # pg_monitor 组成员资格和 secrets.env 中的密码。
    ensure_monitor_role "${monitor_password}"

    if [ -f "${USERINFO_FILE}" ] \
        && run_psql -AXtqc "SELECT 1 FROM pg_database WHERE datname = '${dbname}';" | grep -q '^1$' \
        && run_psql -AXtqc "SELECT 1 FROM pg_roles WHERE rolname = '${business_user}';" | grep -q '^1$'; then
        echo_log "user_init: ${dbname} and ${business_user} already exist, reuse ${USERINFO_FILE}."
        # 即便走短路路径也补一次扩展，覆盖"老集群、pgvector 是这一轮才装包"的场景
        ensure_extensions "${dbname}"
        # 同样补一次监控账号在业务库的 CONNECT，覆盖"监控账号是这一轮才加进来"的场景
        grant_monitor_db_connect "${dbname}"
        password=$(awk '{print $2}' "${USERINFO_FILE}" | awk -F':' '{print $2}')
        run_psql -v ON_ERROR_STOP=1 -d "${dbname}" -c "ALTER USER \"${business_user}\" WITH PASSWORD '${password}';"
        echo_success "{'username':${business_user}, 'password':${password}}"
        return 0
    fi

    raw_password=$(pwgen -cnCy 16 -1)
    password=${raw_password//:/?}
    password=${password//@/?}
    password=${password//!/?}
    password=${password//\'/?}
    password=${password//\"/?}

    # 记录业务 role 是否在我们动手前就已存在；
    # 若已存在则说明 .userinfo.conf 已丢失，本次需要 ALTER USER 把密码同步回去。
    local role_was_present=0
    if run_psql -AXtqc "SELECT 1 FROM pg_roles WHERE rolname = '${business_user}';" | grep -q '^1$'; then
        role_was_present=1
    fi

    ensure_role dbrole_offline               "WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB NOLOGIN NOREPLICATION NOBYPASSRLS"
    ensure_role dbrole_readonly              "WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB NOLOGIN NOREPLICATION NOBYPASSRLS"
    ensure_role dbrole_readwrite             "WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB NOLOGIN NOREPLICATION NOBYPASSRLS"
    ensure_role dbrole_readwrite_with_delete "WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB NOLOGIN NOREPLICATION NOBYPASSRLS"
    ensure_role dbrole_sa                    "WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB NOLOGIN NOREPLICATION NOBYPASSRLS"
    ensure_role dbuser_dba                   "WITH SUPERUSER INHERIT NOCREATEROLE NOCREATEDB LOGIN NOREPLICATION NOBYPASSRLS PASSWORD '${dba_password}'"
    ensure_role replication                  "WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB LOGIN REPLICATION NOBYPASSRLS PASSWORD '${replication_password}'"

    run_psql -v ON_ERROR_STOP=1 <<SQL
SET password_encryption = 'scram-sha-256';
GRANT dbrole_readonly TO dbrole_offline GRANTED BY postgres;
GRANT dbrole_readwrite TO dbrole_readwrite_with_delete GRANTED BY postgres;
GRANT dbrole_sa TO dbuser_dba GRANTED BY postgres;
SQL

    ensure_database "${dbname}"

    # 扩展统一通过 ensure_extensions 维护，短路与全量路径共用
    ensure_extensions "${dbname}"

    # 监控账号 CONNECT 权限同样短路 / 全量都跑，幂等
    grant_monitor_db_connect "${dbname}"

    run_psql -v ON_ERROR_STOP=1 -d "${dbname}" <<SQL
SET password_encryption = 'scram-sha-256';
CREATE SCHEMA IF NOT EXISTS yay;
CREATE TABLE IF NOT EXISTS yay.init_result_check_table
(
    id bigserial NOT NULL,
    check_result varchar(64),
    created_time timestamp without time zone NOT NULL DEFAULT timezone('UTC'::text, now()) NOT NULL,
    PRIMARY KEY (id)
);
GRANT USAGE ON SCHEMA yay TO GROUP dbrole_readonly,dbrole_readwrite;
GRANT SELECT ON ALL TABLES IN SCHEMA yay TO GROUP dbrole_readonly;
GRANT SELECT,INSERT,UPDATE ON ALL TABLES IN SCHEMA yay TO GROUP dbrole_readwrite;
GRANT DELETE ON ALL TABLES IN SCHEMA yay TO GROUP dbrole_readwrite_with_delete;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA yay TO dbrole_readonly;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA yay TO dbrole_readwrite;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA yay TO dbrole_readonly;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA yay TO dbrole_readwrite;
ALTER DEFAULT PRIVILEGES IN SCHEMA yay GRANT SELECT ON TABLES TO dbrole_readonly;
ALTER DEFAULT PRIVILEGES IN SCHEMA yay GRANT SELECT,INSERT,UPDATE ON TABLES TO dbrole_readwrite;
ALTER DEFAULT PRIVILEGES IN SCHEMA yay GRANT DELETE ON TABLES TO dbrole_readwrite_with_delete;
ALTER DEFAULT PRIVILEGES IN SCHEMA yay GRANT SELECT ON SEQUENCES TO dbrole_readonly;
ALTER DEFAULT PRIVILEGES IN SCHEMA yay GRANT ALL ON SEQUENCES TO dbrole_readwrite;
ALTER DEFAULT PRIVILEGES IN SCHEMA yay GRANT ALL ON FUNCTIONS TO dbrole_readonly;
ALTER DEFAULT PRIVILEGES IN SCHEMA yay GRANT ALL ON FUNCTIONS TO dbrole_readwrite;
GRANT CONNECT ON DATABASE "${dbname}" TO GROUP dbrole_readonly,dbrole_readwrite;
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${business_user}') THEN
        CREATE USER "${business_user}" PASSWORD '${password}' IN ROLE dbrole_readwrite_with_delete;
    END IF;
END
\$\$;
GRANT dbrole_readwrite_with_delete TO "${business_user}" GRANTED BY postgres;
SQL

    # 仅在 role 已存在（短路未命中说明 .userinfo.conf 丢失，DB 端是旧密码、文件端将是新密码）
    # 才用新密码 ALTER 一次以恢复一致。稳态重跑会走早期短路，根本不会到这里，密码不会被旋转。
    if [ "${role_was_present:-0}" = "1" ]; then
        echo_log "user_init: business role pre-existed without a matching ${USERINFO_FILE}; resetting password to re-sync."
        run_psql -v ON_ERROR_STOP=1 -d "${dbname}" -c "ALTER USER \"${business_user}\" WITH PASSWORD '${password}';"
    fi

    install -d -o postgres -g postgres -m 0755 "$(dirname "${USERINFO_FILE}")" 2>/dev/null \
        || mkdir -p "$(dirname "${USERINFO_FILE}")"
    echo "username:${business_user}  password:${password}" > "${USERINFO_FILE}"
    chown postgres:postgres "${USERINFO_FILE}" 2>/dev/null || true
    chmod 0600 "${USERINFO_FILE}" 2>/dev/null || true
    echo_success "{'username':${business_user}, 'password':${password}}"
}


user_initialization "${servername}"
