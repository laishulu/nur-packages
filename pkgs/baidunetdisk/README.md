# baidunetdisk

把百度网盘 Linux 客户端打包成 Nix 包：厂商的 `.deb` 解包后原样保留（不 patchelf），
跑在 `buildFHSEnv` 沙箱里。本仓库不分发二进制，构建时由 `fetchurl` 从官方 CDN 下载。

- 上游：<https://pan.baidu.com/download>
- 安装包：`baidunetdisk_8.9.7_amd64.deb`（x86_64，Electron 22.3.27 / Chrome 108）
- 许可：专有（`meta.license = unfree`）

## 用法

`license` 是 unfree，需要允许：

```nix
nixpkgs.config.allowUnfree = true;
```

flake 内部已经开了 `allowUnfree`：

```sh
nix run .#baidunetdisk                 # 启动客户端
nix build .#baidunetdisk               # 只构建
nix-build -A baidunetdisk --arg pkgs 'import <nixpkgs> { config.allowUnfree = true; }'
```

作为 flake 输入 / overlay 的用法见仓库根 [`README.md`](../../README.md)。

## 实现

本包只做三件事：

1. `dpkg-deb -x` 解包 `.deb`，把 `/opt/baidunetdisk` 原样放进 `$out/opt`，并关掉
   `strip` / `patchELF` / `fixup`——厂商的 ELF 和 asar 都不能被改写；
2. 用 `buildFHSEnv` 提供 glibc、gtk3、gtk2、nss、X11 等运行库，客户端在沙箱里以
   未 patchelf 的状态运行；
3. 提供 `$out/bin/baidunetdisk` 包装脚本、`.desktop` 文件和 SVG 图标。

### 为什么需要 GTK2 的 C++ 绑定

客户端是 Electron 22，但 `resources/core.asar/main.js` 会用 koffi 加载一个链接了
`libgtkmm-2.4.so.1` 的 vendor 库（`libbrowserengine.so`）。少了它客户端能启动进程，
但主窗口出不来，日志里是：

```
[ERROR] Failed to load main.js ...: Error: Failed to load shared library: libgtkmm-2.4.so.1
```

所以这个包比一般 Electron 包多了 GTK2 一整套：

- `pkgs.gtk2`：nixpkgs 还有，但已经被标记为待移除（`meta.problems`），直接求值会
  报错。这里用 `overrideAttrs` 清掉这个标记——二进制是闭源的，没法改成用 gtk3。
- `gtkmm 2.24.5`：nixpkgs 已经删了，见 [`gtkmm2.nix`](./gtkmm2.nix)（沿用旧表达式，
  只把依赖换成 `glibmm_2_4` / `cairomm_1_0` / `pangomm_1_4` / `atkmm` 这些带版本号的
  属性名）。

如果哪天 nixpkgs 连 `pkgs.gtk2` 的源码都删了（NixOS 27.05 计划移除），这个包也需要像
`gtkmm2.nix` 一样自己带一份 GTK2 的构建表达式。

### 沙箱里的其他处理

- **`--no-sandbox`**：`.deb` 的 postinst 会给 `chrome-sandbox` 设 setuid，setuid 二进制
  不能放进 Nix store，所以 Chromium 沙箱关闭（厂商自己的 `.desktop` 也是这么做的）。
- **D-Bus**：会话总线 socket 在 `/run/user/$UID`，沙箱默认看不到，会让客户端连不上
  portal / 通知 / 托盘服务（日志 `A connection to the bus can't be made`），因此把
  `/run/user` 绑进沙箱。
- **私有 `/dev/shm`**：厂商代码在 `/dev/shm` 里用固定名字创建对象
  （`sem.baidu_netdisk_service_mutex`、`netdisk_unite_message_queue`），
  `netdisk_service` 会以 `O_RDWR` 打开已存在的信号量。如果同名文件属于**别的用户**，
  `/dev/shm` 的 sticky 位让它既删不掉也打不开，服务就会抛未捕获的
  `boost::interprocess::interprocess_exception: Permission denied` 然后 SIGABRT。
  沙箱给 `/dev/shm` 挂私有 tmpfs，这组名字就只在本实例内有效，也不会再污染宿主的
  `/dev/shm`。
- **VA-API**：沙箱里带 `libva` 和 VA 驱动。`mesa` 只提供 AMD/Nouveau/virtio/D3D12 的
  `*_drv_video.so`，Intel 的 `iHD_drv_video.so` 在 `intel-media-driver` 里，所以额外
  加了这个包——否则 libva 在 Intel 机器上一个驱动都找不到。NVIDIA 的
  `nvidia-vaapi-driver` 没带：它要宿主的 NVIDIA 驱动库，FHS 里没有。
- **读写**：客户端把配置写到 `~/.config/baidunetdisk`，安装目录只读没问题，所以不像
  `cmcc-jtydn` 那样需要复制一份可写副本。
- **自检**：`baidunetdisk --check-libs` 在沙箱里对主程序、各个 helper 和 vendor `.so`
  逐个跑 `ldd`，打印仍然缺失的库（正常输出
  `baidunetdisk: no missing shared libraries`）；`baidunetdisk --check-vaapi` 直接跑
  `vainfo`，打印 libva 实际加载的驱动和解码 profile。

## 验证情况

在本仓库的开发机上做过：

- `nix build .#baidunetdisk` 通过（`.deb` 约 255 MB，安装后约 665 MB）；
- `baidunetdisk --check-libs`：没有缺库；
- 在 `Xvfb` + `dbus-run-session` 里启动，主窗口（950×575，标题「百度网盘」）正常出现，
  扫码登录页、二维码、中文文案都正常渲染；
- 用一条别属主的 `sem.baidu_netdisk_service_mutex` 复现了 `netdisk_service` 的
  SIGABRT（`boost::interprocess::interprocess_exception: Permission denied`）；
  给沙箱挂私有 `/dev/shm` 后，同样条件下服务正常存活，宿主的 `/dev/shm` 也不再被写入；
- 沙箱内 `vainfo`/`--check-vaapi` 报 `Intel iHD driver ... 26.3.5`，H.264/HEVC/VP9
  解码 profile 齐全（宿主机 GPU 是 Intel，`/dev/dri/renderD128`）。

没有验证的部分：真实桌面上的托盘图标、文件对话框、拖拽上传（需要真正的桌面环境）。

## 终端里的无害输出

- `[ERROR:gl_utils.cc(319)] ... GL Driver Message (OpenGL, Performance, ...): GPU stall due
  to ReadPixels`：Chromium 把 GL 驱动的「性能」级提示也按 ERROR 打到 stderr，来源是
  客户端自己用 WebGL 画界面时的帧回读，不影响功能。`--log-level=3` 和
  `--disable-logging` 都压不住它（GPU 进程直接写 stderr），不想看就重定向：
  `nix run .#baidunetdisk 2>/dev/null`。
- `libva error: vaGetDriverNames() failed with unknown libva error`：这是 libva 在
  **X11 显示后端**上枚举驱动名时的自检失败，不代表“没找到驱动”。可以自己复现：
  `vainfo --display x11` 会打出同一行，紧接着仍然报
  `Driver version: Intel iHD driver ...` 并列出解码 profile；`vainfo --display drm`
  则完全没这行。Chromium 把它当非致命继续初始化，可以忽略。

## 已知限制

- 只支持 `x86_64-linux`：厂商只提供 amd64 的 `.deb`（arm64 的 Spark Store 包还停在
  4.17.7 的旧产品线）。
- 应用内自动更新不可用：store 只读，客户端自己下载的更新包装不进去。升级本包要改
  `version` 和 `hash`，并重新确认 GTK2 依赖没变。
- `.deb` 的 postinst 做的 Deepin 文件管理器扩展、右键菜单、`mimeapps.list` 修改都没做；
  只安装了 `.desktop`、图标和 `x-scheme-handler/baiduyunguanjia` 的 MimeType。
- 百度官方的下载页至今还挂着 4.17.7（Electron 11 的老客户端）；CDN 上 8.9.x 才是当前
  版本，本包取的是 8.9.7。

## 升级

新版本一般还在同一个路径下：

```sh
version=8.9.8
curl -L -o baidunetdisk.deb \
  "https://issuecdn.baidupcs.com/issue/netdisk/LinuxGuanjia/$version/baidunetdisk_${version}_amd64.deb"
sha256sum baidunetdisk.deb   # 转成 SRI 后填进 default.nix 的 hash
dpkg-deb -c baidunetdisk.deb | head   # 确认 /opt/baidunetdisk 布局没变
```

路径里没有 `8.9.8` 时会返回 404；用 `curl -sI` 探测即可。
