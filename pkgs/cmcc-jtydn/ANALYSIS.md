# cmcc-jtydn 安装包分析

分析对象：`CMCC-JTYDN-UOSx86-2.23.1.deb`
（来源 <https://soho.komect.com/clientDownload> → UOS 版 AMD64，
下载端点 `https://dl.soho.komect.com/upgrade/download/app/ad2bcdde85d84d6a`）

- 大小：246,700,884 字节（235.27 MiB）
- SHA256：`65fa5a093d73bfef407304b32ed45a1c761d4b105ebdcfa2ffea67e9de751202`
- 包结构：`debian-binary` / `control.tar.gz` / `data.tar.xz`（标准 ar）

## control

```
Package: cmcc-jtydn
Version: 2.23.1
License: unknown
Vendor: soho.komect.com <dingguowei@cmhi.chinamobile.com>
Architecture: amd64
Maintainer: soho.komect.com <dingguowei@cmhi.chinamobile.com>
Installed-Size: 1118737            (约 1.07 GiB)
Depends: libgtk-3-0, libnotify4, libnss3, libxss1, libxtst6, xdg-utils,
         libatspi2.0-0, libuuid1, libsecret-1-0
Conflicts: cloud-computer-kylin
Replaces: cloud-computer-kylin
Recommends: libappindicator3-1
Homepage: https://soho.komect.com
```

Depends 是典型的 Electron 依赖集（gtk3 / nss / xss / xtst / atspi / secret），
没有 Qt、没有 Xorg 服务器依赖，说明界面就是 Electron。

## 文件布局

```
/opt/chuanyun-vdi-client/
├── cmcc-jtydn                155.8 MiB  Electron 22.3.27 主程序
├── chrome-sandbox            50 KiB     postinst chmod 4755
├── chrome_crashpad_handler
├── libEGL.so / libGLESv2.so / libffmpeg.so / libvk_swiftshader.so / libvulkan.so.1
├── launch-app.sh             被 postinst 使用的启动脚本（含硬编码 /opt 路径）
├── resources/
│   ├── app.asar              103.2 MiB
│   └── app.asar.unpacked/node_modules/
│       ├── chuanyunAddOn/          449.7 MiB  主 VDI SDK（含 Qt5.12、FFmpeg 58、
│       │                                     GStreamer、ICU、libm/libz 等）
│       │   └── ccsdk/uos/{bin,config,lib,include}
│       │       └── bin/  chuanyun-view(95.6M), chuanyun-redirect,
│       │                 fusermount3, chuanyun-redirect.service,
│       │                 99-usb-permissions.rules, qt.conf, run_app.sh
│       └── chuanyunAddOn-zte/      314 MiB    ZTE uSmartView 分支
│           └── ccsdk/{bin,config,lib}
│               └── bin/  uSmartView_VDI_Client(131.4M), QoEAgent(2.1M),
│                         bootCypc, usbredirect, fusermount3, net_ping,
│                         zqoe.service, start_qoe.sh, monitor_qoe.sh
/usr/share/applications/cmcc-jtydn.desktop
/usr/share/icons/hicolor/0x0/apps/cmcc-jtydn.png
/usr/share/doc/cmcc-jtydn/changelog.gz
```

- `postinst` 引用的 `netdetectAddOn/ntsdk`、`net_ping`、`99-usb-permissions.rules`
  在 2.23.1 里**根本不存在**：`md5sums`（1206 项）里没有任何匹配路径，说明这些
  postinst 步骤是历史遗留、在本版本中会打印错误但不影响安装（脚本没有 `set -e`）。
- `app.asar` 内部没有 `/opt/chuanyun-vdi-client` 字样，主程序是路径无关的：
  Electron 以自身可执行文件位置解析 `resources/`，所以可以整体搬到任意目录运行。
- 只有系统集成文件硬编码了 `/opt`：`chuanyun-redirect.service`、`zqoe.service`、
  `monitor_qoe.sh`、`start_qoe.sh`。

## 维护脚本做了什么

`postinst`（节选）：

- `update-alternatives --install /usr/bin/cmcc-jtydn ... /opt/chuanyun-vdi-client/cmcc-jtydn`
- `chmod 4755 chrome-sandbox`（SUID sandbox）
- `chmod 4755 bin/fusermount3`、`chmod 4755 bin/chuanyun-redirect`（SUID 文件重定向）
- `setcap cap_net_raw+ep net_ping`（网络探测）
- 复制 `fusermount3` 到 `/usr/local/bin` 并 `chown root && chmod 4755`
- `mv zqoe.service /lib/systemd/system/` → `systemctl enable/start`
- `mv chuanyun-redirect.service /lib/systemd/system/` → `systemctl enable/start`
- `mv 99-usb-permissions.rules /etc/udev/rules.d/` → `udevadm reload`
- 创建可写目录：`ccsdk/uos/{config,logs}`、`ccsdk-zte/{config,log}` 等 `chmod 777`，
  配置文件 `chmod 656`
- 把用户加入 `dialout` 组（串口/USB 设备）
- 复制 `.desktop` 到用户桌面

`preinst` / `prerm` / `postrm`：杀掉 `cmcc-jtydn`、`chuanyun-view`、
`chuanyun-redirect`、`uSmartView_VDI_Client`、`QoEAgent`、`usbredirect` 等进程；
卸载时禁用并删除两个 systemd 服务，删除 `~/.config/CMCC-JTYDN`。

## 对打包的结论

1. **必须可写**：客户端会写安装目录里的 `config/`、`logs/`（postinst 专门放宽权限），
   所以不能直接从只读 store 运行 → 首次启动复制到 `$XDG_DATA_HOME`。
2. **不需要 patchelf**：主程序和所有 native addon 都按 UOS 的 FHS 布局构建，
   在 `buildFHSEnv` 里配齐 gtk3/nss/X11/FUSE 等即可运行；强行 `autoPatchelfHook`
   反而可能把自带的 Qt5/FFmpeg 换成 nixpkgs 版本而破坏兼容性。
3. **SUID / setcap / systemd / udev 一律不复制**：这些需要 root 改动系统状态，
   在 Nix store 语义下也无法表达。主界面登录、云桌面串流不依赖它们；
   USB 重定向、文件拖拽（fuse）、QoE 测速会缺失。
4. `.desktop` 的 `Exec` 硬编码 `/opt/...`，需要用自己的 launcher 覆盖。

## 与另一个“移动云电脑”客户端的区别

此前从 `ecloud.10086.cn`（移动云官网帮助中心的历史版本页）取到的是另一条产品线：

| | `Ecloud_CloudComputer_UOS_x86_V3.7.6.deb` | `CMCC-JTYDN-UOSx86-2.23.1.deb` |
| --- | --- | --- |
| 包名 | `com.cmss.saas.ecloudcomputer` 3.7.6.0 | `cmcc-jtydn` 2.23.1 |
| 来源 | ecloud.10086.cn（移动云/政企） | soho.komect.com（家庭云电脑） |
| 安装路径 | `/opt/apps/com.cmss.saas.ecloudcomputer` | `/opt/chuanyun-vdi-client` |
| 技术栈 | Qt5 自研渲染 + ZTE/H3C/CMSS 驱动 SDK | Electron 22.3.27 + 川云 VDI |
| 体积 | 488 MiB deb / 1.75 GiB 安装 | 235 MiB deb / 1.07 GiB 安装 |
| 额外风险 | postinst 写入 `/etc/sudoers` 的 NOPASSWD 规则 | 无 sudoers 改动 |

两者都是中国移动的云电脑客户端，但不是同一个产品，本仓库只打包后者。
