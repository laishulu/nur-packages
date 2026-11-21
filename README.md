# nur-packages

[laishulu](https://github.com/laishulu) 的个人 [NUR](https://github.com/nix-community/NUR) 仓库。

## 包

| 属性 | 说明 | 平台 | 许可 |
| --- | --- | --- | --- |
| `font-sarasa-nerd` | Sarasa Term SC Nerd 字体 | 全平台 | OFL |
| `cmcc-jtydn` | 中国移动云电脑客户端（家庭云电脑 / 川云 VDI，2.23.1） | `x86_64-linux` | 专有（unfree） |

`cmcc-jtydn` 是打包好的厂商二进制：`nix build` 会下载厂商 `.deb`（约 235 MB）并组装一个
`buildFHSEnv`，第一次运行再把客户端复制成 1.1 GB 的可写副本。细节、依赖和已知限制见
[`pkgs/cmcc-jtydn/README.md`](./pkgs/cmcc-jtydn/README.md) 与
[`pkgs/cmcc-jtydn/ANALYSIS.md`](./pkgs/cmcc-jtydn/ANALYSIS.md)。

## 用法

### NUR（推荐）

在 `configuration.nix` 里启用 NUR 后：

```nix
{ pkgs, ... }:
{
  nixpkgs.config.allowUnfree = true;   # cmcc-jtydn 是专有软件
  environment.systemPackages = [ pkgs.nur.repos.laishulu.cmcc-jtydn ];
}
```

`cmcc-jtydn` 这个属性只有在 `allowUnfree` 打开时才会出现（否则整个属性省略）。
这是给 NUR 用的：NUR 评估每个仓库时用的是 `allowUnfree = false` 的 `pkgs`，仓库里若有
unfree 派生，会让**整个仓库**的评估失败；省略它反而能正常收录。flake 内部已经开了
`allowUnfree`，所以 `nix flake check` / `nix run .#cmcc-jtydn` 照常可用。

### flake

```nix
{
  inputs.nur-packages.url = "github:laishulu/nur-packages";

  outputs = { self, nixpkgs, nur-packages, ... }: {
    nixosConfigurations.host = nixpkgs.lib.nixosSystem {
      modules = [{
        nixpkgs.overlays = [ nur-packages.overlays.default ];
        environment.systemPackages = [ pkgs.cmcc-jtydn ];
      }];
    };
  };
}
```

### 传统方式

```console
$ nix-build -A cmcc-jtydn
$ nix-shell -A cmcc-jtydn
```

## 维护

- 更新 nixpkgs：`nix flake update`，然后 `nix flake check`。
- 推送后想让 NUR 立刻感知：`curl -XPOST "https://nur-update.nix-community.org/update?repo=laishulu"`。
- CI 会按 `ci.nix` 只构建可自由分发（`license.free`）且可缓存的包；`cmcc-jtydn` 因为
  unfree 不会进 CI，需要用户本地构建，这是预期行为。

## 许可证

本仓库的打包脚本以 MIT 发布（见 [`LICENSE`](./LICENSE)）。打包进去的第三方软件保留其
原始许可：`font-sarasa-nerd` 为 OFL，`cmcc-jtydn` 为中国移动的专有软件，本仓库不分发其二进制，
只在构建时从厂商端点下载。
