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
    --version    -V  Specify the database version to install (17 or 18)
    --servername -S  Specify the database server name to install
    --step       -s  Run a single phase only. Valid values:
                       preflight    OS / 版本预检
                       apt-source   写入 PGDG 阿里云镜像 + Pigsty 中国镜像 APT 源
                       packages     apt-get install PostgreSQL / PgBouncer / pgvector / pgvectorscale
                       accounts     建立 postgres / pgbouncer / pgpool 账号与 /home/postgres
                       dirs         /mnt/storage00/pg 目录树和符号链接
                       sysctl       内核参数 / limits / grub / rc.local
                       all          顺序执行以上所有 (默认)
EOF
}


step="all"

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
        --step|-s)
            step=$2
            shift
            ;;
        --help|-h)
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

step_begin() { echo_log "[STEP][$1] start"; }
step_end()   { echo_log "[STEP][$1] done"; }


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
    if id postgres >/dev/null 2>&1; then
        install -d -o postgres -g postgres -m 0755 /home/postgres
    fi
}


ensure_service_accounts() {
    if ! getent group pgbouncer >/dev/null 2>&1; then
        addgroup --system pgbouncer
    fi
    if ! id pgbouncer >/dev/null 2>&1; then
        adduser --system --ingroup pgbouncer --no-create-home \
            --home /var/run/pgbouncer --shell /usr/sbin/nologin pgbouncer
    fi
    install -d -o pgbouncer -g pgbouncer -m 0755 /etc/pgbouncer /var/run/pgbouncer /var/log/pgbouncer

    if ! getent group pgpool >/dev/null 2>&1; then
        addgroup --system pgpool
    fi
    if ! id pgpool >/dev/null 2>&1; then
        adduser --system --ingroup pgpool --no-create-home \
            --home /var/run/pgpool --shell /usr/sbin/nologin pgpool
    fi
}


setup_pgdg_apt_repo() {
    local codename="$1"
    local key_path="/etc/apt/trusted.gpg.d/pgdg.gpg"
    local key_url="https://mirrors.aliyun.com/postgresql/repos/apt/ACCC4CF8.asc"

    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y --no-install-recommends ca-certificates gnupg wget

    rm -f "${key_path}" /etc/apt/trusted.gpg.d/pgdg.asc
    wget --quiet -O - "${key_url}" | gpg --dearmor -o "${key_path}"
    chmod 0644 "${key_path}"

    cat > /etc/apt/sources.list.d/pgdg.list <<EOF
deb https://mirrors.aliyun.com/postgresql/repos/apt ${codename}-pgdg main
EOF
}


setup_pigsty_apt_repo() {
    local codename="$1"
    local key_path="/etc/apt/keyrings/pigsty.gpg"
    local key_url="https://repo.pigsty.cc/key"

    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y --no-install-recommends ca-certificates gnupg wget

    install -d -m 0755 /etc/apt/keyrings
    rm -f "${key_path}" /etc/apt/sources.list.d/pigsty*.list
    wget --quiet -O - "${key_url}" | gpg --dearmor -o "${key_path}"
    chmod 0644 "${key_path}"

    cat > /etc/apt/sources.list.d/pigsty-cc.list <<EOF
deb [signed-by=${key_path}] https://repo.pigsty.cc/apt/infra generic main
deb [signed-by=${key_path}] https://repo.pigsty.cc/apt/pgsql/${codename} ${codename} main
EOF
}


package_exists_apt() {
    apt-cache show "$1" >/dev/null 2>&1
}


setup_apt_sources_only() {
    local dbversion="$1"
    local major_version="${dbversion%%.*}"

    if [ -z "${OS_CODENAME:-}" ]; then
        echo_failure "Debian package setup error" "VERSION_CODENAME is missing from /etc/os-release"
        exit 1
    fi

    export DEBIAN_FRONTEND=noninteractive
    rm -f /etc/apt/sources.list.d/pgdg*.list
    apt-get update
    apt-get install -y --no-install-recommends postgresql-common locales

    cat > /etc/postgresql-common/createcluster.conf <<EOF
create_main_cluster = false
EOF

    setup_pgdg_apt_repo "${OS_CODENAME}"
    setup_pigsty_apt_repo "${OS_CODENAME}"
    apt-get update

    if ! package_exists_apt "postgresql-${major_version}"; then
        echo_failure \
            "Debian package is unavailable" \
            "postgresql-${major_version} is not available for Debian ${OS_VERSION_ID}. Use PostgreSQL 17 or 18 from the configured APT repositories."
        exit 1
    fi

    for pkg in \
        "postgresql-${major_version}-pgvector" \
        "postgresql-${major_version}-pgvectorscale"
    do
        if ! package_exists_apt "${pkg}"; then
            echo_failure \
                "Required PostgreSQL extension package is unavailable" \
                "${pkg} is not available from the configured PGDG/Pigsty APT repositories."
            exit 1
        fi
    done
}


install_packages_only() {
    local dbversion="$1"
    local major_version="${dbversion%%.*}"
    local core_packages=""
    local required_extension_packages=()
    local optional_packages=()

    required_extension_packages=(
        "postgresql-${major_version}-pgvector"
        "postgresql-${major_version}-pgvectorscale"
    )

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

    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y --no-install-recommends ${core_packages} "${required_extension_packages[@]}" "${optional_packages[@]}"

    ensure_locale

    rm -f /usr/pgsql
    ln -sf "/usr/lib/postgresql/${major_version}" /usr/pgsql
    echo 'export PATH=/usr/pgsql/bin:$PATH' > /etc/profile.d/pgsql.sh

    if command -v pgbouncer >/dev/null 2>&1; then
        ln -sf "$(command -v pgbouncer)" /usr/bin/pgbouncer
    fi

    # Debian 包安装后默认会通过 systemd 启动 postgresql / pgbouncer 的 packaging unit；
    # 我们这套部署用 pg_ctl 直接管理 cluster，不依赖 systemd unit，但也不要在它已被
    # 我们幂等启动后再无差别 stop。仅当：
    #   - systemd unit 处于 active
    #   - 我们这套 cluster 不在跑（即没有 /mnt/storage00/pg/data 的 postmaster.pid）
    # 才 stop，避免重跑误中已运行的 cluster。
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet postgresql 2>/dev/null \
            && [ ! -f /mnt/storage00/pg/data/postmaster.pid ]; then
            systemctl stop postgresql || true
        fi
        if systemctl is-active --quiet pgbouncer 2>/dev/null \
            && [ ! -f /var/run/pgbouncer/pgbouncer.pid ]; then
            systemctl stop pgbouncer || true
        fi
    fi
}


# 兼容入口：等价于 setup_apt_sources_only + install_packages_only。
# 如有旧脚本/手动调试 source 本文件后调用 pg_install / install_debian_packages 仍能用。
install_debian_packages() {
    setup_apt_sources_only "$1"
    install_packages_only "$1"
}


pg_install() {
    install_debian_packages "$1"
}


dir_init() {
    local basedir='/mnt/storage00'
    local archive_dir='/mnt/storage00/arcwal'
    local backup_dir='/mnt/storage00/backup'
    local remote_dir='/mnt/storage00/remote'
    local cluster_dir="${basedir}/pg"

    mkdir -p "${basedir}"

    if [ -f "${cluster_dir}/data/PG_VERSION" ]; then
        echo_log "PostgreSQL cluster already initialized at ${cluster_dir}/data, keep existing layout."
    else
        if [ -d "${cluster_dir}" ] && [ ! -L "${cluster_dir}" ]; then
            echo_log "Stale directory ${cluster_dir} without PG_VERSION detected, cleaning up."
            rm -rf "${cluster_dir}"
        fi
        mkdir -p "${cluster_dir}"/{bin,conf,data,tlog,tmp}
    fi

    mkdir -p "${archive_dir}" "${backup_dir}" "${remote_dir}"
    # /pg 兼容符号链接，指向真实数据目录根
    if [ -L /pg ] || [ ! -e /pg ]; then
        ln -sfn "${cluster_dir}" /pg
    fi
    ln -sfn "${cluster_dir}/data/log" "${cluster_dir}/log"
    ln -sfn "${archive_dir}" "${cluster_dir}/arcwal"
    ln -sfn "${backup_dir}" "${cluster_dir}/backup"
    ln -sfn "${remote_dir}" "${cluster_dir}/remote"
    chown -R postgres:postgres "${cluster_dir}"
    chown -R postgres:postgres "${archive_dir}" "${backup_dir}" "${remote_dir}"
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


ensure_pg_tuning_service() {
    # 把 THP/defrag 的运行时兜底从 /etc/rc.local 迁移到一个 systemd oneshot unit。
    # 原因：Debian 12 默认不会在 boot 时自动跑 /etc/rc.local（rc-local generator 仅
    # 在文件存在 + 可执行 + 头部 #!/bin/sh -e 时才 enable，并且这个机制在未来发行版
    # 不被保证）。改成显式 systemd unit 之后，重启后 sysfs 的兜底一定会被执行。
    local unit=/etc/systemd/system/pg-tuning.service
    local desired
    desired="$(cat <<'EOF'
[Unit]
Description=PostgreSQL host runtime tuning (THP knobs)
After=local-fs.target
DefaultDependencies=no

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c "echo never > /sys/kernel/mm/transparent_hugepage/enabled || true"
ExecStart=/bin/sh -c "echo never > /sys/kernel/mm/transparent_hugepage/defrag || true"

[Install]
WantedBy=multi-user.target
EOF
)"

    local need_reload=0
    if [ ! -f "${unit}" ] || ! printf '%s\n' "${desired}" | cmp -s - "${unit}"; then
        printf '%s\n' "${desired}" > "${unit}"
        chmod 0644 "${unit}"
        need_reload=1
    fi

    if command -v systemctl >/dev/null 2>&1; then
        if [ "${need_reload}" = "1" ]; then
            systemctl daemon-reload
        fi
        systemctl enable pg-tuning.service >/dev/null 2>&1 || true
        # restart 一次，确保本次安装也立刻把 sysfs 设置好（oneshot + RemainAfterExit
        # 模式下 restart 等价于重新执行 ExecStart 链）。
        systemctl restart pg-tuning.service || true
    fi
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
        net.ipv4.tcp_tw_reuse = 1
        net.ipv4.tcp_max_tw_buckets = 262144
        net.ipv4.tcp_rmem = 8192 87380 16777216
        net.ipv4.tcp_wmem = 8192 65536 16777216
        # 脏页阈值改用绝对字节数（dirty_ratio 配合大内存机会让脏页堆到内存的 80%
        # 触发 IO stall）。同时设置 dirty_bytes 会让 dirty_ratio 自动失效。
        vm.dirty_background_bytes = 1073741824
        vm.dirty_bytes = 4294967296
        net.ipv4.ip_local_port_range = 40000 65535
        vm.dirty_expire_centisecs = 6000
        vm.dirty_writeback_centisecs = 50
        vm.min_free_kbytes = 2097152
        vm.mmap_min_addr = 65536
        vm.swappiness = 0
        vm.overcommit_memory = 2
        vm.overcommit_ratio = $(( (mem - swap) * 100 / mem ))
        vm.zone_reclaim_mode = 0
EOF
        sysctl -p || echo_log "sysctl -p reported unknown keys, continuing."

        ensure_kernel_args

        if [ -x /opt/MegaRAID/MegaCli/MegaCli64 ]; then
            /opt/MegaRAID/MegaCli/MegaCli64 -LDSetProp WB -LALL -aALL
            /opt/MegaRAID/MegaCli/MegaCli64 -LDSetProp ADRA -LALL -aALL
            /opt/MegaRAID/MegaCli/MegaCli64 -LDSetProp -DisDskCache -LALL -aALL
            /opt/MegaRAID/MegaCli/MegaCli64 -LDSetProp -Cached -LALL -aALL
        fi

        ensure_pg_tuning_service
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
    postgres    soft    memlock     unlimited
    postgres    hard    memlock     unlimited
EOF

    cat > /etc/security/limits.d/pgbouncer.conf <<- EOF
    pgbouncer    soft    nproc       655360
    pgbouncer    hard    nofile      655360
    pgbouncer    soft    nofile      655360
    pgbouncer    soft    stack       unlimited
    pgbouncer    hard    stack       unlimited
    pgbouncer    soft    core        unlimited
    pgbouncer    hard    core        unlimited
    pgbouncer    soft    memlock     unlimited
    pgbouncer    hard    memlock     unlimited
EOF

    cat > /etc/security/limits.d/pgpool.conf <<- EOF
    pgpool    soft    nproc       655360
    pgpool    hard    nofile      655360
    pgpool    soft    nofile      655360
    pgpool    soft    stack       unlimited
    pgpool    hard    stack       unlimited
    pgpool    soft    core        unlimited
    pgpool    hard    core        unlimited
    pgpool    soft    memlock     unlimited
    pgpool    hard    memlock     unlimited
EOF
}


main() {
    # detect_os 写入 OS_CODENAME / OS_VERSION_ID，validate_pgversion 校验 PG 版本；
    # 这两个动作轻量幂等，所有 step 都需要它们的副作用，所以无条件先跑。
    detect_os
    validate_pgversion

    case "${step}" in
        preflight)
            step_begin preflight
            step_end preflight
            echo_success
            ;;
        apt-source)
            step_begin apt-source
            setup_apt_sources_only "${version}"
            step_end apt-source
            echo_success
            ;;
        packages)
            step_begin packages
            install_packages_only "${version}"
            step_end packages
            echo_success
            ;;
        accounts)
            step_begin accounts
            ensure_postgres_user
            ensure_service_accounts
            step_end accounts
            echo_success
            ;;
        dirs)
            step_begin dirs
            dir_init
            step_end dirs
            echo_success
            ;;
        sysctl)
            step_begin sysctl
            optimize
            step_end sysctl
            echo_success
            ;;
        all)
            step_begin preflight ;                                          step_end preflight
            step_begin apt-source ; setup_apt_sources_only "${version}" ;   step_end apt-source
            step_begin packages   ; install_packages_only  "${version}" ;   step_end packages
            step_begin accounts   ; ensure_postgres_user ; ensure_service_accounts ; step_end accounts
            step_begin dirs       ; dir_init ;                              step_end dirs
            step_begin sysctl     ; optimize ;                              step_end sysctl
            echo_success
            ;;
        *)
            echo_failure "unknown step: ${step}" "valid steps: preflight|apt-source|packages|accounts|dirs|sysctl|all"
            exit 1
            ;;
    esac
}

main
