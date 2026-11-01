#!/bin/bash
# ============================================================================
# 快速方案：直接修改现成固件的默认配置，不编译
#
# 原理：libwrt-ax5-nowifi.ubi 已经内置 OpenClash 和全部依赖，
#       唯一的问题是默认 IP 是 192.168.6.1（书房电脑够不到）。
#       把 /etc/uci-defaults 塞进 squashfs 再重新打包，10-30 分钟即可。
#
# 耗时：约 10-30 分钟（取决于网速和磁盘）
# 风险：中。重新打包的 UBI 若参数不匹配，刷了起不来。
#       但 U-Boot 在（WAN 口 + RESET 15 秒），可以重刷完整编译版。
#
# 用法：
#   bash fast-patch.sh <原始.ubi> [输出.ubi]
#
# 依赖（脚本会自动装）：
#   squashfs-tools  mtd-utils  python3-pip
# ============================================================================
set -Eeuo pipefail

SRC="${1:-libwrt-ax5-nowifi.ubi}"
OUT="${2:-libwrt-ax5-custom.ubi}"
WORK="${WORK:-$PWD/fastpatch-work}"
PRESET_URL="https://raw.githubusercontent.com/hx-design/IPQ/main/files/etc/uci-defaults/90-ax5-sidegate"

log() { printf '\n\033[1;36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf '\n\033[1;31m[FATAL]\033[0m %s\n' "$*" >&2; exit 1; }
trap 'die "aborted at line $LINENO"' ERR

[ -f "$SRC" ] || die "找不到源固件: $SRC"
echo "  源固件 : $SRC ($(du -h "$SRC" | cut -f1))"
echo "  输出   : $OUT"
echo "  工作区 : $WORK"

# ------------------------------------------------------------- 1. dependencies
log "step 1/6 安装工具"
if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -qq
    sudo apt-get install -y -qq squashfs-tools mtd-utils python3-pip zstd \
        || die "工具安装失败"
else
    die "需要 apt-get（Debian/Ubuntu）"
fi

# ubireader 用来解 UBI；如果 pip 装不上，退化到手工解析
HAVE_UBIREADER=0
if python3 -c "import ubireader" 2>/dev/null; then
    HAVE_UBIREADER=1
else
    log "安装 ubireader（解 UBI 用）"
    pip3 install --quiet ubireader 2>/dev/null && HAVE_UBIREADER=1 || true
fi
[ "$HAVE_UBIREADER" = "1" ] && echo "  ubireader: OK" || echo "  ubireader: 不可用（将尝试手工提取）"

# ------------------------------------------------------------- 2. extract ubi
log "step 2/6 从 UBI 提取 squashfs 卷"
rm -rf "$WORK"; mkdir -p "$WORK"
cd "$WORK"

if [ "$HAVE_UBIREADER" = "1" ]; then
    ubireader_extract_images -o ubifs-out "../$SRC" 2>&1 | tail -3 || true
    # 输出可能是 ubifs-rootfs.img / *.squashfs / *.img
    SQ=$(find ubifs-out -type f \( -name '*.img' -o -name '*.squashfs' \) | head -1)
    [ -n "$SQ" ] || die "ubireader 没提取出卷文件，检查 $(pwd)/ubifs-out"
    echo "  提取到: $SQ ($(du -h "$SQ" | cut -f1))"
else
    die "ubireader 不可用。此方案的备选是完整编译，见 BUILD.md 方案 B"
fi

# 确认是 squashfs
if head -c 4 "$SQ" | grep -q 'hsqs'; then
    echo "  类型: squashfs ✅"
else
    echo "  类型: 非 squashfs（可能是 ubifs），本脚本不支持，改走完整编译"
    die "unsupported volume type"
fi

# --------------------------------------------------------- 3. unpack squashfs
log "step 3/6 解开 squashfs"
rm -rf rootfs
unsquashfs -q -d rootfs "$SQ" > /dev/null || die "unsquashfs 失败"
echo "  解出 $(find rootfs -type f | wc -l) 个文件"
ls rootfs/ | head -8 | sed 's/^/    /'

# 看看原厂默认 IP，确认改的是对的地方
echo "  --- 原 /etc/config/network 里的 lan 段 ---"
awk '/config interface .lan./,/^$/' rootfs/etc/config/network 2>/dev/null | head -10 | sed 's/^/    /' || true

# ---------------------------------------------------------- 4. inject preset
log "step 4/6 注入首启预置脚本"
mkdir -p rootfs/etc/uci-defaults
if [ -f "$PRESET_URL" ] 2>/dev/null; then :; fi
# 优先用本地文件，其次下载
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/files/etc/uci-defaults/90-ax5-sidegate" ]; then
    cp "$SCRIPT_DIR/files/etc/uci-defaults/90-ax5-sidegate" rootfs/etc/uci-defaults/
    echo "  来源: 本地 buildkit"
else
    curl -fsSL -m 30 "$PRESET_URL" -o rootfs/etc/uci-defaults/90-ax5-sidegate \
        || die "下载预置脚本失败"
    echo "  来源: $PRESET_URL"
fi
chmod +x rootfs/etc/uci-defaults/90-ax5-sidegate
echo "  已放置: /etc/uci-defaults/90-ax5-sidegate ($(wc -c < rootfs/etc/uci-defaults/90-ax5-sidegate) 字节)"
head -5 rootfs/etc/uci-defaults/90-ax5-sidegate | sed 's/^/    /'

# ------------------------------------------------------- 5. repack squashfs
log "step 5/6 重新打包 squashfs"
# 沿用原镜像的参数；xz 是 OpenWrt 默认，块大小 128K 与 NAND 页匹配
mksquashfs rootfs new-squashfs.img \
    -comp xz -b 131072 -noappend -no-xattrs -all-root \
    > /dev/null 2>&1 || die "mksquashfs 失败"
NEW_SIZE=$(stat -c%s new-squashfs.img)
echo "  新 squashfs: $((NEW_SIZE/1048576)) MB"

# ---------------------------------------------------------------- 6. ubinize
log "step 6/6 重新生成 UBI 镜像"
LEB_SIZE=126976      # 128KiB PEB - 2 x 2048 vid/hdr
PEB_SIZE=131072
MIN_IO=2048
SUBPAGE=2048

cat > ubinize.cfg <<EOF
[rootfs]
mode=ubi
image=new-squashfs.img
vol_id=0
vol_type=dynamic
vol_name=rootfs
vol_flags=autoresize
EOF

ubinize -o "$OUT" -m "$MIN_IO" -p "$PEB_SIZE" -s "$SUBPAGE" ubinize.cfg \
    || die "ubinize 失败"

echo
echo "  === 产物 ==="
ls -lh "$OUT" | sed 's/^/    /'
printf "  魔数: "; head -c 4 "$OUT" | od -An -c | tr -d ' \n'; echo "  (应为 UBI#)"
echo "  原始: $(stat -c%s "../$SRC") 字节"
echo "  新  : $(stat -c%s "$OUT") 字节"

cat <<'NOTE'

  ================== 重要提醒 ==================
  1. 这个镜像只改了「首次启动时执行的预置脚本」，
     刷完后设备应该自动出现在 192.168.5.250。
  2. 但它和完整编译版相比，缺一样东西：
     diy-script.sh 里对 config_generate 的默认 IP 修改。
     本方案靠 uci-defaults 在启动时改，效果一样。
  3. 如果刷完在 192.168.5.250 打不开：
     - 先 ARP 扫描确认设备在不在：arp-scan -l 或逐个 ping
     - 再试 192.168.6.1（预置脚本可能没跑）
     - 都不行就搬回书房进 U-Boot 刷完整编译版
  ==============================================
NOTE

log "完成: $(pwd)/$OUT"
