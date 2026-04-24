#!/bin/bash
# created by: zhaoyueshun@p1.com
# Feedback and improvements are welcome.
# date: 2019-10-02 18:29:39


#User initialization script
SCRIPT=$(readlink -f $0)
cd $(dirname $SCRIPT)


echo_success(){
    cat <<EOF
    {
        "result": 0,
        "info": $1,
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
    timestamp=`date "+%Y-%m-%d %H:%M:%S"`
    echo "${timestamp} $*" >&2
}



help () {
        cat << EOF
Usage: $0 [OPTIONS]
Options:
    --servername -S The name of the business assumed by the database user
EOF

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
            echo_failure "Parameter parse error. Invalid argument: $1"
            exit -1
            ;;
    esac
    shift
done

if [ -z  "${servername}" ];then
    echo_failure "parameter parse error. Please select servername"
    exit -1
fi  

function user_initialization()
{  
    vailduntil=`date -d +90day +'%Y-%m-%d %H:%M:%S'`
    passwd=`pwgen -cnCy  16 -1`
    p1=${passwd//:/?}
    p2=${p1//@/?}
    p3=${p2//!/?}
    p4=${p3//\'/?}
    p5=${p4//\"/?}
    password=${p5}
    sername=$1
    name=${sername//-/}
    echo "username:dbuser_${name}  password:${password}" > /home/postgres/.userinfo.conf
    psql -U postgres  << EOF 
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
    ALTER ROLE dbuser_dba WITH SUPERUSER INHERIT NOCREATEROLE NOCREATEDB LOGIN NOREPLICATION NOBYPASSRLS PASSWORD 'md57bb81c95d81079e81981f7c8cf84d586' VALID UNTIL       '${vailduntil}';
    CREATE ROLE dbuser_monitor;
    ALTER ROLE dbuser_monitor WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB LOGIN NOREPLICATION NOBYPASSRLS PASSWORD 'md569ef1c948b85b237f264a58d3cb0730b' VALID UNTIL '${vailduntil}';
    CREATE ROLE dbuser_stats;
    ALTER ROLE dbuser_stats WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB LOGIN NOREPLICATION NOBYPASSRLS PASSWORD 'md5425da66bfc2f7d5df6905c0492b0033c' VALID UNTIL   '${vailduntil}';
    CREATE ROLE replication;
    ALTER ROLE replication WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB LOGIN REPLICATION NOBYPASSRLS PASSWORD 'md579d14c0f4deee5ecaf50bb5f20b0aabd';
    GRANT dbrole_offline TO dbuser_stats GRANTED BY postgres;
    GRANT dbrole_readonly TO dbrole_offline GRANTED BY postgres;
    GRANT dbrole_readwrite TO dbrole_readwrite_with_delete GRANTED BY postgres;
    GRANT dbrole_sa TO dbuser_dba GRANTED BY postgres;
    GRANT pg_monitor TO dbuser_monitor GRANTED BY postgres;
    create database "putong-${sername}";
EOF

    psql -U postgres  -d "putong-${sername}" << EOF
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
    create user dbuser_${name} ENCRYPTED PASSWORD '${password}' in group dbrole_readwrite_with_delete VALID UNTIL   '${vailduntil}';
    GRANT dbrole_readwrite_with_delete TO dbuser_${name} GRANTED BY postgres;
    GRANT USAGE ON SCHEMA yay TO "dbuser_monitor";

EOF
    echo_success "{'username':dbuser_${name}, 'password':${password}}"
}


user_initialization ${servername}
