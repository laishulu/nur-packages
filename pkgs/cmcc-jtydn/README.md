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

作为 flake 输入或通过本仓库的 overlay 使用，见仓库根 [`README.md`](../../README.md)。

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

## 键盘：Shift 卡住（已在包内修掉）

现象：进入云电脑后按一次 Shift，之后远端就一直是“按住 Shift”的状态——小写字母
全变大写、数字键出的是 `!@#$`，本地其它程序完全正常；关掉客户端重连才恢复。

根因是**键盘布局 + 客户端按键识别方式**的组合：

1. KDE 键盘设置里开了 “Both Shift keys together enable Caps Lock”
   （`~/.config/kxkbrc` 的 `Options=...,shift:both_capslock`），XKB 里是：

   ```
   key <LFSH> { [ Shift_L, Caps_Lock ] };
   key <RTSH> { [ Shift_R, Caps_Lock ] };
   ```

   即 Shift 键「按下时是 Shift_L、加 Shift 之后是 Caps_Lock」。

2. 客户端把按键转成 keysym 时用的是**当前键盘状态**（Qt 走
   `xkb_state_key_get_one_sym(state, keycode)`，抓键线程走 `XLookupString`）。
   X11 的抬起事件到达时，正在释放的那个修饰键还按着，于是取到的是「加 Shift」
   的那一级：

   | 事件 | 取得的 keysym |
   | --- | --- |
   | Shift 按下 | `0xffe1` Shift_L ✅ |
   | Shift 抬起 | `0xffe5` Caps_Lock ❌ |

   可以在本机复现：

   ```
   setxkbmap -print | grep both_capslock      # keymap 里确实有这个选项
   xmodmap -pke | grep 'keycode  50'          # Shift_L Caps_Lock
   ```

3. 客户端于是把 Shift 的抬起当成 Caps Lock：日志里是
   `QEvent::KeyRelease: key: 16777252`（Qt::Key_CapsLock）、
   `Release scanCodeHash: 58`（CapsLock），**Shift 的 key-up 从来没发出去**，
   guest 就一直按着 Shift。只有修饰键会中招（普通字母/数字的 keysym 不受这个
   选项影响），重连清空输入通道后恢复。

修法：一个只加载进客户端进程的 `LD_PRELOAD` shim（源码见 `default.nix` 的
`keyboardFix`），包住 `xkb_state_key_get_one_sym`：当它把某个键解析成
`Caps_Lock`/`Shift_Lock`/`Num_Lock`、而这个键的**基础（level 0）keysym 是修饰键**
时，改报基础 keysym。

只钩这一个函数就够，是因为客户端不管走哪条路，修饰键最后都要在 Qt 里被解析成
`Qt::Key` 才会发给 guest：

| 路径 | 触发条件 | 修饰键的 keysym 来自 |
| --- | --- | --- |
| 抓键线程（grabkb）| `XGrabKeyboard` 成功 | 合成事件回到 Qt 后再解析 |
| 普通焦点路径 | 没抓住键盘，Qt 直接收事件 | Qt 自己的 xkb state |

厂商二进制一个字节都没改。普通键（含 Shift+字母）不满足“基础 keysym 是修饰键”，
原样返回，所以大写字母、`!@#$` 不受影响。

对着本机真实 keymap（`us` + `shift:both_capslock`）实测：

```
                     不加 shim            加 shim
Shift 键(shift 按着) 0xffe5 Caps_Lock     0xffe1 Shift_L
'1'  (shift 按着)    0x21  '!'            0x21  '!'
'a'  (shift 按着)    0x41  'A'            0x41  'A'
```

启动后日志应该变成 `QEvent::KeyRelease: key: 16777248`（Qt::Key_Shift）、
`Release scanCodeHash: 42`，而不是 58。

- 想临时关掉：`CMCC_NO_KB_FIX=1 cmcc-jtydn`。
- 关掉 `shift:both_capslock` 映射当然也能解决，但不是必须的，包内已经兼容。

## 连上后黑屏、菜单卡死

现象：连上云电脑后 viewer 窗口全黑、整个界面没响应（悬浮菜单点不动），但进程没退出；
时有时无。

根因：viewer 在 **GUI 线程**里通过 System V 消息队列启动 USB 重定向：

```
QSpiceWidget::displayOpenGlInvalidate
  → QSpiceConn::DealCdpUSB / StartCdpUSB
    → DeviceRedirectManager::StartCdpUSB
      → MessageQueue::send → msgsnd(2)
```

本包没有装 `.deb` 里那套 setuid 的 `chuanyun-redirect` + systemd 服务，队列没有消费者；
而 `kernel.msgmnb` 只有 16384 字节，队列一满 `msgsnd` 就**阻塞**（不是返回错误）。UI 线程
卡死 → 不绘制、不发 firstFrame、菜单无响应；解码线程是另一条线程，所以日志里还能看到
`decoder first avframe`。这也解释了为什么软件渲染 / 换 GL 后端都没用。

可以这样确认（黑屏时看队列）：

```sh
ipcs -q
# 0x00000064 msqid 0 ... 已用 16065 字节 10 条     ← 16384 的上限快满了
cat /proc/sys/kernel/msgmnb        # 16384
```

以及崩溃栈（会话结束时 abort 也在同一条路径）：

```
__libc_msgsnd ← MessageQueue::send ← DeviceRedirectManager::StartCdpUSB
← QSpiceConn::StartCdpUSB ← QSpiceWidget::displayOpenGlInvalidate
```

修法：`displayFix` shim 里同时拦截 `msgsnd@GLIBC_2.2.5`，强制加 `IPC_NOWAIT`；队列满
（`EAGAIN`）或队列已被删除（`EIDRM`）时**丢弃这条消息并返回成功**，UI 线程不再阻塞。
这些消息只有 USB 重定向守护进程会读；它不在时本来也没人消费，丢掉没有副作用。

- 关掉：`CMCC_NO_DISPLAY_FIX=1 cmcc-jtydn`
- 调试：`CMCC_DEBUG_SHIM=1 cmcc-jtydn`，`/tmp/cmcc-shim.log` 里会看到
  `display shim: msgsnd queue 0 full/gone (EAGAIN), dropped`

> 顺带：黑屏时如果 `ipcs -q` 里那两个队列的属主是别的用户（比如 `nix`），是之前用
> 别的账号直接跑过厂商客户端留下的，可以用 `sudo ipcrm -q <msqid>` 清掉，不过装了本包
> 的 shim 之后不清也不会再卡。

## 连上后分辨率被顶到本地 4K（已修）

现象：有时连上去后 viewer 按本地屏幕的 3840×2160 去申请分辨率，云端驱动不了就黑屏；
顶部悬浮菜单里能看出分辨率和本地不一致。时有时无。

根因：本地是 4K 屏 + 200% 缩放（`kwinoutputconfig.json` 里 `eDP-1` 的 `scale: 2`，
X 侧 `Xft.dpi: 192`），但 `buildFHSEnv` 里的 Qt 5.12 没有拿到这个缩放，看到的仍是
物理的 3840×2160：

```
spice-widget SPICE displayPrimaryCreate: Display Create W x H 1920 x 1200
now is fullscreen: vm size() 1920x1200 local 3840x2160
spice-widget updateSize: request vm updateDispaly W x H 3840 2160
```

guest 建好显示后，viewer 立刻通过 `spice_main_channel_update_display()` 请求把它切到
窗口大小；云端接受这个模式但驱动不了就黑屏。别的客户端不动 guest 的分辨率、只在本地
缩放，所以没事。

修法（`default.nix` 里的 `displayFix` shim + 启动器里的分辨率上限）：

1. 启动器在进沙箱后读 X 服务器的 `Xft.dpi`（KWin 在 200% 缩放下给 192）和
   `xrandr --current` 的物理分辨率（3840×2160），算出**逻辑分辨率**
   `3840*96/192 x 2160*96/192 = 1920x1080`，通过 `CMCC_MAX_DISPLAY` 传给 shim。
2. `displayFix` 用 version script 导出 `spice_main_channel_update_display@SPICEGTK_1`
   来拦截这个调用，把请求宽度/高度夹到 `CMCC_MAX_DISPLAY`（拿得到 guest 当前主
   surface 尺寸时也不会超过它），**请求照常发出去**。

注意别做成“直接丢弃请求”：实测丢一次之后 guest 连第一帧都不出（viewer 日志里没有
`firstFrame come`），所以这里是夹小而不是不发。

- 关掉：`CMCC_NO_DISPLAY_FIX=1 cmcc-jtydn`
- 自己定上限：`CMCC_MAX_DISPLAY=2560x1440 cmcc-jtydn`（不设时按逻辑分辨率算）
- 调试：`CMCC_DEBUG_SHIM=1 cmcc-jtydn` → `/tmp/cmcc-shim.log`，形如

  ```
  display shim loaded (pid 1234)
  display shim: call 3840x2160
  display shim: request 3840x2160, max 1920x1080, guest 0x0 -> sent 1920x1080
  keyboard shim loaded (pid 1234)
  ```

  厂商日志里的 `updateSize: request vm updateDispaly W x H 3840 2160` 是在调用**之前**
  打的，夹取不会改变它，不能用它验证。

## USB 重定向

`.deb` 的 USB 重定向由两部分组成：viewer 通过 System V 消息队列把「把某个 USB 设备
交给云端」的请求发出去，root 守护进程 `chuanyun-redirect` 接收后在本机认领设备
（libusbipd），并把设备的 VID:PID 写进 udev 规则。这条队列就是前面窗口卡死那节的
同一条；本包默认不装那个守护进程，所以客户端的 USB 列表一直是摆设。

本包把它补上了：

- `$out/bin/cmcc-jtydn-redirect`：在**单独的 FHS 沙箱**里启动厂商的
  `chuanyun-redirect`（它是指向 Debian 解释器的 UOS 二进制），库查找顺序和客户端
  包装一致——先镜像 FHS 库，再补 buster 才有的 soname，厂商目录最后。
- `$out/lib/systemd/system/cmcc-jtydn-redirect.service`：以 root 运行；
  `RuntimeDirectory=cmcc-jtydn` 提供可写的 `/run/cmcc-jtydn`（守护进程往里写 udev
  规则）；`Restart=always`，因为守护进程处理到上一条残留的 "stop" 消息会正常退出。
- NixOS 模块 `nixosModules.cmcc-jtydn-usb`（`modules/cmcc-jtydn-usb.nix`）：
  起上面那个服务，并加一条 `SUBSYSTEM=="usb" ... TAG+="uaccess"` 的 udev 规则，
  让桌面用户能看到设备。

启用（flake）：

```nix
{
  inputs.nur-packages.url = "github:laishulu/nur-packages";

  # nixosConfigurations.<host>.modules 里：
  modules = [
    inputs.nur-packages.nixosModules.cmcc-jtydn-usb
    {
      services.cmcc-jtydn-usb.enable = true;
      # 默认取 flake 自带的包；也可以显式指定：
      # services.cmcc-jtydn-usb.package = inputs.nur-packages.packages.x86_64-linux.cmcc-jtydn;
    }
  ];
}
```

如果你的配置把本仓库挂到了 `nur.repos.<名字>` 下（例如自己写一层 overlay：
`laishulu = import inputs.nur-laishulu { pkgs = prev; };`——注意本仓库目前**不在**
nix-community/NUR 的索引里，`pkgs.nur.repos.laishulu` 默认是不存在的），模块名是
`modules.cmcc-jtydn-usb`（复数 `modules`，`nixosModules` 是 flake 的输出名）。

这种情况下**不要**在模块文件里写 `imports = [ pkgs.nur... ]`：`pkgs` 是模块参数，
而 `imports` 在参数解析之前求值，会直接触发 infinite recursion。要放在 `flake.nix`
的 `nixosSystem.modules` 里：

```nix
modules = [
  inputs.nur-laishulu.nixosModules.cmcc-jtydn-usb
];
```

`package` 选项会依次找 `pkgs.cmcc-jtydn`（加了本仓库 overlay 时）和
`pkgs.nur.repos.laishulu.cmcc-jtydn`，都不用显式指定。

不用 flake 的话，把这个包做进 `environment.systemPackages` 之后手工写：

```nix
systemd.services.cmcc-jtydn-redirect = {
  description = "CMCC Cloud PC USB redirection";
  wantedBy = [ "multi-user.target" ];
  after = [ "network.target" "systemd-udevd.service" ];
  serviceConfig = {
    ExecStart = "${pkgs.cmcc-jtydn}/bin/cmcc-jtydn-redirect";
    Restart = "always";
    RuntimeDirectory = "cmcc-jtydn";
    LimitNOFILE = 65535;
  };
};
services.udev.extraRules = ''
  SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", TAG+="uaccess"
'';
```

说明与限制：

- 守护进程以 **root** 运行（.deb 的 unit 也是 `User=root`），它需要解开内核驱动绑定、
  访问 `/dev/bus/usb` 与 `/sys`，并写 udev 规则。
- 它跑在包自带的 FHS 沙箱里，`/run/cmcc-jtydn` 会被 bind 到沙箱内的
  `/etc/udev/rules.d`（宿主的 `/etc` 在 NixOS 上只读），所以它写的规则只在沙箱里
  生效；真正的权限由模块里那条静态 udev 规则 + root 守护进程保证。
- 会话结束后守护进程可能收到残留的 "stop" 消息而退出，`Restart=always` 会把它拉起来
  并保持空闲，这是预期行为。
- **顺序很重要**：客户端只在**连接那一刻**给守护进程发「启动 USB 服务」，断开时发
  「停止」。所以守护进程必须在客户端连接之前就已经在跑（开机自启正好满足）。如果
  你在会话中间 `systemctl restart cmcc-jtydn-redirect`，新的守护进程收不到那次启动
  消息，列表会是空的——断开重连一次即可。
- 实测（2.23.1 + 一个 SanDisk U 盘）：

  ```
  # journalctl -u cmcc-jtydn-redirect
  start to connect usb server main channel....
  success to connect server main channel!
  main channel handle request device list ...
  ✅ 已注册 USB 设备：busid=3-11, 设备总数=1

  # chuanyun-viewer_*.log
  🔍 解析 USB 状态变更: msg_type=5, vid=1921, pid=21923, busid=3-11, name=Ultra Luxe
  ✅ USB插入（正常设备）: busid=3-11, dev_name=Ultra Luxe
  原始设备数量: 1, 过滤后设备数量: 1
  ```

- 守护进程会往 `/etc/udev/rules.d/99-usb-permissions.rules` 追加 VID:PID 权限规则；
  沙箱里这个路径被 bind 到 `/run/cmcc-jtydn/udev`（unit 的 `ExecStartPre` 会先建目录），
  主机侧真正的设备权限由模块里那条静态 `TAG+="uaccess"` 规则提供。
- 其余问题看 `journalctl -u cmcc-jtydn-redirect`：`Connect fail ... 10800` 表示当时
  没有会话（客户端未连上），会话建立后应变成 `success to connect server main channel`。

## 已知限制

这些功能在上游 `.deb` 的 postinst 里通过 root 操作装配，本包**默认不做**，
属于“能用客户端、但外围集成缺失”的范围：

| 功能 | 上游做法 | 本包状态 |
| --- | --- | --- |
| Chromium SUID sandbox | `chmod 4755 chrome-sandbox` | 关闭 sandbox |
| USB 重定向（chuanyun-redirect） | systemd 服务（root）+ udev 规则 | **已提供**：`bin/cmcc-jtydn-redirect` + `lib/systemd/system/cmcc-jtydn-redirect.service`，用 NixOS 模块 `services.cmcc-jtydn-usb` 启用（见上一节） |
| 网络探测 `net_ping` | postinst 里 `setcap cap_net_raw+ep` | 2.23.1 根本没带这个二进制，属于空操作，无需处理 |
| udev 规则 `99-usb-permissions.rules` | 复制到 `/etc/udev/rules.d` | 2.23.1 里没有这个文件；守护进程运行时自己往里追加 VID:PID，沙箱里该路径被 bind 到 `/run/cmcc-jtydn/udev`；用户态访问由模块里的 `TAG+="uaccess"` 规则提供 |
| QoE 测速（zqoe.service） | 安装并启动 systemd 服务 | 由启动器代为启动：`monitor_qoe.sh` 里硬编码的 `/opt/...` 会在运行时改写到可写副本，客户端退出时一并停掉；`CMCC_NO_QOE=1` 可关闭 |
| `cmcc-jtydn` 命令 | `update-alternatives` 链接到 `/usr/bin` | 由 `$out/bin/cmcc-jtydn` 提供 |
| 桌面快捷方式 | 复制到用户桌面 | 提供 `.desktop`，不复制到桌面 |

USB 重定向现在由 `bin/cmcc-jtydn-redirect`（自带 FHS 沙箱）+ NixOS 模块
`services.cmcc-jtydn-usb` 提供，不再需要手工写 root wrapper。

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
