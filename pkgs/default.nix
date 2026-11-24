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
// lib.optionalAttrs (pkgs.stdenv.hostPlatform.isx86_64 && exposeUnfree
  # Same situation: a prebuilt amd64 Electron client from a vendor .deb.  On
  # top of that it needs the GTK2 C++ stack, whose attribute names moved to
  # versioned forms (`glibmm_2_4`, ...) in 2026; on an older channel those names
  # do not exist yet, so the attribute is absent there instead of making the
  # whole repository fail to evaluate.
  && lib.all (n: lib.hasAttr n pkgs) [
    "gtk2"
    "glibmm_2_4"
    "cairomm_1_0"
    "pangomm_1_4"
    "atkmm"
    "libsigcxx_2_0"
  ]) {
  baidunetdisk = pkgs.callPackage ./baidunetdisk { };
}
