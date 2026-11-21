# Convenience file for `nixpkgs.overlays = [ (import ./overlay.nix) ];`.
#
# The actual definition lives in overlays/default.nix, which is also what NUR
# exposes as `nur.repos.<name>.overlays.default` and what the repository flake
# re-exports, so both entry points stay in sync.
(import ./overlays).default
