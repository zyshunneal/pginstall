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
    local key_path="/etc/apt/keyrings/pgdg.asc"

    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y --no-install-recommends ca-certificates

    install -d -m 0755 /etc/apt/keyrings
    cat > "${key_path}" <<'PGDG_KEY_EOF'
-----BEGIN PGP PUBLIC KEY BLOCK-----

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
=DA1T
-----END PGP PUBLIC KEY BLOCK-----
PGDG_KEY_EOF
    chmod 0644 "${key_path}"

    cat > /etc/apt/sources.list.d/pgdg.list <<EOF
deb [signed-by=${key_path}] https://mirrors.aliyun.com/postgresql/repos/apt ${codename}-pgdg main
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
