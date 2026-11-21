# cmcc-jtydn

把中国移动云电脑（家庭云电脑）的统信 UOS / Linux 客户端 `cmcc-jtydn` 打包成 Nix 包：
厂商 Electron 二进制保持未 patchelf 状态，跑在 `buildFHSEnv` 里。本包只做“下载 + 解包 +
包装”，不分发二进制，构建时由 `fetchurl` 从官方地址下载。

- 上游：<https://soho.komect.com/clientDownload>
- 安装包：`CMCC-JTYDN-UOSx86-2.23.1.deb`（x86_64，Electron 22.3.27 + 川云 VDI）
- 本仓库只做“解包 + 包装”：不分发二进制，构建时由 `fetchurl` 从官方地址下载

## 用法

本包的 `license` 是 `unfree`（客户端闭源）。flake 内部已经开了
`config.allowUnfree`；直接 `nix-build` 或写进 `configuration.nix` 时，需要：

```nix
nixpkgs.config.allowUnfree = true;
```

或临时 `NIXPKGS_ALLOW_UNFREE=1`。

### 在本仓库里构建

```sh
nix-build -A cmcc-jtydn          # 传统方式
nix run .#cmcc-jtydn             # flake
nix-build -A cmcc-jtydn --arg pkgs 'import <nixpkgs> {}'
```

作为 flake 输入或通过 NUR overlay 使用，见仓库根 [`README.md`](../../README.md)。

## 首次运行

第一次启动会把解包后的客户端复制到可写目录（约 1.1 GB）：

```
${XDG_DATA_HOME:-~/.local/share}/cmcc-jtydn/2.23.1/app
```

原因：`.deb` 的 postinst 会给 `resources/app.asar.unpacked/.../ccsdk` 下的
`config/`、`logs/` 等目录 `chmod 777`，客户端运行时确实会往安装目录里写文件，
而 Nix store 是只读的。复制完成后启动的是这份可写副本，之后的启动不再复制。

升级版本时会按新版本号重新复制一份，旧目录可手动删除。

## 运行时说明

- 客户端跑在 `buildFHSEnv` 里：glibc、gtk3、nss 等由 Nix 提供，厂商的
  ELF 二进制保持未 patchelf 状态，避免破坏 Electron 和自带 native addon。
- 库搜索顺序是固定的三层，前面的先命中：
  1. FHS 沙箱（nixpkgs 的 glibc/gtk3/X11，以及本包里自建的 OpenSSL 1.1）；
  2. Debian 10 (buster) 库，只补 nixpkgs 早就删掉的旧 soname
     （`libjpeg.so.8`、`libx264.so.155`、`libaom.so.0`、`libwebp.so.6` 等）；
     它们挂载在 `/debian-libs`，与 FHS 同名的库会被跳过——否则 buster 的
     `libharfbuzz.so.0` 会顶掉 nix 那份，再连带要求 `libgraphite2`、`libicu63`；
  3. 厂商自带的 `ccsdk/uos/lib`（Qt 5.12、FFmpeg 58、GStreamer、ICU）。
  厂商目录**不能放最前**：那个目录是给 UOS（glibc 2.31 时代）打的补丁层，自带
  `libm.so.6`、`libmount.so.1`、`libpcre2-8.so.0` 等旧版本，前置会把 FHS 的新库
  顶掉，于是新库反过来报 `version 'GLIBC_2.38' not found`、`'MOUNT_2_40' not found`。
- 缺库自检：`cmcc-jtydn --check-libs` 会对主程序和 `ccsdk` 里的 helper（Qt5 的
  `chuanyun-view` 等）逐个跑 `ldd`，只打印 `not found` 的项。缺什么就往
  `targetPkgs` 里补对应 nixpkgs 包，比一个个试快得多。
- 默认附加 `--no-sandbox --disable-setuid-sandbox`：`.deb` 依赖 setuid 的
  `chrome-sandbox`，而 setuid 程序不能放在 Nix store。NixOS 开启
  unprivileged user namespaces 时仍会走 Chromium 的 namespace sandbox。
- 需要图形会话（X11 / XWayland）以及 `XDG_DATA_HOME` 指向的可写目录。
- `buildFHSEnv` 依赖 `bubblewrap`，也就是内核要允许非特权 user namespace；
  如果系统关了 userns，`bwrap` 会直接报错，需要先放开。

## 已知限制

这些功能在上游 `.deb` 的 postinst 里通过 root 操作装配，本包**默认不做**，
属于“能用客户端、但外围集成缺失”的范围：

| 功能 | 上游做法 | 本包状态 |
| --- | --- | --- |
| Chromium SUID sandbox | `chmod 4755 chrome-sandbox` | 关闭 sandbox |
| USB 重定向（chuanyun-redirect） | systemd 服务 + setuid `fusermount3` | 未安装；服务文件里的 `/opt/...` 路径也不可用 |
| 网络探测 `net_ping` | postinst 里 `setcap cap_net_raw+ep` | 2.23.1 根本没带这个二进制，属于空操作，无需处理 |
| udev 规则 `99-usb-permissions.rules` | 复制到 `/etc/udev/rules.d` | 2.23.1 里同样缺失，无需处理 |
| QoE 测速（zqoe.service） | 安装并启动 systemd 服务 | 由启动器代为启动：`monitor_qoe.sh` 里硬编码的 `/opt/...` 会在运行时改写到可写副本，客户端退出时一并停掉；`CMCC_NO_QOE=1` 可关闭 |
| `cmcc-jtydn` 命令 | `update-alternatives` 链接到 `/usr/bin` | 由 `$out/bin/cmcc-jtydn` 提供 |
| 桌面快捷方式 | 复制到用户桌面 | 提供 `.desktop`，不复制到桌面 |

如果之后要补 USB 重定向，需要自己写一个以 root 运行的 wrapper（NixOS 里可以用
`systemd.services` + `security.wrappers`），并把 `chuanyun-redirect.service` 里的
`/opt/chuanyun-vdi-client/...` 替换成 `${cmcc-jtydn}/opt/...` 的实际路径。

## 实测记录

初版是在 Windows 上根据 `.deb` 内容静态编写并自审的，没有在 NixOS 上跑过。第一次
真机 `nix profile add` 之后暴露了这些问题，均已修正：

| 现象 | 原因 | 修正 |
| --- | --- | --- |
| `error while loading shared libraries: libgbm.so.1` | nixpkgs 的 `mesa` 不提供 `libgbm.so.1` | `targetPkgs` 里显式加 `libgbm`（顺带 `libglvnd`） |
| 满屏 `GLIBC_2.38 not found` / `MOUNT_2_40 not found` / `no version information available` | 厂商 lib 目录整体前置，旧版 `libm`/`libmount`/`libpcre2` 顶掉 FHS 新库 | 只链接 FHS 缺失的厂商库，其余走系统库 |
| `chuanyun-view: libpixman-1.so.0` 找不到 | Qt5 远程视图 helper 是独立进程，`gtk3`/`mesa` 的传递依赖里没有 pixman | `targetPkgs` 补 `pixman` 及 `xcb-util*`、`libjpeg_turbo`、`libwebp` 等 Qt5 运行库 |
| 缺 `iw` 命令 | netdetect 插件靠 `iw` 看无线链路，FHS 里没有 | `targetPkgs` 加 `iw`，并把 `/usr/sbin:/sbin` 补进 `PATH` |
| 缺 `libssl.so.1.1` | 厂商 VDI SDK 仍链接 OpenSSL 1.1，新 nixpkgs 已无 `openssl_1_1` | 内联 derivation 从源码构建 1.1.1w（`openssl_1_1` 在新 nixpkgs 里是 `throw`，探测它会炸） |
| `chuanyun-view` 缺一大串 `libx264.so.155` / `libjpeg.so.8` / `libaom.so.0` 等 | 这些库原先是 UOS（Debian 10）系统库，`.deb` 不带，nixpkgs 也没有对应 soname | 包内 `debianLibs` 从 Debian buster 归档解包对应库（`libjpeg.so.8` 取 Ubuntu focal 的 libjpeg-turbo8），放进 FHS 的 `/usr/lib` |

缺库排查用 `cmcc-jtydn --check-libs`：对主程序和 `ccsdk` 里的 helper 逐个跑 `ldd`，
只打印 `not found` 的项，缺什么往 `targetPkgs` 里补对应 nixpkgs 包即可（FHS 方案下
不需要 `autoPatchelfHook`）。

## 更新

1. 在 <https://soho.komect.com/clientDownload> 查看新版本；
2. 修改 `pkgs/cmcc-jtydn/default.nix` 里的 `version`；
3. `nix build`，用报错里的新 hash 替换 `hash =`（或用 `nix-prefetch-url` 取）。

## 许可证

本仓库的打包脚本：MIT（见 `LICENSE`）。
客户端本体为闭源商业软件，版权归中国移动所有；本仓库不包含、也不再分发其二进制。
