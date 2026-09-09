#!/bin/bash

# 严格模式：出错即退，未定义变量报错，管道错误冒泡
set -euo pipefail

####################################
# 基本配置（按需改）
####################################

RUN_NAME="pp_steam_link"               # 二进制前缀 & 包名：pp_steam_link.zip

GO_VERSION="1.27.1"                    # 构建工具链版本
export GOTOOLCHAIN="go${GO_VERSION}"

# 目标平台：阿里云 ECS 默认 x86_64；倚天等 ARM 机型用 TARGET_GOARCH=arm64 覆盖
TARGET_GOARCH="${TARGET_GOARCH:-amd64}"

# 组件：cmd/<comp> 各构建一个二进制 ${RUN_NAME}_<comp>，
# 对应 systemd 单元 ${RUN_NAME}_<comp>.service。
# 数组顺序即启动顺序，停止时按逆序 —— 先停 api 不再收新请求，再停 worker。
COMPONENTS=(api worker)

# 契约库：libra 子命令拉取的模块
LIBRA_MODULE="github.com/PlayPilotAsia/libra"

# 服务器目录
SRC_ROOT="/opt/www/${RUN_NAME}"
SRC_OUTPUT="${SRC_ROOT}/output"

# 部署路径与历史版本备份目录（releases 位于 DEPLOY_PATH 内，部署与回滚都会保留它）
DEPLOY_PATH="${SRC_ROOT}.deploy"
BACKUP_ROOT="${DEPLOY_PATH}/releases"

# 应用日志目录（由 systemd 单元重定向进来）与本脚本自身的操作日志
LOG_DIR="/opt/logs/${RUN_NAME}"
LOG_PATH="${SRC_ROOT}/control.log"

# 上传包所在目录
PKG_DIR="/tmp"

# 本地源码目录 = 脚本所在目录
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

####################################
# 工具函数
####################################

log() {
  local ts msg
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  msg="${ts} ${RUN_NAME}: $*"
  echo "${msg}"
  # 操作日志只在服务器上落盘：本地开发机 /opt 通常不可写，写不进去也不该中断构建
  if mkdir -p "$(dirname "${LOG_PATH}")" 2>/dev/null; then
    echo "${msg}" >>"${LOG_PATH}" 2>/dev/null || true
  fi
}

usage() {
  cat <<EOF
Usage: $0 <command> [args]

本地（开发机）：
  libra                    拉取 ${LIBRA_MODULE}@main 并整理 go.mod
  check_code               go fmt ./... + go vet ./...
  local_build [COMP...]    交叉编译 linux/${TARGET_GOARCH} 并打出 ${RUN_NAME}.zip
                           默认构建全部组件：${COMPONENTS[*]}

服务器（${SRC_ROOT}）：
  start   [COMP...]        启动，默认全部（顺序：${COMPONENTS[*]}）
  stop    [COMP...]        停止，默认全部（逆序）
  restart [COMP...]        重启，默认全部
  status  [COMP...]        查看状态，默认全部；全部 active 才返回 0
  n                        停服 + 备份 + 解压 ${PKG_DIR}/${RUN_NAME}.zip + 部署 + 启动
  rollback VERSION         回滚到 releases/VERSION 并重启（VERSION 可用 latest）

COMP 取值：${COMPONENTS[*]}
EOF
}

# in_array <needle> [item...]
in_array() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    if [[ "${item}" == "${needle}" ]]; then
      return 0
    fi
  done
  return 1
}

# resolve_components [COMP...] —— 无参数输出全部组件，有参数则逐个校验后原样输出。
# 每行一个；组件名不含空格，调用方按词展开即可。
resolve_components() {
  if [[ $# -eq 0 ]]; then
    printf '%s\n' "${COMPONENTS[@]}"
    return 0
  fi

  local comp
  for comp in "$@"; do
    if ! in_array "${comp}" "${COMPONENTS[@]}"; then
      echo "unknown component: ${comp}" >&2
      echo "available: ${COMPONENTS[*]}" >&2
      return 1
    fi
    echo "${comp}"
  done
}

# 逆序输出传入的组件，供 stop 使用
reverse_components() {
  local -a items=("$@")
  local i
  for ((i = ${#items[@]} - 1; i >= 0; i--)); do
    echo "${items[i]}"
  done
}

unit_of() {
  echo "${RUN_NAME}_$1.service"
}

ensure_systemctl() {
  if ! command -v systemctl >/dev/null 2>&1; then
    log "ERROR: systemctl not found; start/stop/restart/status/n/rollback 只能在服务器上用"
    exit 1
  fi
}

####################################
# systemd 控制函数
####################################

start_one() {
  local unit
  unit="$(unit_of "$1")"

  log "starting ${unit}"
  systemctl start "${unit}"

  sleep 2

  if systemctl is-active --quiet "${unit}"; then
    local pid
    pid="$(systemctl show -p MainPID --value "${unit}" || echo "")"
    log "${unit} started, MainPID=${pid:-unknown}"
  else
    local state
    state="$(systemctl is-active "${unit}" || echo "unknown")"
    log "ERROR: ${unit} failed to start, state=${state}"
    systemctl status "${unit}" --no-pager || true
    exit 1
  fi
}

stop_one() {
  local unit
  unit="$(unit_of "$1")"

  if systemctl is-active --quiet "${unit}"; then
    log "stopping ${unit}"
    systemctl stop "${unit}"
    log "${unit} stopped"
  else
    local state
    state="$(systemctl is-active "${unit}" || echo "unknown")"
    log "${unit} not active (state=${state}), nothing to stop"
  fi
}

restart_one() {
  local unit
  unit="$(unit_of "$1")"

  log "restarting ${unit}"
  systemctl restart "${unit}"

  sleep 2

  if systemctl is-active --quiet "${unit}"; then
    local pid
    pid="$(systemctl show -p MainPID --value "${unit}" || echo "")"
    log "${unit} restarted, MainPID=${pid:-unknown}"
  else
    local state
    state="$(systemctl is-active "${unit}" || echo "unknown")"
    log "ERROR: ${unit} restart failed, state=${state}"
    systemctl status "${unit}" --no-pager || true
    exit 1
  fi
}

# 返回非零表示该组件不在运行
status_one() {
  local unit
  unit="$(unit_of "$1")"

  if systemctl is-active --quiet "${unit}"; then
    local pid
    pid="$(systemctl show -p MainPID --value "${unit}" || echo "")"
    log "${unit} active (running), MainPID=${pid:-unknown}"
    return 0
  fi

  local state
  state="$(systemctl is-active "${unit}" || echo "unknown")"
  log "${unit} not running, state=${state}"
  return 1
}

start() {
  ensure_systemctl
  mkdir -p "${LOG_DIR}"

  local resolved comp
  resolved="$(resolve_components "$@")"
  for comp in ${resolved}; do
    start_one "${comp}"
  done
}

stop() {
  ensure_systemctl

  local resolved comp
  resolved="$(resolve_components "$@")"
  # 停止走逆序：api 先退出，worker 手上的任务才不会白做
  for comp in $(reverse_components ${resolved}); do
    stop_one "${comp}"
  done
}

restart() {
  ensure_systemctl
  mkdir -p "${LOG_DIR}"

  local resolved comp
  resolved="$(resolve_components "$@")"
  for comp in ${resolved}; do
    restart_one "${comp}"
  done
}

status() {
  ensure_systemctl

  local resolved comp
  local failed=0
  resolved="$(resolve_components "$@")"
  for comp in ${resolved}; do
    status_one "${comp}" || failed=1
  done
  return "${failed}"
}

####################################
# 部署：n = 从 zip 部署 + 启动
####################################

deploy_new() {
  local pkg_src="${PKG_DIR}/${RUN_NAME}.zip"
  local pkg_dst="${SRC_ROOT}/${RUN_NAME}.zip"
  local version backup_dir

  # 1. 先确认包已上传：无包时不该停服，更不该产生一次空备份
  if [[ ! -f "${pkg_src}" ]]; then
    log "ERROR: package not found: ${pkg_src}"
    exit 1
  fi

  # 2. 停止全部组件
  stop

  # 3. 备份当前部署目录
  version="$(date '+%Y%m%d_%H%M%S')"
  backup_dir="${BACKUP_ROOT}/${version}"

  if [[ -d "${DEPLOY_PATH}" ]] && [[ -n "$(ls -A "${DEPLOY_PATH}" 2>/dev/null || true)" ]]; then
    log "creating backup ${backup_dir}"
    mkdir -p "${backup_dir}"

    rsync -a \
      --exclude 'releases' \
      --exclude 'logs' \
      --exclude '*.log' \
      "${DEPLOY_PATH}/" "${backup_dir}/"

    echo "${version}" >"${BACKUP_ROOT}/latest"

    log "backup created: ${version}"
  else
    log "no existing deployment to backup"
  fi

  # 4. 把上传的包移进源码目录
  mkdir -p "${SRC_ROOT}"
  mv "${pkg_src}" "${pkg_dst}"

  # 5. 清理旧 output 并解压
  rm -rf "${SRC_OUTPUT}"
  unzip -oq "${pkg_dst}" -d "${SRC_ROOT}"

  if [[ ! -d "${SRC_OUTPUT}" ]]; then
    log "ERROR: after unzip, output dir not found: ${SRC_OUTPUT}"
    exit 1
  fi

  # 6. 覆盖到部署目录
  log "syncing ${SRC_OUTPUT}/ -> ${DEPLOY_PATH}/"
  mkdir -p "${DEPLOY_PATH}"
  rsync -a "${SRC_OUTPUT}/" "${DEPLOY_PATH}/"

  # 7. 启动全部组件
  start

  log "deploy finished, version=${version}"
}

n() {
  log "==== deploy (n) started ===="
  deploy_new
  log "==== deploy (n) finished ===="
}

####################################
# 回滚：从 releases/<VERSION> 覆盖回 DEPLOY_PATH
####################################

rollback() {
  local version="${1:-}"

  if [[ -z "${version}" ]]; then
    log "rollback: VERSION is required (or 'latest')"
    exit 1
  fi

  if [[ "${version}" == "latest" ]]; then
    if [[ -f "${BACKUP_ROOT}/latest" ]]; then
      version="$(cat "${BACKUP_ROOT}/latest")"
      log "rollback: resolved 'latest' -> ${version}"
    else
      log "rollback: 'latest' file not found in ${BACKUP_ROOT}"
      exit 1
    fi
  fi

  local backup_dir="${BACKUP_ROOT}/${version}"

  if [[ ! -d "${backup_dir}" ]]; then
    log "rollback: backup dir not found: ${backup_dir}"
    if [[ -d "${BACKUP_ROOT}" ]]; then
      log "available versions under ${BACKUP_ROOT}:"
      ls -1 "${BACKUP_ROOT}" || true
    fi
    exit 1
  fi

  log "rolling back to version ${version}"

  stop

  mkdir -p "${DEPLOY_PATH}"
  # 清空当前部署内容，但保留 releases —— 备份就存在里面，连它一起删掉
  # 就再也回不去了（只能重新打包上传）
  find "${DEPLOY_PATH}" -mindepth 1 -maxdepth 1 ! -name 'releases' -exec rm -rf {} +
  rsync -a "${backup_dir}/" "${DEPLOY_PATH}/"

  start

  log "rollback finished, current version=${version}"
}

####################################
# 本地：代码检查与构建
####################################

check_code() {
  cd "${SRC_DIR}"

  go fmt ./...

  if ! go vet ./...; then
    echo "go vet failed" >&2
    return 1
  fi
  echo "go vet passed."
}

local_build() {
  cd "${SRC_DIR}"

  local resolved
  resolved="$(resolve_components "$@")"

  check_code

  rm -f "${RUN_NAME}.zip"
  rm -rf output
  mkdir -p output/bin output/conf output/scripts

  # configs/ → conf/：systemd 单元里的 CONFIG_DIR 指向部署后的 conf。
  # 真实密钥不在这里，由服务器 /opt/playpilot/env/{APP_ENV}.env 注入。
  cp -R configs/. output/conf/
  if [[ -d scripts ]]; then
    cp -R scripts/. output/scripts/
  fi

  local comp
  local -a built=()
  for comp in ${resolved}; do
    echo "== building ${RUN_NAME}_${comp} (linux/${TARGET_GOARCH}) =="
    CGO_ENABLED=0 GOOS=linux GOARCH="${TARGET_GOARCH}" \
      go build -ldflags="-s -w" -trimpath \
      -o "output/bin/${RUN_NAME}_${comp}" "./cmd/${comp}"
    built+=("${RUN_NAME}_${comp}")
  done

  zip -rq "${RUN_NAME}.zip" output

  echo "== built binaries in ${RUN_NAME}.zip =="
  for comp in "${built[@]}"; do
    echo "  - bin/${comp}"
  done
  echo
  echo "上传: scp ${RUN_NAME}.zip <server>:${PKG_DIR}/"
  echo "部署: ssh <server> '${SRC_ROOT}/control.sh n'"
}

libra() {
  cd "${SRC_DIR}"

  go get "${LIBRA_MODULE}@main"
  # 不加 -go=${GO_VERSION}：GO_VERSION 是构建用的工具链版本，
  # 而 go.mod 的 go 行是语言版本，抬高它会无谓地提高其他人的最低工具链要求。
  go mod tidy
}

####################################
# 参数分发
####################################

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

cmd="$1"
shift

case "${cmd}" in
start) start "$@" ;;
stop) stop "$@" ;;
restart) restart "$@" ;;
status) status "$@" ;;
n) n ;;
rollback) rollback "${1:-}" ;;
libra) libra ;;
check_code) check_code ;;
local_build) local_build "$@" ;;
*)
  usage
  exit 1
  ;;
esac
