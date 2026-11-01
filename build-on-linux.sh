#!/bin/bash
# ============================================================================
# Redmi AX5 (RA67) - OpenWrt custom firmware build script
#
# Target : qualcommax / ipq60xx / redmi_ax5  (aarch64, no wifi)
# Purpose: side-gateway image that boots at 192.168.5.250 with dhcp and
#          firewall already disabled, and OpenClash dependencies preinstalled.
#
# Requirements (check first, script aborts if not met):
#   disk  : >= 40 GB free in $WORKDIR
#   ram   : >= 6 GB  (4-6 GB works only with 2 GB swap)
#   cpu   : any x86_64; more cores = faster (8 cores ~ 2h, 4 cores ~ 4h)
#
# Usage:
#   bash build-on-linux.sh                 # default workdir ~/ax5
#   WORKDIR=/data/ax5 bash build-on-linux.sh
#   JOBS=16 bash build-on-linux.sh         # override parallel jobs
# ============================================================================
set -Eeuo pipefail

WORKDIR="${WORKDIR:-$HOME/ax5}"
JOBS="${JOBS:-$(nproc)}"
SRC_REPO="https://github.com/King-Of-Knights/openwrt-6.x.git"
SRC_BRANCH="main"
KIT_REPO="https://github.com/hx-design/IPQ.git"     # carries our custom config
KIT_BRANCH="main"
CONFIG_NAME="ipq60xx-ax5-sidegate.config"

log() { printf '\n\033[1;36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf '\n\033[1;31m[FATAL]\033[0m %s\n' "$*" >&2; exit 1; }
trap 'die "aborted at line $LINENO"' ERR

# ---------------------------------------------------------------- 0. checks
log "step 0/7 environment check"
echo "  user    : $(id -un)"
echo "  kernel  : $(uname -srm)"
echo "  cpu     : $(nproc) cores"
echo "  memory  : $(awk '/MemTotal/{printf "%.1f GB", $2/1048576}' /proc/meminfo)"
mkdir -p "$WORKDIR"
FREE_GB=$(df -BG --output=avail "$WORKDIR" | tail -1 | tr -dc '0-9')
echo "  workdir : $WORKDIR"
echo "  free    : ${FREE_GB} GB"

[ "$FREE_GB" -ge 35 ] || die "need >= 35 GB free in $WORKDIR, have ${FREE_GB} GB"
MEM_GB=$(awk '/MemTotal/{printf "%d", $2/1048576}' /proc/meminfo)
SWAP_GB=$(awk '/SwapTotal/{printf "%d", $2/1048576}' /proc/meminfo)
if [ $((MEM_GB + SWAP_GB)) -lt 6 ]; then
    die "need >= 6 GB ram+swap, have ${MEM_GB}+${SWAP_GB} GB (add swap first)"
fi
[ "$(uname -m)" = "x86_64" ] || echo "  WARN: host arch $(uname -m), cross-compile still fine"

# ---------------------------------------------------------- 1. dependencies
log "step 1/7 install build dependencies"
if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    sudo apt-get update -qq
    # core set - must succeed
    sudo apt-get install -y -qq \
        build-essential clang flex bison g++ gawk gcc-multilib g++-multilib \
        gettext git libncurses-dev libssl-dev python3-setuptools python3-distutils \
        rsync swig unzip zlib1g-dev file wget ca-certificates \
        autoconf automake autopoint binutils bzip2 ccache cpio curl \
        device-tree-compiler fastjar gperf haveged help2man intltool \
        libc6-dev-i386 libelf-dev libglib2.0-dev libgmp3-dev libltdl-dev \
        libmpc-dev libmpfr-dev libreadline-dev libtool lrzsz mkisofs msmtp \
        nano ninja-build p7zip p7zip-full patch pkgconf python3 python3-pip \
        python3-ply python3-pyelftools qemu-utils re2c rsync scons \
        squashfs-tools subversion texinfo uglifyjs upx-ucl vim xmlto xxd \
        || die "core dependency install failed"
    # optional extras - tolerated
    sudo apt-get install -y -qq asciidoc antlr3 libncursesw5-dev 2>/dev/null || true
elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y @development-tools gcc gcc-c++ clang flex bison gawk \
        gettext git ncurses-devel openssl-devel python3-setuptools rsync swig \
        unzip zlib-devel file wget autoconf automake bzip2 ccache cpio curl \
        dtc patch pkgconf python3 python3-pip qemu-img squashfs-tools subversion \
        texinfo vim xmlto xxd || die "dependency install failed"
else
    die "unsupported distro: need apt-get or dnf"
fi

# ------------------------------------------------------------------ 2. source
log "step 2/7 clone openwrt source (this is the slow part, be patient)"
mkdir -p "$WORKDIR"
cd "$WORKDIR"
if [ -d openwrt/.git ]; then
    echo "  openwrt/ already exists, skipping clone"
else
    git clone --depth 1 -b "$SRC_BRANCH" "$SRC_REPO" openwrt \
        || die "clone failed. If github is slow, set a proxy first:
     export https_proxy=http://127.0.0.1:7890 http_proxy=http://127.0.0.1:7890"
fi

log "step 3/7 clone build kit (our custom config)"
if [ -d buildkit/.git ]; then
    git -C buildkit fetch --depth 1 origin "$KIT_BRANCH" && git -C buildkit reset --hard FETCH_HEAD
else
    git clone --depth 1 -b "$KIT_BRANCH" "$KIT_REPO" buildkit || die "kit clone failed"
fi
ls -l buildkit/configs/ | sed 's/^/    /'

# --------------------------------------------------------------- 4. apply diy
log "step 4/7 run diy script (feeds + default ip + theme)"
cd "$WORKDIR/openwrt"
cp ../buildkit/diy-script.sh ./diy.sh
chmod +x diy.sh
# the upstream script assumes github actions workspace; rewrite that variable
sed -i "s|\$GITHUB_WORKSPACE|$WORKDIR/buildkit|g" diy.sh
grep -n "GITHUB_WORKSPACE\|sed -i 's/192" diy.sh | sed 's/^/    /' || true
./diy.sh 2>&1 | tail -20

# ------------------------------------------------------- 5. custom config+files
log "step 5/7 apply custom build config and first-boot preset"
cd "$WORKDIR/openwrt"
cp "../buildkit/configs/$CONFIG_NAME" .config
mkdir -p files
cp -r ../buildkit/files/. files/
echo "  preset files:"
find files -type f | sed 's/^/    /'
# sanity: preset must be executable by the init system
chmod +x files/etc/uci-defaults/90-ax5-sidegate

# make defconfig resolves the package graph; report what survives
make defconfig > /dev/null 2>&1 || die "make defconfig failed"
log "  resolved config check"
for p in luci-app-openclash bash curl coreutils-nohup dnsmasq-full kmod-tun \
         luci-i18n-base-zh-cn block-mount kmod-usb-storage; do
    if grep -q "^CONFIG_PACKAGE_${p}=y" .config; then
        echo "    OK   $p"
    else
        echo "    MISS $p   <-- BAD, abort"
        MISSING=1
    fi
done
grep -q "^CONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_redmi_ax5=y" .config \
    || die "target device redmi_ax5 not selected"
echo "    OK   target device redmi_ax5"
[ "${MISSING:-0}" = "0" ] || die "some required packages were dropped by defconfig"

# --------------------------------------------------------------- 6. download
log "step 6/7 pre-download package sources (parallel, resumable)"
make download -j"$JOBS" 2>&1 | tail -5 || echo "  WARN: some downloads failed, compile will retry"
find dl -size -1024c -delete 2>/dev/null || true

# ---------------------------------------------------------------- 7. compile
log "step 7/7 compile (this is the long part)"
START=$(date +%s)
make -j"$JOBS" 2>&1 | tee "$WORKDIR/build.log" | tail -1
make -j1 V=s 2>&1 | tail -1 || true   # retry serially to surface real errors
END=$(date +%s)
echo "  compile wall time: $(( (END-START)/60 )) min"

# ------------------------------------------------------------------ 8. output
log "result"
OUTDIR="$WORKDIR/openwrt/bin/targets/qualcommax/ipq60xx"
if [ -d "$OUTDIR" ]; then
    ls -lh "$OUTDIR" | grep -Ei "ax5|ubi|sysupgrade|sha256" | sed 's/^/    /'
    echo
    echo "  factory image (flash via u-boot web):"
    ls "$OUTDIR"/*redmi_ax5*squashfs-factory.ubi 2>/dev/null | sed 's/^/    /'
    echo "  sysupgrade image (flash from luci/ssh):"
    ls "$OUTDIR"/*redmi_ax5*squashfs-sysupgrade.bin 2>/dev/null | sed 's/^/    /'
    echo
    echo "  verify UBI magic:"
    for f in "$OUTDIR"/*redmi_ax5*squashfs-factory.ubi; do
        [ -f "$f" ] || continue
        printf "    %s -> " "$(basename "$f")"
        head -c 4 "$f" | od -An -c | tr -d ' \n'; echo "  (expect UBI#)"
    done
else
    die "output dir missing, check $WORKDIR/build.log"
fi

log "DONE. copy the factory.ubi back to the windows machine"
