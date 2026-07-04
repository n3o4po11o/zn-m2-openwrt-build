#!/bin/bash
#
# ZN-M2 OpenWrt 本地编译脚本 (Ubuntu 24.04 Noble)
#
# 从零开始编译兆能 ZN-M2 (IPQ6018/IPQ6000) OpenWrt 固件。
# 流程对应 .github/workflows/zn-m2.yml，已适配本地 Ubuntu 24.04 环境。
#
# 用法:
#   chmod +x scripts/zn-m2/build-ubuntu-24.04.sh
#   ./scripts/zn-m2/build-ubuntu-24.04.sh
#
# 注意: OpenWrt 不允许以 root 身份编译，请使用普通用户运行；
#       依赖安装阶段会通过 sudo 提权。
#

set -eo pipefail

# ============== 可配置变量（对应 workflow env） ==============
REPO_URL="https://github.com/n3o4po11o/sdf8057-ipq6000.git"
REPO_BRANCH="master"
WORKDIR="${WORKDIR:-/workdir}"          # 源码编译根目录
BUILD_LOG="${BUILD_LOG:-1}"             # 1=记录编译日志, 0=不记录
TZ="${TZ:-Asia/Shanghai}"
JOBS_DOWNLOAD="${JOBS_DOWNLOAD:-8}"     # 下载线程
# 编译线程默认取 CPU 核数
JOBS_COMPILE="${JOBS_COMPILE:-$(nproc)}"

# ============== 颜色输出 ==============
RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; BLUE='\033[36m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
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

info "项目根目录: $PROJECT_ROOT"
info "源码编译目录: $WORKDIR"
info "编译线程数: $JOBS_COMPILE"

# 校验关键文件存在
for f in feeds.conf.default config/zn-m2.config scripts/zn-m2/diy-part1.sh \
         scripts/zn-m2/diy-part2.sh scripts/zn-m2/diy-part3.sh; do
    [[ -e "$PROJECT_ROOT/$f" ]] || { error "缺少必要文件: $f"; exit 1; }
done

FEEDS_CONF="$PROJECT_ROOT/feeds.conf.default"
CONFIG_FILE="$PROJECT_ROOT/config/zn-m2.config"
DIY_P1_SH="$PROJECT_ROOT/scripts/zn-m2/diy-part1.sh"
DIY_P2_SH="$PROJECT_ROOT/scripts/zn-m2/diy-part2.sh"
DIY_P3_SH="$PROJECT_ROOT/scripts/zn-m2/diy-part3.sh"

# ============== Step 1: 安装编译依赖 ==============
install_deps() {
    info "==> Step 1: 安装编译依赖（Ubuntu 22.04 Noble）"
    export DEBIAN_FRONTEND=noninteractive

    # 基础工具
    sudo apt-get update
    sudo apt-get install -y apt-transport-https ca-certificates curl wget git gnupg2

    # OpenWrt 编译主依赖（参考 immortalwrt build-scripts，noble 适配）
    sudo apt-get install -y \
        ack antlr3 asciidoc autoconf automake autopoint binutils bison \
        build-essential bzip2 ccache cmake cpio curl device-tree-compiler ecj fakeroot \
        fastjar flex gawk gettext genisoimage gperf haveged help2man intltool \
        irqbalance jq lib32gcc-s1 libc6-dev-i386 libelf-dev libglib2.0-dev libgmp3-dev \
        libltdl-dev libmpc-dev libmpfr-dev libncurses-dev libreadline-dev libssl-dev \
        libtool libyaml-dev libz-dev lrzsz msmtp nano ninja-build p7zip p7zip-full patch \
        pkgconf libpython3-dev python3 python3-pip python3-cryptography python3-docutils \
        python3-ply python3-pyelftools python3-requests qemu-utils quilt re2c rsync scons \
        sharutils squashfs-tools subversion swig texinfo uglifyjs unzip vim wget xmlto \
        zlib1g-dev zstd xxd

    # GCC 13 / Clang 18（noble 默认即 gcc-13/g++-13，确保 multilib）
    sudo apt-get install -y gcc-13 g++-13 gcc-13-multilib g++-13-multilib || true
    sudo apt-get install -y clang-18 libclang-18-dev lld-18 liblld-18-dev llvm-18 || true

    # Node / Go（部分 LuCI / sing-box 等需要）
    sudo apt-get install -y nodejs yarn || true
    sudo apt-get install -y golang-1.25-go || sudo apt-get install -y golang-go || true

    # workflow 额外依赖
    sudo apt-get install -y rename pigz libfuse-dev upx subversion clang lua5.1 liblua5.1-0-dev || true

    # 清理
    sudo apt-get autoremove -y --purge || true
    sudo apt-get clean

    success "依赖安装完成"
}

# ============== Step 2: 初始化工作目录 ==============
init_workdir() {
    info "==> Step 2: 初始化工作目录"
    sudo mkdir -p "$WORKDIR"
    sudo chown "$USER:${GROUPS[0]}" "$WORKDIR"
    sudo timedatectl set-timezone "$TZ" 2>/dev/null || warn "设置时区失败，可忽略"
    git config --global user.email "$(whoami)@local"
    git config --global user.name "$(whoami)"
    git config --global init.defaultBranch master
}

# ============== Step 3: 克隆源码 ==============
clone_source() {
    info "==> Step 3: 克隆 OpenWrt 源码"
    if [[ -d "$WORKDIR/openwrt/.git" ]]; then
        warn "$WORKDIR/openwrt 已存在，跳过克隆（如需重新克隆请先删除）"
    else
        cd "$WORKDIR"
        df -hT "$PWD"
        git clone "$REPO_URL" -b "$REPO_BRANCH" openwrt
    fi
    # 建立软链到项目下，方便脚本引用
    ln -sfn "$WORKDIR/openwrt" "$PROJECT_ROOT/openwrt"
    success "源码就绪: $WORKDIR/openwrt"
}

# ============== Step 4: 加载自定义 feeds（diy-part1） ==============
load_feeds() {
    info "==> Step 4: 加载自定义 feeds 源 + diy-part1"
    cp -f "$FEEDS_CONF" "$WORKDIR/openwrt/feeds.conf.default"
    chmod +x "$DIY_P1_SH"
    cd "$WORKDIR/openwrt"
    bash "$DIY_P1_SH"
    success "feeds 源已加载"
}

# ============== Step 5: 更新 / 修改 / 安装 feeds ==============
update_feeds() {
    info "==> Step 5: 更新 feeds"
    cd "$WORKDIR/openwrt"
    ./scripts/feeds update -a
    success "feeds 更新完成"
}

modify_feeds() {
    info "==> Step 6: diy-part2（优先安装 passwall feeds）"
    chmod +x "$DIY_P2_SH"
    cd "$WORKDIR/openwrt"
    bash "$DIY_P2_SH"
    success "passwall feeds 优先安装完成"
}

install_feeds() {
    info "==> Step 7: 安装全部 feeds"
    cd "$WORKDIR/openwrt"
    ./scripts/feeds install -a
    success "feeds 安装完成"
}

# ============== Step 8: 加载配置 + diy-part3 ==============
load_config() {
    info "==> Step 8: 加载 zn-m2.config + diy-part3"
    # 可选的自定义 files 目录
    if [[ -d "$PROJECT_ROOT/files" ]]; then
        rm -rf "$WORKDIR/openwrt/files"
        cp -r "$PROJECT_ROOT/files" "$WORKDIR/openwrt/files"
    fi
    cp -f "$CONFIG_FILE" "$WORKDIR/openwrt/.config"
    chmod +x "$DIY_P3_SH"
    cd "$WORKDIR/openwrt"
    bash "$DIY_P3_SH"
    success "配置已加载"
}

# ============== Step 9: 下载 ==============
download() {
    info "==> Step 9: make defconfig + 下载源码包"
    cd "$WORKDIR/openwrt"
    make defconfig
    make download -j"$JOBS_DOWNLOAD"
    # 清理过小的损坏文件（<1KB 视为下载失败）
    find dl -size -1024c -exec ls -l {} \;
    find dl -size -1024c -exec rm -f {} \;
    success "下载完成"
}

# ============== Step 10: 编译 ==============
compile() {
    info "==> Step 10: 编译固件（$JOBS_COMPILE 线程）"
    cd "$WORKDIR/openwrt"
    df -hT

    if [[ "$BUILD_LOG" == "1" ]]; then
        local logfile="$PROJECT_ROOT/build-$(date +%Y%m%d%H%M).log"
        info "编译日志将写入: $logfile"
        # 三级回退：多线程 → 单线程 → 单线程详细输出
        ( make -j"$JOBS_COMPILE" 2>&1 || \
          make -j1 2>&1           || \
          make -j1 V=s 2>&1 ) | tee "$logfile"
        local pipe_status=${PIPESTATUS[0]}
        [[ $pipe_status -ne 0 ]] && { error "编译失败，请查看日志: $logfile"; exit 1; }
    else
        make -j"$JOBS_COMPILE" || make -j1 || make -j1 V=s
    fi
    success "编译成功"
}

# ============== Step 11: 整理产物 ==============
collect_artifacts() {
    info "==> Step 11: 整理固件产物"
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
  - 控制台地址: 192.168.1.1   默认密码: password
  - uboot 刷机: openwrt-ipq60xx-generic-zn_m2-squashfs-nand-factory.ubi
  - 系统升级 : openwrt-ipq60xx-generic-zn_m2-squashfs-nand-sysupgrade.bin
============================================================
EOF
}

# ============== 主流程 ==============
main() {
    echo -e "\n${GREEN}========== ZN-M2 OpenWrt 本地编译 (Ubuntu 22.04) ==========${NC}\n"
    install_deps
    init_workdir
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

main "$@"
