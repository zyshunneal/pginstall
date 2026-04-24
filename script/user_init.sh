#!/bin/bash
# created by: zhaoyueshun@p1.com
# Feedback and improvements are welcome.
# date: 2019-10-02 18:29:39

set -euo pipefail

SCRIPT=$(readlink -f "$0")
cd "$(dirname "$SCRIPT")"


echo_success(){
    cat <<EOF
    {
        "result": 0,
        "info": success,
        "data": {}
    }
EOF
}


echo_failure(){
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


echo_log(){
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "${timestamp} $*" >&2
}


help () {
    cat << EOF
Usage: $0 [OPTIONS]
Options:
    --servername -S The name of the business assumed by the database user
EOF
}


require_env() {
    local name="$1"
    if [ -z "${!name:-}" ]; then
        echo_failure "parameter parse error. Please set ${name}" ""
        exit 1
    fi
}


sql_escape() {
    printf "%s" "$1" | sed "s/'/''/g"
}


while test $# -gt 0
do case $1 in
        --servername|-S)
            servername=$2
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

if [ -z "${servername:-}" ];then
    echo_failure "parameter parse error. Please select servername" ""
    exit 1
fi

require_env PGINSTALL_DBA_PASSWORD
require_env PGINSTALL_MONITOR_PASSWORD
require_env PGINSTALL_STATS_PASSWORD
require_env PGINSTALL_REPLICATION_PASSWORD
require_env PGINSTALL_BUSINESS_USER_PASSWORD

function user_initialization()
{
    local vailduntil
    local sername
    local name
    local username
    local dba_password
    local monitor_password
    local stats_password
    local replication_password
    local business_password

    vailduntil=$(date -d +90day +'%Y-%m-%d %H:%M:%S')
    sername=$1
    name=${sername//-/}
    username="dbuser_${name}"

    dba_password=$(sql_escape "${PGINSTALL_DBA_PASSWORD}")
    monitor_password=$(sql_escape "${PGINSTALL_MONITOR_PASSWORD}")
    stats_password=$(sql_escape "${PGINSTALL_STATS_PASSWORD}")
    replication_password=$(sql_escape "${PGINSTALL_REPLICATION_PASSWORD}")
    business_password=$(sql_escape "${PGINSTALL_BUSINESS_USER_PASSWORD}")

    psql -v ON_ERROR_STOP=1 -U postgres << EOF
    CREATE ROLE dbrole_offline;
    ALTER ROLE dbrole_offline WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB NOLOGIN NOREPLICATION NOBYPASSRLS;
    CREATE ROLE dbrole_readonly;
    ALTER ROLE dbrole_readonly WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB NOLOGIN NOREPLICATION NOBYPASSRLS;
    CREATE ROLE dbrole_readwrite;
    ALTER ROLE dbrole_readwrite WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB NOLOGIN NOREPLICATION NOBYPASSRLS;
    CREATE ROLE dbrole_readwrite_with_delete;
    ALTER ROLE dbrole_readwrite_with_delete WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB NOLOGIN NOREPLICATION NOBYPASSRLS;
    CREATE ROLE dbrole_sa;
    ALTER ROLE dbrole_sa WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB NOLOGIN NOREPLICATION NOBYPASSRLS;
    CREATE ROLE dbuser_dba;
    ALTER ROLE dbuser_dba WITH SUPERUSER INHERIT NOCREATEROLE NOCREATEDB LOGIN NOREPLICATION NOBYPASSRLS PASSWORD '${dba_password}' VALID UNTIL '${vailduntil}';
    CREATE ROLE dbuser_monitor;
    ALTER ROLE dbuser_monitor WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB LOGIN NOREPLICATION NOBYPASSRLS PASSWORD '${monitor_password}' VALID UNTIL '${vailduntil}';
    CREATE ROLE dbuser_stats;
    ALTER ROLE dbuser_stats WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB LOGIN NOREPLICATION NOBYPASSRLS PASSWORD '${stats_password}' VALID UNTIL '${vailduntil}';
    CREATE ROLE replication;
    ALTER ROLE replication WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB LOGIN REPLICATION NOBYPASSRLS PASSWORD '${replication_password}';
    GRANT dbrole_offline TO dbuser_stats GRANTED BY postgres;
    GRANT dbrole_readonly TO dbrole_offline GRANTED BY postgres;
    GRANT dbrole_readwrite TO dbrole_readwrite_with_delete GRANTED BY postgres;
    GRANT dbrole_sa TO dbuser_dba GRANTED BY postgres;
    GRANT pg_monitor TO dbuser_monitor GRANTED BY postgres;
    create database "putong-${sername}";
EOF

    psql -v ON_ERROR_STOP=1 -U postgres -d "putong-${sername}" << EOF
    create schema yay;
    CREATE TABLE yay.init_result_check_table
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
    grant all on all functions in schema yay to dbrole_readonly;
    grant all on all functions in schema yay to dbrole_readwrite;
    ALTER DEFAULT PRIVILEGES IN SCHEMA yay GRANT SELECT ON TABLES TO dbrole_readonly;
    ALTER DEFAULT PRIVILEGES IN SCHEMA yay GRANT SELECT,INSERT,UPDATE ON TABLES TO dbrole_readwrite;
    ALTER DEFAULT PRIVILEGES IN SCHEMA yay GRANT DELETE ON TABLES TO dbrole_readwrite_with_delete;
    ALTER DEFAULT PRIVILEGES IN SCHEMA yay GRANT SELECT ON SEQUENCES TO dbrole_readonly;
    ALTER DEFAULT PRIVILEGES IN SCHEMA yay GRANT ALL ON SEQUENCES TO dbrole_readwrite;
    ALTER DEFAULT PRIVILEGES IN SCHEMA yay GRANT ALL ON functions TO dbrole_readonly;
    ALTER DEFAULT PRIVILEGES IN SCHEMA yay GRANT ALL ON functions TO dbrole_readwrite;
    GRANT CONNECT ON DATABASE "putong-${sername}" TO GROUP dbrole_readonly,dbrole_readwrite;
    create user ${username} ENCRYPTED PASSWORD '${business_password}' in group dbrole_readwrite_with_delete VALID UNTIL '${vailduntil}';
    GRANT dbrole_readwrite_with_delete TO ${username} GRANTED BY postgres;
    GRANT USAGE ON SCHEMA yay TO "dbuser_monitor";
EOF

    echo_success
}


user_initialization "${servername}"
