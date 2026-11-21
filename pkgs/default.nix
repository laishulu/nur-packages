{ pkgs }:

let
  inherit (pkgs) lib;

  # NUR evaluates every repository with a strict `pkgs` (`allowUnfree = false`).
  # An unfree derivation there makes the evaluation of the *whole* repository
  # fail, which would keep it out of NUR entirely -- so the attribute is only
  # exposed when the caller allows unfree packages.  Consumers that do get the
  # package through the overlay or the flake.
  exposeUnfree = pkgs.config.allowUnfree or false;
in
{
  font-sarasa-nerd = pkgs.callPackage ./font-sarasa-nerd { };
}
// lib.optionalAttrs (pkgs.stdenv.hostPlatform.isx86_64 && exposeUnfree) {
  # The client is a vendored 64-bit Debian/Electron binary; on other hosts there
  # is nothing that could be built, so the attribute is simply absent there
  # instead of being a derivation that always fails.
  cmcc-jtydn = pkgs.callPackage ./cmcc-jtydn { };
}
