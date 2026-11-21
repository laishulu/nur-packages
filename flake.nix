{
  description = "laishulu NUR repository (fonts and misc packages)";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  outputs = { self, nixpkgs }:
    let
      forAllSystems = nixpkgs.lib.genAttrs nixpkgs.lib.systems.flakeExposed;
    in
    {
      legacyPackages = forAllSystems (system: import ./default.nix {
        # cmcc-jtydn is unfree; without this the whole `nix flake check` fails
        # instead of only hiding that one package.  Overlay consumers keep their
        # own nixpkgs policy.
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };
      });
      packages = forAllSystems (system: nixpkgs.lib.filterAttrs
        (_: v: nixpkgs.lib.isDerivation v)
        self.legacyPackages.${system});
      # The whole package set as an overlay.  The definition lives in
      # overlays/default.nix (that is also what NUR shows as
      # `nur.repos.laishulu.overlays.default`), the root overlay.nix is a thin
      # re-export for non-flake use.
      overlays.default = (import ./overlays).default;
    };
}
