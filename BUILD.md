# AX5 定制固件 —— Linux 容器编译作业书

> 给容器里的 agent：照本文档顺序执行即可。所有命令都已实测校验。
> 一键脚本：`build-on-linux.sh`（可直接 `bash build-on-linux.sh`）

---

## 一、这次要编什么

| 项 | 值 |
|---|---|
| 目标设备 | Redmi AX5 / RA67（`qualcommax` → `ipq60xx` → `redmi_ax5`） |
| 架构 | **aarch64**（64 位，注意不是 armv7） |
| 源码 | `https://github.com/King-Of-Knights/openwrt-6.x.git` 分支 `main` |
| 编译配置仓库 | `https://github.com/hx-design/IPQ.git` 分支 `main` |
| 配置文件 | `configs/ipq60xx-ax5-sidegate.config` |
| 首启预置脚本 | `files/etc/uci-defaults/90-ax5-sidegate` |
| 默认管理地址 | **`192.168.5.250`**（网关 `192.168.5.1`） |
| 默认密码 | `hx199591` |
| WiFi | **不编译**（`11AC/11AX_SUPPORT not set`） |

**为什么必须预置 192.168.5.250**：AX5 在客厅，电脑在书房，两者之间没有可用的直连网线。刷机后如果设备停在 `192.168.6.1`，书房电脑（只能走 WiFi）**永远访问不到它**。预置成主路由网段里的地址后，刷完直接能开 LuCI。

---

## 二、硬件要求（不满足就别开始）

| 项 | 最低 | 推荐 | 说明 |
|---|---|---|---|
| 磁盘 | **35 GB** | 50 GB | 源码 ~2 GB + 编译产物 ~25 GB |
| 内存+swap | **6 GB** | 8 GB+ | 低于 6 GB 会 OOM，先加 swap |
| CPU | 2 核 | **8 核+** | 4 核约 4 小时，8 核约 2 小时 |
| 系统 | Debian 11/12 或 Ubuntu 22.04/24.04 | 同 | 其他发行版需自行换依赖 |

检查命令：
```bash
nproc; free -g; df -BG --output=avail $HOME | tail -1
```

---

## 三、执行步骤（一键脚本已封装，以下是展开说明）

### 步骤 0：网络自检（很重要）

编译要从 GitHub 拉源码和上百个包，**国内网络常常卡在这里**。

```bash
time curl -sI -m 15 https://github.com > /dev/null
```

- **2 秒内返回** → 直连没问题，继续
- **超时或超过 10 秒** → 先设代理，否则 `git clone` 和 `make download` 会卡死：

```bash
export https_proxy=http://<代理地址>:<端口>
export http_proxy=$https_proxy
export all_proxy=$https_proxy
git config --global http.proxy $https_proxy
```

### 步骤 1：依赖安装

```bash
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
sudo apt-get install -y build-essential clang flex bison g++ gawk \
  gcc-multilib g++-multilib gettext git libncurses-dev libssl-dev \
  python3-setuptools python3-distutils rsync swig unzip zlib1g-dev file wget \
  ca-certificates autoconf automake autopoint binutils bzip2 ccache cpio curl \
  device-tree-compiler fastjar gperf haveged help2man intltool libc6-dev-i386 \
  libelf-dev libglib2.0-dev libgmp3-dev libltdl-dev libmpc-dev libmpfr-dev \
  libreadline-dev libtool lrzsz mkisofs msmtp nano ninja-build p7zip \
  p7zip-full patch pkgconf python3 python3-pip python3-ply python3-pyelftools \
  qemu-utils re2c scons squashfs-tools subversion texinfo uglifyjs upx-ucl \
  vim xmlto xxd
# 可选，失败不影响
sudo apt-get install -y asciidoc antlr3 libncursesw5-dev 2>/dev/null || true
```

> `python3-distutils` 在 Ubuntu 24.04 已并入 `python3`，装不上就删掉该项重跑。

### 步骤 2：拉源码

```bash
mkdir -p ~/ax5 && cd ~/ax5
git clone --depth 1 -b main https://github.com/King-Of-Knights/openwrt-6.x.git openwrt
git clone --depth 1 -b main https://github.com/hx-design/IPQ.git buildkit
```

### 步骤 3：跑 diy 脚本（装 feeds + 改默认 IP + 换主题）

```bash
cd ~/ax5/openwrt
cp ../buildkit/diy-script.sh ./diy.sh
chmod +x diy.sh
# 上游脚本假设在 GitHub Actions 里跑，用 $GITHUB_WORKSPACE 定位图片，这里改成实际路径
sed -i "s|\$GITHUB_WORKSPACE|$HOME/ax5/buildkit|g" diy.sh
./diy.sh
```

这一步会 `feeds update` + `feeds install -a`，**耗时 5–20 分钟且最容易卡网络**。失败就重跑，可以断点续传。

### 步骤 4：应用定制配置和首启脚本

```bash
cd ~/ax5/openwrt
cp ../buildkit/configs/ipq60xx-ax5-sidegate.config .config
mkdir -p files
cp -r ../buildkit/files/. files/
chmod +x files/etc/uci-defaults/90-ax5-sidegate
make defconfig
```

### 步骤 5：**关键校验（不通过就别编译）**

`make defconfig` 会自动修正依赖图，可能把某些包丢掉。必须确认这些还在：

```bash
for p in luci-app-openclash bash curl coreutils-nohup dnsmasq-full \
         kmod-tun luci-i18n-base-zh-cn block-mount kmod-usb-storage; do
  grep -q "^CONFIG_PACKAGE_${p}=y" .config && echo "OK   $p" || echo "MISS $p  <-- 必须修"
done
grep "^CONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_redmi_ax5=y" .config
```

如果有 `MISS`，说明该包在当前源码树里不存在（可能改名了），用 `./scripts/feeds search <名字>` 找实际包名，改配置后重跑。

**特别提醒**：`bash`、`curl`、`coreutils-nohup` 这三项如果缺失，OpenClash 装上也是死的（这是上游配置的原始 bug）。

### 步骤 6：预下载 + 编译

```bash
make download -j$(nproc)          # 预下载所有源码包，可重复执行
make -j$(nproc) V=s 2>&1 | tee ~/ax5/build.log
```

**首次编译 2–5 小时**（取决于核数）。中途失败用 `make -j1 V=s` 串行重跑，能看到真实报错。

### 步骤 7：取产物

```bash
ls -lh ~/ax5/openwrt/bin/targets/qualcommax/ipq60xx/ | grep -i ax5
```

需要的两个文件：

| 文件 | 用途 |
|---|---|
| `*redmi_ax5*squashfs-**factory.ubi**` | U-Boot Web 刷机（需要网线直连 WAN 口） |
| `*redmi_ax5*squashfs-**sysupgrade.bin**` | **从现有系统网页/SSH 升级（推荐，不用动线）** |

产物校验：
```bash
head -c 4 <factory.ubi> | od -An -c     # 应为 UBI#
ls -l <factory.ubi>                     # 应在 50-60 MB
```

---

## 四、编完之后怎么送回 Windows

容器里用 `scp` 或直接 HTTP 服务把文件取走：

```bash
# 容器内起一个临时下载服务
cd ~/ax5/openwrt/bin/targets/qualcommax/ipq60xx/
python3 -m http.server 8899
```

Windows 侧：
```powershell
curl.exe -o ax5-custom.ubi http://<容器地址>:8899/<文件名>
```

或者反过来，从 Windows 用 scp 拉：
```bash
scp user@<容器地址>:~/ax5/openwrt/bin/targets/qualcommax/ipq60xx/*.ubi .
```

**只取 `factory.ubi` 和 `sysupgrade.bin` 两个文件即可**，其他（packages.tar.gz、config.buildinfo 等）都不需要。

---

## 五、已知坑（提前知道能省几小时）

| # | 现象 | 原因 | 解决 |
|---|---|---|---|
| 1 | `feeds update` 卡住不动 | GitHub 在国内慢 | 设 `http_proxy`，或给 git 配 `url."https://ghproxy.com/https://github.com/".insteadOf` |
| 2 | `make download` 大量 404 | 上游改了包版本 | 忽略，`make` 时会重试；真缺包才处理 |
| 3 | 编译到一半 `Killed` | 内存不足 | 加 swap：`dd if=/dev/zero of=/swap bs=1M count=4096; mkswap /swap; swapon /swap` |
| 4 | `make defconfig` 后包变少 | 依赖冲突 | 见步骤 5 校验，缺什么补什么 |
| 5 | `diy.sh` 报 `cp: cannot stat .../bg1.jpg` | 没改 `$GITHUB_WORKSPACE` | 按步骤 3 的 sed 改路径 |
| 6 | 产物只有几个 MB | 编译没真正完成 | 看 `build.log` 末尾的 error |
| 7 | OpenClash 内核架构 | **产物是 aarch64** | 内核要下 `clash-linux-arm64`，不是 armv7 |

---

## 六、刷机路径（编好后用哪条）

AX5 现在在客厅，电脑在书房只有 WiFi，**没有可用的直连网线**，所以：

### 路线 A：sysupgrade 升级（推荐，零动线）

从当前 Nwrt 系统（`192.168.5.250`，SSH 密码 `hx199591`）直接刷：

```bash
scp sysupgrade.bin root@192.168.5.250:/tmp/
ssh root@192.168.5.250
sysupgrade -F -n /tmp/sysupgrade.bin
```

刷完重启，设备应该直接出现在 `192.168.5.250`。
**风险**：Nwrt(19.07) → libwrt(6.x) 跨大版本，有一定失败概率。

### 路线 B：U-Boot Web 刷（可靠，但要把 AX5 搬回书房）

如果路线 A 失败，设备会停在无响应状态。这时：

1. 把 AX5 从客厅**搬回书房**（只需电源 + 一根短线接电脑）
2. 网线插 **WAN 口**，按住 RESET 约 **15 秒** 松手
3. 浏览器开 `192.168.1.1`，上传 `factory.ubi`
4. 刷完搬回客厅接主路由

**注意：U-Boot Web 只在 WAN 口响应，而且 RESET 要按满 15 秒**（这两点今晚已经实测确认，教程里写的"闪 5 下就松"是错的）。

---

## 七、给 agent 的最简执行指令

```bash
# 一条命令搞定（脚本内含全部检查、依赖、编译、产物校验）
cd ~ && git clone --depth 1 https://github.com/hx-design/IPQ.git ax5-kit
bash ax5-kit/build-on-linux.sh 2>&1 | tee ~/ax5-full.log
```

或者只下载脚本：
```bash
curl -O https://raw.githubusercontent.com/hx-design/IPQ/main/build-on-linux.sh
bash build-on-linux.sh
```

> 注意：`build-on-linux.sh` 目前只在本地工作目录，还没推到 GitHub。如果要用 URL 方式，需要先 push。
