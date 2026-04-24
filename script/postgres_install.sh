#!/bin/bash
# created by: zhaoyueshun@p1.com
# Feedback and improvements are welcome.
# date: 2019-10-16 18:33:22

set -euo pipefail

SCRIPT=$(readlink -f "$0")
cd "$(dirname "$SCRIPT")"


echo_success() {
    cat <<EOF
    {
        "result": 0,
        "info": success,
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
    --version -V Specify the database version to install
    --servername -S Specify the database server name to install
EOF
}


while test $# -gt 0
do
    case "$1" in
        --servername|-S)
            servername=$2
            shift
            ;;
        --version|-V)
            version=$2
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

if [ -z "${version:-}" ]; then
    echo_failure "parameter parse error. Please select version" ""
    exit 1
fi

if [ -z "${servername:-}" ]; then
    echo_failure "parameter parse error. Please select servername" ""
    exit 1
fi


detect_os() {
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID=${ID:-}
        OS_VERSION_ID=${VERSION_ID:-}
        OS_CODENAME=${VERSION_CODENAME:-}
    else
        echo_failure "OS detect error" "/etc/os-release is missing"
        exit 1
    fi

    if [ "${OS_ID}" != "debian" ] || [ "${OS_VERSION_ID}" != "12" ]; then
        echo_failure "Unsupported operating system" "This project only supports Debian 12. Current system: ID=${OS_ID}, VERSION_ID=${OS_VERSION_ID}"
        exit 1
    fi
}


validate_pgversion() {
    local major_version
    major_version="${version%%.*}"

    case "${major_version}" in
        17|18)
            ;;
        *)
            echo_failure "Unsupported PostgreSQL version" "Only PostgreSQL 17 and 18 are supported. Current version: ${version}"
            exit 1
            ;;
    esac
}


ensure_locale() {
    if locale -a 2>/dev/null | grep -qi '^en_US\.utf8$'; then
        return
    fi

    if command -v locale-gen >/dev/null 2>&1; then
        grep -q '^en_US.UTF-8 UTF-8$' /etc/locale.gen 2>/dev/null || echo 'en_US.UTF-8 UTF-8' >> /etc/locale.gen
        sed -i "s/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/" /etc/locale.gen
        locale-gen en_US.UTF-8
        return
    fi

    if command -v localedef >/dev/null 2>&1; then
        localedef -i en_US -f UTF-8 en_US.UTF-8 || true
    fi
}


ensure_postgres_user() {
    return
}


setup_pgdg_apt_repo() {
    local codename="$1"

    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends ca-certificates curl gnupg lsb-release wget

    install -d -m 0755 /usr/share/postgresql-common/pgdg
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
        | gpg --dearmor > /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc

    cat > /etc/apt/sources.list.d/pgdg.list <<EOF
deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt ${codename}-pgdg main
EOF
}


package_exists_apt() {
    apt-cache show "$1" >/dev/null 2>&1
}


install_debian_packages() {
    local dbversion="$1"
    local major_version="${dbversion%%.*}"
    local core_packages=""
    local optional_packages=()

    if [ -z "${OS_CODENAME:-}" ]; then
        echo_failure "Debian package setup error" "VERSION_CODENAME is missing from /etc/os-release"
        exit 1
    fi

    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends postgresql-common locales

    cat > /etc/postgresql-common/createcluster.conf <<EOF
create_main_cluster = false
EOF

    setup_pgdg_apt_repo "${OS_CODENAME}"
    apt-get update

    if ! package_exists_apt "postgresql-${major_version}"; then
        echo_failure \
            "Debian package is unavailable" \
            "postgresql-${major_version} is not available for Debian ${OS_VERSION_ID}. Use PostgreSQL 17 or 18 from the configured APT repositories."
        exit 1
    fi

    core_packages="numactl pwgen lz4 unzip gcc net-tools uuid-runtime libxml2 libxslt1.1 python3 python3-dev tcl postgresql-${major_version} postgresql-client-${major_version} postgresql-contrib-${major_version} postgresql-server-dev-${major_version} pgbouncer"

    for pkg in \
        "pgpool2" \
        "postgresql-${major_version}-repack" \
        "postgresql-${major_version}-postgis-3" \
        "postgresql-${major_version}-postgis-3-scripts"
    do
        if package_exists_apt "${pkg}"; then
            optional_packages+=("${pkg}")
        fi
    done

    apt-get install -y --no-install-recommends ${core_packages} "${optional_packages[@]}"

    ensure_locale

    rm -f /usr/pgsql
    ln -sf "/usr/lib/postgresql/${major_version}" /usr/pgsql
    echo 'export PATH=/usr/pgsql/bin:$PATH' > /etc/profile.d/pgsql.sh

    if command -v pgbouncer >/dev/null 2>&1; then
        ln -sf "$(command -v pgbouncer)" /usr/bin/pgbouncer
    fi

    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop postgresql >/dev/null 2>&1 || true
        systemctl stop pgbouncer >/dev/null 2>&1 || true
    fi
}


pg_install() {
    install_debian_packages "$1"
}


dir_init() {
    local basedir='/mnt/storage00'
    local archive_dir='/mnt/storage00/arcwal'
    local backup_dir='/mnt/storage00/backup'
    local remote_dir='/mnt/storage00/remote'

    mkdir -p "${basedir}"

    if [ ! -d "${basedir}/postgresql/${servername}db_${version}/" ]; then
        mkdir -p "${basedir}/postgresql/${servername}db_${version}"/{bin,conf,data,tlog,tmp}
        mkdir -p "${archive_dir}" "${backup_dir}" "${remote_dir}"
        ln -sf "${basedir}/postgresql/${servername}db_${version}" /pg
        ln -sf "${basedir}/postgresql/${servername}db_${version}/data/log" "${basedir}/postgresql/${servername}db_${version}"
        ln -sf "${archive_dir}" "${basedir}/postgresql/${servername}db_${version}"
        ln -sf "${backup_dir}" "${basedir}/postgresql/${servername}db_${version}"
        ln -sf "${remote_dir}" "${basedir}/postgresql/${servername}db_${version}"
        chown -R postgres:postgres "${basedir}/postgresql"
        chown -R postgres:postgres "${archive_dir}" "${backup_dir}" "${remote_dir}"
    else
        echo_failure "Building a standardized directory structure fail" "Directory ${basedir}/postgresql/${servername}db_${version}/ exists. Please check manually."
        exit 1
    fi
}


ensure_kernel_args() {
    local args="numa=off transparent_hugepage=never"

    if [ -f /etc/default/grub ]; then
        for arg in ${args}; do
            if ! grep -q "${arg}" /etc/default/grub; then
                sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=\"\\(.*\\)\"/GRUB_CMDLINE_LINUX_DEFAULT=\"\\1 ${arg}\"/" /etc/default/grub
            fi
        done

        if command -v update-grub >/dev/null 2>&1; then
            update-grub
        fi
    fi
}


ensure_rc_local() {
    local rc_local=/etc/rc.local

    if [ ! -f "${rc_local}" ]; then
        cat > "${rc_local}" <<'EOF'
#!/bin/sh -e
exit 0
EOF
    fi

    if ! grep -q 'Database optimisation' "${rc_local}"; then
        sed -i "/^exit 0$/i # Database optimisation\necho 'never' > /sys/kernel/mm/transparent_hugepage/enabled\necho 'never' > /sys/kernel/mm/transparent_hugepage/defrag" "${rc_local}"
    fi

    chmod +x "${rc_local}"
    sh "${rc_local}" || true
}


optimize() {
    local cpucores
    cpucores=$(grep -c 'cpu cores' /proc/cpuinfo)

    if [ "${cpucores}" -gt 40 ]; then
        local mem
        local swap
        mem=$(free | awk '/Mem:/{print $2}')
        swap=$(free | awk '/Swap:/{print $2}')

        cat > /etc/sysctl.conf <<- EOF
        # Database kernel optimisation
        fs.aio-max-nr = 1048576
        fs.file-max = 76724600
        kernel.sem = 4096 2147483647 2147483646 512000
        kernel.shmmax = $(( mem * 1024 / 2 ))
        kernel.shmall = $(( mem / 5 ))
        kernel.shmmni = 819200
        net.core.netdev_max_backlog = 10000
        net.core.rmem_default = 262144
        net.core.rmem_max = 4194304
        net.core.wmem_default = 262144
        net.core.wmem_max = 4194304
        net.core.somaxconn = 4096
        net.ipv4.tcp_max_syn_backlog = 4096
        net.ipv4.tcp_keepalive_intvl = 20
        net.ipv4.tcp_keepalive_probes = 3
        net.ipv4.tcp_keepalive_time = 60
        net.ipv4.tcp_mem = 8388608 12582912 16777216
        net.ipv4.tcp_fin_timeout = 5
        net.ipv4.tcp_synack_retries = 2
        net.ipv4.tcp_syncookies = 1
        net.ipv4.tcp_timestamps = 1
        net.ipv4.tcp_tw_recycle = 0
        net.ipv4.tcp_tw_reuse = 1
        net.ipv4.tcp_max_tw_buckets = 262144
        net.ipv4.tcp_rmem = 8192 87380 16777216
        net.ipv4.tcp_wmem = 8192 65536 16777216
        vm.dirty_background_bytes = 409600000
        net.ipv4.ip_local_port_range = 40000 65535
        vm.dirty_expire_centisecs = 6000
        vm.dirty_ratio = 80
        vm.dirty_writeback_centisecs = 50
        vm.extra_free_kbytes = 4096000
        vm.min_free_kbytes = 2097152
        vm.mmap_min_addr = 65536
        vm.swappiness = 0
        vm.overcommit_memory = 2
        vm.overcommit_ratio = $(( (mem - swap) * 100 / mem ))
        vm.zone_reclaim_mode = 0
EOF
        sysctl -p

        ensure_kernel_args

        if [ -x /opt/MegaRAID/MegaCli/MegaCli64 ]; then
            /opt/MegaRAID/MegaCli/MegaCli64 -LDSetProp WB -LALL -aALL
            /opt/MegaRAID/MegaCli/MegaCli64 -LDSetProp ADRA -LALL -aALL
            /opt/MegaRAID/MegaCli/MegaCli64 -LDSetProp -DisDskCache -LALL -aALL
            /opt/MegaRAID/MegaCli/MegaCli64 -LDSetProp -Cached -LALL -aALL
        fi

        ensure_rc_local
    fi

    cat > /etc/security/limits.d/postgresql.conf <<- EOF
    postgres    soft    nproc       655360
    postgres    hard    nproc       655360
    postgres    hard    nofile      655360
    postgres    soft    nofile      655360
    postgres    soft    stack       unlimited
    postgres    hard    stack       unlimited
    postgres    soft    core        unlimited
    postgres    hard    core        unlimited
    postgres    soft    memlock     250000000
    postgres    hard    memlock     250000000
EOF

    cat > /etc/security/limits.d/pgbouncer.conf <<- EOF
    pgbouncer    soft    nproc       655360
    pgbouncer    hard    nofile      655360
    pgbouncer    soft    nofile      655360
    pgbouncer    soft    stack       unlimited
    pgbouncer    hard    stack       unlimited
    pgbouncer    soft    core        unlimited
    pgbouncer    hard    core        unlimited
    pgbouncer    soft    memlock     250000000
    pgbouncer    hard    memlock     250000000
EOF

    cat > /etc/security/limits.d/pgpool.conf <<- EOF
    pgpool    soft    nproc       655360
    pgpool    hard    nofile      655360
    pgpool    soft    nofile      655360
    pgpool    soft    stack       unlimited
    pgpool    hard    stack       unlimited
    pgpool    soft    core        unlimited
    pgpool    hard    core        unlimited
    pgpool    soft    memlock     250000000
    pgpool    hard    memlock     250000000
EOF
}


main() {
    detect_os
    validate_pgversion
    ensure_postgres_user
    pg_install "${version}"
    dir_init
    optimize
    echo_success
}

main
