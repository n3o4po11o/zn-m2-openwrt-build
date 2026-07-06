#!/bin/bash
#
# Copyright (c) 2019-2020 P3TERX <https://p3terx.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 (After Update feeds)
#
#优先安装 passwall 源
./scripts/feeds install -a -f -p passwall_packages
./scripts/feeds install -a -f -p passwall_luci

# ---- rust host 包自举编译修复（http-auth MSRV 冲突） ----
# 现象: cargo 编译 stage1 tool cargo 时报
#   "package http-auth v0.1.10 cannot be built because it requires rustc 1.70.0
#    or newer, while the currently active rustc version is 1.67.1"
#
# 根因:
#   1) feeds/packages/lang/rust 默认生成的 config.toml 里 locked-deps=false,
#      bootstrap 源码 (src/bootstrap/builder.rs) 仅在 locked_deps=true 时才给
#      cargo 加 --locked。因此 cargo 编译时重新解析依赖, 联网把传递依赖
#      http-auth 解析到最新的 0.1.10 (rust-version=1.70), 与自举的 rustc
#      1.67.1 冲突而失败。
#      源码包自带 Cargo.lock / vendor 里 http-auth 本就是 0.1.6 (无 MSRV 约束)。
#   2) feeds 自带的 0001-Update-xz2-and-use-it-static.patch 把 Cargo.lock 里
#      cargo 降到 0.67.1, 但没同步 src/tools/cargo/Cargo.toml (仍 0.68.0),
#      导致 lockfile 与 manifest 不一致; 一旦开启 locked-deps=true, cargo 在
#      stage0 std 阶段就因 lockfile needs update 而失败。
#
# 修法 (两步, 缺一不可):
#   1) 禁用有问题的 xz2 patch (它只改 lockfile 却制造不一致, 且对 host 工具链
#      非必需 —— bootstrap 的 xz2 改走动态链接 liblzma 即可)。
#   2) 给 rust 包 Makefile 的 Host/Compile 注入 sed, 在 x.py 运行前把 config.toml
#      里 #locked-deps = false 改成 locked-deps = true, 强制 cargo 按 lockfile
#      (http-auth=0.1.6) 走, 不重新解析依赖。
# 幂等: 已处理则跳过。
RUST_PATCH="feeds/packages/lang/rust/patches/0001-Update-xz2-and-use-it-static.patch"
if [[ -f "$RUST_PATCH" ]]; then
    rm -f "$RUST_PATCH"
    echo "[diy-part2] 已禁用 rust xz2 patch (会破坏 lockfile 一致性)"
fi

RUST_MK="feeds/packages/lang/rust/Makefile"
if [[ -f "$RUST_MK" ]] && ! grep -q "zn-m2: force locked-deps" "$RUST_MK"; then
    python3 - "$RUST_MK" <<'ZN_PY'
import sys
path = sys.argv[1]
src = open(path).read()
marker = '\tsed -i "s/^#locked-deps = false/locked-deps = true/" $(HOST_BUILD_DIR)/config.toml  # zn-m2: force locked-deps\n'
target = 'define Host/Compile\n\tcd $(HOST_BUILD_DIR) && \\\n'
replacement = 'define Host/Compile\n' + marker + '\tcd $(HOST_BUILD_DIR) && \\\n'
if target in src:
    open(path, 'w').write(src.replace(target, replacement, 1))
    print("[diy-part2] 已为 rust host 包注入 locked-deps=true 修复")
else:
    print("[diy-part2] 警告: 未找到 rust Host/Compile 锚点，跳过 rust 修复", file=sys.stderr)
ZN_PY
fi
