# nur-packages

[laishulu](https://github.com/laishulu) 的个人仓库，按 [NUR](https://github.com/nix-community/NUR) 的格式组织（当前未收录进 NUR 索引）。

## 包

| 属性 | 说明 | 平台 | 许可 |
| --- | --- | --- | --- |
| `font-sarasa-nerd` | Sarasa Term SC Nerd 字体 | 全平台 | OFL |
| `cmcc-jtydn` | 中国移动云电脑客户端（家庭云电脑 / 川云 VDI，2.23.1） | `x86_64-linux` | 专有（unfree） |
| `baidunetdisk` | 百度网盘 Linux 客户端（8.9.7） | `x86_64-linux` | 专有（unfree） |

`cmcc-jtydn` 是打包好的厂商二进制：`nix build` 会下载厂商 `.deb`（约 235 MB）并组装一个
`buildFHSEnv`，第一次运行再把客户端复制成 1.1 GB 的可写副本。细节、依赖和已知限制见
[`pkgs/cmcc-jtydn/README.md`](./pkgs/cmcc-jtydn/README.md) 与
[`pkgs/cmcc-jtydn/ANALYSIS.md`](./pkgs/cmcc-jtydn/ANALYSIS.md)。

`baidunetdisk` 也是厂商二进制：`nix build` 会下载百度网盘的 `.deb`（约 255 MB），解包后
同样跑在 `buildFHSEnv` 里，安装目录保持只读（客户端只往 `~/.config/baidunetdisk` 写配置）。
它需要 GTK2 的 C++ 绑定（`libgtkmm-2.4.so.1`），而 nixpkgs 已经删掉了 `gtkmm2`、并把
`gtk2` 标记为待移除，所以本包自己带了一份 `gtkmm 2.24.5`，并在本地清掉 `pkgs.gtk2` 的
移除标记。细节见
[`pkgs/baidunetdisk/README.md`](./pkgs/baidunetdisk/README.md)。

## 用法

> **注意**：这个仓库目前**没有进 nix-community/NUR 的索引**（NUR 的 `repos.json` 里没有
> `laishulu`），所以 `pkgs.nur.repos.laishulu.*` 取不到。用下面的 flake 入口。

### flake（推荐）

```nix
{
  inputs.nur-packages.url = "github:laishulu/nur-packages";

  outputs = { self, nixpkgs, nur-packages, ... }: {
    nixosConfigurations.host = nixpkgs.lib.nixosSystem {
      modules = [
        ({ pkgs, ... }: {
          nixpkgs.config.allowUnfree = true;   # cmcc-jtydn / baidunetdisk 是专有软件
          nixpkgs.overlays = [ nur-packages.overlays.default ];
          environment.systemPackages = [ pkgs.cmcc-jtydn pkgs.baidunetdisk ];
        })
      ];
    };
  };
}
```

`allowUnfree = true` 是必须的：本仓库只在 `pkgs.config.allowUnfree` 打开时才暴露
`cmcc-jtydn` 和 `baidunetdisk`（NUR 用它自己的严格 `pkgs` 评估每个仓库，不省略 unfree
属性会让整个仓库评估失败，所以做成按需暴露）。

### 直接运行 / 构建

flake 内部已经开了 `allowUnfree`，不需要额外设置：

```console
$ nix run github:laishulu/nur-packages#cmcc-jtydn
$ nix build github:laishulu/nur-packages#cmcc-jtydn
$ nix run github:laishulu/nur-packages#baidunetdisk
```

### 本地检出 / 传统方式

```console
$ git clone https://github.com/laishulu/nur-packages && cd nur-packages
$ nix run .#cmcc-jtydn
$ nix-build -A cmcc-jtydn
$ nix-build -A baidunetdisk --arg pkgs 'import <nixpkgs> { config.allowUnfree = true; }'
$ nix-shell -A cmcc-jtydn
```

### 自己把本仓库挂进 NUR 的情况

有些配置会自己写一层 overlay 把本仓库挂到 `nur.repos.<名字>` 下，例如：

```nix
nur = prev.nur // {
  repos = prev.nur.repos // {
    laishulu = import inputs.nur-laishulu { pkgs = prev; };
  };
};
```

只有这样才有 `pkgs.nur.repos.laishulu.cmcc-jtydn`（以及
`pkgs.nur.repos.laishulu.modules.cmcc-jtydn-usb`，注意是 `modules`，不是 flake 输出名
`nixosModules`）。模块的 `package` 选项会依次找 `pkgs.cmcc-jtydn` 和
`pkgs.nur.repos.laishulu.cmcc-jtydn`，都不用显式指定。

## 维护

- 更新 nixpkgs：`nix flake update`，然后 `nix flake check`。
- 如果哪天这个仓库被 NUR 收录了，推送后想让它立刻感知：
  `curl -XPOST "https://nur-update.nix-community.org/update?repo=laishulu"`。
- CI 会按 `ci.nix` 只构建可自由分发（`license.free`）且可缓存的包；`cmcc-jtydn` 和
  `baidunetdisk` 因为 unfree 不会进 CI，需要用户本地构建，这是预期行为。

## 许可证

本仓库的打包脚本以 MIT 发布（见 [`LICENSE`](./LICENSE)）。打包进去的第三方软件保留其
原始许可：`font-sarasa-nerd` 为 OFL，`cmcc-jtydn` 为中国移动的专有软件，`baidunetdisk`
为百度的专有软件，本仓库不分发它们的二进制，只在构建时从厂商端点下载。
