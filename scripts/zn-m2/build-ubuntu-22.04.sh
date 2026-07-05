#!/bin/bash
#
# ZN-M2 OpenWrt 本地编译脚本 (Ubuntu 22.04 Jammy)
#
# 从零开始编译兆能 ZN-M2 (IPQ6000 / IPQ6018) OpenWrt 固件。
# 流程一一对应 .github/workflows/zn-m2.yml，已适配本地 Ubuntu 22.04 环境。
#
# 用法:
#   chmod +x scripts/zn-m2/build-ubuntu-22.04.sh
#   ./scripts/zn-m2/build-ubuntu-22.04.sh              # 全流程
#   ./scripts/zn-m2/build-ubuntu-22.04.sh compile      # 仅编译（前提：已下载）
#   STEP=download ./scripts/zn-m2/build-ubuntu-22.04.sh # 仅跑到某一步
#
# 注意:
#   - OpenWrt 不允许以 root 身份编译，请使用普通用户运行本脚本；
#     依赖安装阶段会自动通过 sudo 提权。
#   - CI 里通过 jlumbroso/free-disk-space 释放空间，本地一般无需此步；
#     如确有需要，可在运行前自行清理。
#

set -eo pipefail

# ============== 可配置变量（对应 workflow env） ==============
REPO_URL="${REPO_URL:-https://github.com/n3o4po11o/sdf8057-ipq6000.git}"
REPO_BRANCH="${REPO_BRANCH:-master}"
FEEDS_CONF="${FEEDS_CONF:-feeds.conf.default}"
CONFIG_FILE="${CONFIG_FILE:-config/zn-m2.config}"
DIY_P1_SH="${DIY_P1_SH:-scripts/zn-m2/diy-part1.sh}"
DIY_P2_SH="${DIY_P2_SH:-scripts/zn-m2/diy-part2.sh}"
DIY_P3_SH="${DIY_P3_SH:-scripts/zn-m2/diy-part3.sh}"

WORKDIR="${WORKDIR:-/workdir}"            # 源码编译根目录（对应 CI 的 /workdir）
TZ="${TZ:-Asia/Shanghai}"
JOBS_DOWNLOAD="${JOBS_DOWNLOAD:-8}"       # 下载线程（对应 make download -j8）
JOBS_COMPILE="${JOBS_COMPILE:-$(nproc)}"  # 编译线程（对应 make -j$(nproc)）
BUILD_LOG="${BUILD_LOG:-1}"               # 1=记录编译日志, 0=不记录

# immortalwrt 官方初始化脚本（与 workflow 保持一致）
INIT_BUILD_ENV_URL="${INIT_BUILD_ENV_URL:-https://raw.githubusercontent.com/immortalwrt/build-scripts/master/init_build_environment.sh}"

# ============== 颜色输出 ==============
RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; BLUE='\033[36m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ============== 前置检查 ==============
if [[ $EUID -eq 0 ]]; then
    error "OpenWrt 不允许以 root 编译，请用普通用户运行本脚本（依赖安装会自动 sudo）。"
    exit 1
fi

# 定位项目根目录（本脚本位于 scripts/zn-m2/ 下）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

info "项目根目录  : $PROJECT_ROOT"
info "源码编译目录: $WORKDIR"
info "源码仓库    : $REPO_URL ($REPO_BRANCH)"
info "编译线程数  : $JOBS_COMPILE  (下载线程: $JOBS_DOWNLOAD)"

# 校验关键文件存在
for f in "$FEEDS_CONF" "$CONFIG_FILE" "$DIY_P1_SH" "$DIY_P2_SH" "$DIY_P3_SH"; do
    [[ -e "$PROJECT_ROOT/$f" ]] || { error "缺少必要文件: $f"; exit 1; }
done

# 将相对路径解析为绝对路径，便于在 cd 到 openwrt 后仍可引用
FEEDS_CONF="$PROJECT_ROOT/$FEEDS_CONF"
CONFIG_FILE="$PROJECT_ROOT/$CONFIG_FILE"
DIY_P1_SH="$PROJECT_ROOT/$DIY_P1_SH"
DIY_P2_SH="$PROJECT_ROOT/$DIY_P2_SH"
DIY_P3_SH="$PROJECT_ROOT/$DIY_P3_SH"

# ============== Step 1: 初始化编译环境 ==============
# 对应 workflow 的 "Apt Update" + "Initialization environment"
init_environment() {
    info "==> Step 1: 初始化编译环境（Ubuntu 22.04 Jammy）"
    export DEBIAN_FRONTEND=noninteractive

    sudo apt-get update

    # 使用 immortalwrt 官方脚本安装编译主依赖（与 CI 完全一致）
    info "拉取并执行 immortalwrt init_build_environment.sh ..."
    curl -s "$INIT_BUILD_ENV_URL" | sudo bash

    # workflow 中额外指定的依赖
    sudo apt-get install -y rename pigz libfuse-dev upx subversion clang lua5.1 liblua5.1-0-dev

    # 清理
    sudo apt-get autoremove -y --purge
    sudo apt-get clean
    sudo rm -rf po2lmo

    # 时区 / git 身份 / 工作目录
    sudo timedatectl set-timezone "$TZ" 2>/dev/null || warn "设置时区失败（容器/WSL 环境常见），可忽略"
    git config --global user.email "$(whoami)@local"
    git config --global user.name "$(whoami)"
    git config --global init.defaultBranch master
    sudo mkdir -p "$WORKDIR"
    sudo chown "$USER:${GROUPS[0]}" "$WORKDIR"

    success "编译环境就绪"
}

# ============== Step 2: 克隆源码 ==============
# 对应 workflow 的 "Clone source code"
clone_source() {
    info "==> Step 2: 克隆 OpenWrt 源码"
    if [[ -d "$WORKDIR/openwrt/.git" ]]; then
        warn "$WORKDIR/openwrt 已存在，跳过克隆（如需重新克隆请先删除该目录）"
    else
        cd "$WORKDIR"
        df -hT "$PWD"
        git clone "$REPO_URL" -b "$REPO_BRANCH" openwrt
    fi
    # 建立软链到项目根，对应 CI 里的 ln -sf /workdir/openwrt $GITHUB_WORKSPACE/openwrt
    ln -sfn "$WORKDIR/openwrt" "$PROJECT_ROOT/openwrt"
    success "源码就绪: $WORKDIR/openwrt"
}

# ============== Step 3: 加载自定义 feeds + diy-part1 ==============
# 对应 workflow 的 "Load custom feeds"
load_feeds() {
    info "==> Step 3: 加载自定义 feeds 源 + diy-part1"
    set -x
    [[ -e "$FEEDS_CONF" ]] && cp -f "$FEEDS_CONF" "$WORKDIR/openwrt/feeds.conf.default"
    chmod +x "$DIY_P1_SH"
    cd "$WORKDIR/openwrt"
    bash "$DIY_P1_SH"
    set +x
    success "feeds 源已加载"
}

# ============== Step 4: 更新 feeds ==============
# 对应 workflow 的 "Update feeds"
update_feeds() {
    info "==> Step 4: 更新 feeds"
    cd "$WORKDIR/openwrt"
    ./scripts/feeds update -a
    success "feeds 更新完成"
}

# ============== Step 5: diy-part2（修改 feeds / 优先装 passwall） ==============
# 对应 workflow 的 "Modify feeds"
modify_feeds() {
    info "==> Step 5: diy-part2（优先安装 passwall feeds）"
    set -x
    chmod +x "$DIY_P2_SH"
    cd "$WORKDIR/openwrt"
    bash "$DIY_P2_SH"
    set +x
    success "feeds 修改完成"
}

# ============== Step 6: 安装 feeds ==============
# 对应 workflow 的 "Install feeds"
install_feeds() {
    info "==> Step 6: 安装全部 feeds"
    cd "$WORKDIR/openwrt"
    ./scripts/feeds install -a
    success "feeds 安装完成"
}

# ============== Step 7: 加载配置 + diy-part3 ==============
# 对应 workflow 的 "Load custom configuration"
load_config() {
    info "==> Step 7: 加载 zn-m2.config + files + diy-part3"
    set -x
    # 可选的自定义 files 目录（对应 CI 里的 [ -e files ] && mv files openwrt/files）
    if [[ -d "$PROJECT_ROOT/files" ]]; then
        rm -rf "$WORKDIR/openwrt/files"
        cp -r "$PROJECT_ROOT/files" "$WORKDIR/openwrt/files"
    fi
    cp -f "$CONFIG_FILE" "$WORKDIR/openwrt/.config"
    chmod +x "$DIY_P3_SH"
    cd "$WORKDIR/openwrt"
    bash "$DIY_P3_SH"
    set +x
    success "配置已加载"
}

# ============== Step 8: 下载 ==============
# 对应 workflow 的 "Download package"
download() {
    info "==> Step 8: make defconfig + 下载源码包"
    cd "$WORKDIR/openwrt"
    make defconfig
    make download -j"$JOBS_DOWNLOAD"
    # 清理过小的损坏文件（<1KB 视为下载失败，与 CI 一致）
    find dl -size -1024c -exec ls -l {} \;
    find dl -size -1024c -exec rm -f {} \;
    success "下载完成"
}

# ============== Step 9: 编译 ==============
# 对应 workflow 的 "Compile the firmware"
compile() {
    info "==> Step 9: 编译固件（$JOBS_COMPILE 线程）"
    cd "$WORKDIR/openwrt"
    echo -e "$JOBS_COMPILE thread compile"
    df -hT

    if [[ "$BUILD_LOG" == "1" ]]; then
        local logfile="$PROJECT_ROOT/build-$(date +%Y%m%d%H%M).log"
        info "编译日志将写入: $logfile"
        # 三级回退（与 CI 一致）：多线程 → 单线程 → 单线程详细输出
        ( make -j"$JOBS_COMPILE" 2>&1 || \
          make -j1 2>&1           || \
          make -j1 V=s 2>&1 ) | tee "$logfile"
        local pipe_status=${PIPESTATUS[0]}
        [[ $pipe_status -ne 0 ]] && { error "编译失败，请查看日志: $logfile"; exit 1; }
    else
        # 三级回退
        make -j"$JOBS_COMPILE" || make -j1 || make -j1 V=s
    fi
    success "编译成功"
}

# ============== Step 10: 整理产物 ==============
# 对应 workflow 的 "Check space usage" + "Organize files"
collect_artifacts() {
    info "==> Step 10: 整理固件产物"
    df -hT

    local target_dir
    target_dir="$(find "$WORKDIR/openwrt/bin/targets" -mindepth 2 -maxdepth 2 -type d | head -1)"
    if [[ -z "$target_dir" ]]; then
        error "未找到编译产物目录 bin/targets/*/*"
        return 1
    fi
    success "固件目录: $target_dir"

    echo -e "\n固件文件清单："
    ls -lh "$target_dir"/*.ubi "$target_dir"/*.bin "$target_dir"/*.manifest 2>/dev/null || true

    cat <<EOF

============================================================
 刷机说明（来自 README）
  - 控制台地址 : 192.168.1.1   默认密码: password
  - uboot 刷机 : openwrt-ipq60xx-generic-zn_m2-squashfs-nand-factory.ubi
  - 系统升级  : openwrt-ipq60xx-generic-zn_m2-squashfs-nand-sysupgrade.bin
============================================================
EOF
}

# ============== 主流程 ==============
main() {
    echo -e "\n${GREEN}========== ZN-M2 OpenWrt 本地编译 (Ubuntu 22.04 Jammy) ==========${NC}\n"

    init_environment
    clone_source
    load_feeds
    update_feeds
    modify_feeds
    install_feeds
    load_config
    download
    compile
    collect_artifacts

    echo -e "\n${GREEN}========== 全部完成 ==========${NC}"
}

# ============== 入口 ==============
# 支持两种运行方式：
#   1) 直接运行 -> 执行全流程
#   2) 指定子命令 -> 只执行对应步骤（便于断点续编）：
#      init | clone | feeds | update | modify | install | config | download | compile | artifacts
case "${1:-all}" in
    all)        main ;;
    init)       init_environment ;;
    clone)      clone_source ;;
    feeds)      load_feeds ;;
    update)     update_feeds ;;
    modify)     modify_feeds ;;
    install)    install_feeds ;;
    config)     load_config ;;
    download)   download ;;
    compile)    compile ;;
    artifacts)  collect_artifacts ;;
    *)
        error "未知子命令: $1"
        echo "可用: all | init | clone | feeds | update | modify | install | config | download | compile | artifacts"
        exit 1
        ;;
esac
