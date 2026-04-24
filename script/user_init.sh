#!/bin/bash
# created by: zhaoyueshun@p1.com
# Feedback and improvements are welcome.
# date: 2019-10-02 18:29:39

set -euo pipefail

SCRIPT=$(readlink -f "$0")
cd "$(dirname "$SCRIPT")"

DBA_PASSWORD="Aei8ohYah7Eiz4Ah"
REPLICATION_PASSWORD="Phaif5izei3Pij5"


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
    --servername -S The name of the business assumed by the database user
EOF
}


while test $# -gt 0
do case "$1" in
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

if [ -z "${servername:-}" ]; then
    echo_failure "parameter parse error. Please select servername" ""
    exit 1
fi

function user_initialization()
{
    local raw_password
    local password
    local server_name
    local business_name

    raw_password=$(pwgen -cnCy 16 -1)
    password=${raw_password//:/?}
    password=${password//@/?}
    password=${password//!/?}
    password=${password//\'/?}
    password=${password//\"/?}
    server_name=$1
    business_name=${server_name//-/}

    psql -v ON_ERROR_STOP=1 -U postgres <<EOF
    SET password_encryption = 'scram-sha-256';
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
    ALTER ROLE dbuser_dba WITH SUPERUSER INHERIT NOCREATEROLE NOCREATEDB LOGIN NOREPLICATION NOBYPASSRLS PASSWORD '${DBA_PASSWORD}';
    CREATE ROLE replication;
    ALTER ROLE replication WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB LOGIN REPLICATION NOBYPASSRLS PASSWORD '${REPLICATION_PASSWORD}';
    GRANT dbrole_readonly TO dbrole_offline GRANTED BY postgres;
    GRANT dbrole_readwrite TO dbrole_readwrite_with_delete GRANTED BY postgres;
    GRANT dbrole_sa TO dbuser_dba GRANTED BY postgres;
    CREATE DATABASE "putong-${server_name}";
EOF

    psql -v ON_ERROR_STOP=1 -U postgres -d "putong-${server_name}" <<EOF
    SET password_encryption = 'scram-sha-256';
    CREATE SCHEMA yay;
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
    GRANT ALL ON ALL FUNCTIONS IN SCHEMA yay TO dbrole_readonly;
    GRANT ALL ON ALL FUNCTIONS IN SCHEMA yay TO dbrole_readwrite;
    ALTER DEFAULT PRIVILEGES IN SCHEMA yay GRANT SELECT ON TABLES TO dbrole_readonly;
    ALTER DEFAULT PRIVILEGES IN SCHEMA yay GRANT SELECT,INSERT,UPDATE ON TABLES TO dbrole_readwrite;
    ALTER DEFAULT PRIVILEGES IN SCHEMA yay GRANT DELETE ON TABLES TO dbrole_readwrite_with_delete;
    ALTER DEFAULT PRIVILEGES IN SCHEMA yay GRANT SELECT ON SEQUENCES TO dbrole_readonly;
    ALTER DEFAULT PRIVILEGES IN SCHEMA yay GRANT ALL ON SEQUENCES TO dbrole_readwrite;
    ALTER DEFAULT PRIVILEGES IN SCHEMA yay GRANT ALL ON FUNCTIONS TO dbrole_readonly;
    ALTER DEFAULT PRIVILEGES IN SCHEMA yay GRANT ALL ON FUNCTIONS TO dbrole_readwrite;
    GRANT CONNECT ON DATABASE "putong-${server_name}" TO GROUP dbrole_readonly,dbrole_readwrite;
    CREATE USER dbuser_${business_name} PASSWORD '${password}' IN ROLE dbrole_readwrite_with_delete;
    GRANT dbrole_readwrite_with_delete TO dbuser_${business_name} GRANTED BY postgres;
EOF

    echo "username:dbuser_${business_name}  password:${password}" > /home/postgres/.userinfo.conf
    echo_success "{'username':dbuser_${business_name}, 'password':${password}}"
}


user_initialization "${servername}"
