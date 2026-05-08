#!/usr/bin/env bash
# preflight.sh — 部署前/重跑前的统一验证入口，封装常用 ansible 检查并给出明确中文反馈。
#
# 用法:
#   ./preflight.sh [syntax|state|dryrun|all]
#     syntax  仅做 YAML / Jinja 语法静态校验（cluster_init.yml --syntax-check）
#     state   只跑 gather_state.yml -v，把目标机现场状态打出来（不改任何东西）
#     dryrun  cluster_init.yml --check --diff 整条 pipeline 干跑，预览将要发生的变更
#     all     顺序执行上述三步（默认）
#
# 环境变量:
#   PGVERSION   缺省 17
#   SERVERNAME  缺省 agent
#   INVENTORY   缺省 ~/test.host

set -uo pipefail

cd "$(dirname "$(readlink -f "$0")")"

PGVERSION=${PGVERSION:-17}
SERVERNAME=${SERVERNAME:-agent}
INVENTORY=${INVENTORY:-$HOME/test.host}

COMMON_ARGS=( -e "pgversion=${PGVERSION} servername=${SERVERNAME}" -i "${INVENTORY}" )

# ---------- 输出辅助 ----------
hr()   { printf '%s\n' "------------------------------------------------------------"; }
title(){ echo; hr; printf '  %s\n' "$1"; hr; }
ok()   { printf '✓ %s\n' "$1"; }
fail() { printf '✗ %s\n' "$1" >&2; }
info() { printf '· %s\n' "$1"; }

abort_if_unreachable_inventory() {
    if [ ! -f "${INVENTORY}" ]; then
        fail "inventory 文件不存在：${INVENTORY}"
        info "可通过环境变量覆盖：INVENTORY=/path/to/hosts ./preflight.sh ..."
        exit 2
    fi
}

# ---------- 步骤 1：语法 ----------
run_syntax() {
    title "步骤 1 / 静态语法校验  (cluster_init.yml --syntax-check)"
    info "PG 版本=${PGVERSION}, servername=${SERVERNAME}, inventory=${INVENTORY}"
    local out
    out=$(ansible-playbook cluster_init.yml --syntax-check "${COMMON_ARGS[@]}" 2>&1)
    local rc=$?
    echo "${out}"
    if [ ${rc} -eq 0 ]; then
        ok "语法检查通过：cluster_init.yml 及其 9 个 import 的子 playbook 全部解析无误。"
        return 0
    else
        fail "语法检查未通过，请按上方报错定位文件 / 行号。"
        return 1
    fi
}

# ---------- 步骤 2：现场探测 ----------
run_state() {
    title "步骤 2 / 现场状态探测  (gather_state.yml -v)"
    abort_if_unreachable_inventory
    info "只读探测：每台机器只跑 stat/grep/pg_ctl status/SELECT 1，不写入、不重启。"
    if ansible-playbook gather_state.yml "${COMMON_ARGS[@]}" -v; then
        ok "现场探测完成。cluster_state 已通过 debug 模块在上方输出。"
        info "重点关注 cluster_state.pg.{initialized,running,role_actual}、business.{db_present,role_present,userinfo_present} 与 monitor.{role_present,pg_monitor_granted}。"
        return 0
    else
        fail "探测过程中有 host 不可达或权限失败，先排查 inventory 与 SSH 连通性。"
        return 1
    fi
}

# ---------- 步骤 3：干跑 ----------
run_dryrun() {
    title "步骤 3 / 全 pipeline 干跑  (cluster_init.yml --check --diff)"
    abort_if_unreachable_inventory
    info "Ansible check_mode：仅预测改动，不执行写入与服务动作。"
    info "重点观察 PLAY RECAP 行 changed 数 —— 稳态重跑应为 0。"
    if ansible-playbook cluster_init.yml --check --diff "${COMMON_ARGS[@]}"; then
        ok "干跑完成。如 changed=0 即代表本次重跑不会触动已运行的 PG / pgbouncer。"
        return 0
    else
        fail "干跑过程出错或部分 task 在 check_mode 下不可评估。请阅读上方失败行的 msg 字段。"
        return 1
    fi
}

# ---------- 主入口 ----------
ACTION=${1:-all}

case "${ACTION}" in
    syntax)
        run_syntax
        ;;
    state)
        run_state
        ;;
    dryrun)
        run_dryrun
        ;;
    all)
        run_syntax || exit 1
        run_state  || exit 1
        run_dryrun || exit 1
        title "全部检查完成"
        ok "syntax / state / dryrun 三步均通过。可以放心执行真跑：ansible-playbook cluster_init.yml -e \"pgversion=${PGVERSION} servername=${SERVERNAME}\" -i ${INVENTORY}"
        ;;
    -h|--help|help)
        sed -n '1,30p' "$0"
        ;;
    *)
        fail "未知动作: ${ACTION}"
        info "用法: $0 [syntax|state|dryrun|all]"
        exit 2
        ;;
esac
