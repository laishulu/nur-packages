# Named overlays of this repository.
#
# `nur.repos.<name>.overlays.<overlay-name>` exposes this attribute set, and the
# repository flake re-exports `overlays.default` from here, so there is exactly
# one implementation.  The argument names must be `final` and `prev`, otherwise
# `nix flake check` rejects the overlay.
{
  # The whole package set of this repository, applied as an overlay.  Only the
  # non-reserved attributes (`lib`, `modules`, `overlays` are reserved by NUR)
  # are copied into the package set.
  default = final: prev:
    let
      isReserved = n: n == "lib" || n == "overlays" || n == "modules";
      nameValuePair = n: v: { name = n; value = v; };
      nurAttrs = import ../default.nix { pkgs = prev; };
    in
    builtins.listToAttrs
      (map (n: nameValuePair n nurAttrs.${n})
        (builtins.filter (n: !isReserved n)
          (builtins.attrNames nurAttrs)));
}
