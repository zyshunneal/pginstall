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

USERINFO_FILE=/home/postgres/.userinfo.conf


ensure_role() {
    local role="$1"
    local extra="$2"
    psql -v ON_ERROR_STOP=1 -U postgres <<SQL
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
    psql -v ON_ERROR_STOP=1 -U postgres -AXtqc \
        "SELECT 'CREATE DATABASE \"${dbname}\"' WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = '${dbname}');" \
        | psql -v ON_ERROR_STOP=1 -U postgres
}


function user_initialization()
{
    local raw_password
    local password
    local server_name
    local business_name
    local business_user
    local dbname

    server_name=$1
    business_name=${server_name//-/}
    business_user="dbuser_${business_name}"
    dbname="putong-${server_name}"

    if [ -f "${USERINFO_FILE}" ] \
        && psql -U postgres -AXtqc "SELECT 1 FROM pg_database WHERE datname = '${dbname}';" | grep -q '^1$' \
        && psql -U postgres -AXtqc "SELECT 1 FROM pg_roles WHERE rolname = '${business_user}';" | grep -q '^1$'; then
        echo_log "user_init: ${dbname} and ${business_user} already exist, reuse ${USERINFO_FILE}."
        password=$(awk '{print $2}' "${USERINFO_FILE}" | awk -F':' '{print $2}')
        echo_success "{'username':${business_user}, 'password':${password}}"
        return 0
    fi

    raw_password=$(pwgen -cnCy 16 -1)
    password=${raw_password//:/?}
    password=${password//@/?}
    password=${password//!/?}
    password=${password//\'/?}
    password=${password//\"/?}

    ensure_role dbrole_offline               "WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB NOLOGIN NOREPLICATION NOBYPASSRLS"
    ensure_role dbrole_readonly              "WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB NOLOGIN NOREPLICATION NOBYPASSRLS"
    ensure_role dbrole_readwrite             "WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB NOLOGIN NOREPLICATION NOBYPASSRLS"
    ensure_role dbrole_readwrite_with_delete "WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB NOLOGIN NOREPLICATION NOBYPASSRLS"
    ensure_role dbrole_sa                    "WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB NOLOGIN NOREPLICATION NOBYPASSRLS"
    ensure_role dbuser_dba                   "WITH SUPERUSER INHERIT NOCREATEROLE NOCREATEDB LOGIN NOREPLICATION NOBYPASSRLS PASSWORD '${DBA_PASSWORD}'"
    ensure_role replication                  "WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB LOGIN REPLICATION NOBYPASSRLS PASSWORD '${REPLICATION_PASSWORD}'"

    psql -v ON_ERROR_STOP=1 -U postgres <<SQL
SET password_encryption = 'scram-sha-256';
GRANT dbrole_readonly TO dbrole_offline GRANTED BY postgres;
GRANT dbrole_readwrite TO dbrole_readwrite_with_delete GRANTED BY postgres;
GRANT dbrole_sa TO dbuser_dba GRANTED BY postgres;
SQL

    ensure_database "${dbname}"

    psql -v ON_ERROR_STOP=1 -U postgres -d "${dbname}" <<SQL
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

    echo "username:${business_user}  password:${password}" > "${USERINFO_FILE}"
    chown postgres:postgres "${USERINFO_FILE}" 2>/dev/null || true
    chmod 0600 "${USERINFO_FILE}" 2>/dev/null || true
    echo_success "{'username':${business_user}, 'password':${password}}"
}


user_initialization "${servername}"
