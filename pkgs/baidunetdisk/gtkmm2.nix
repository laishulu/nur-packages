# gtkmm 2.24.5 — the C++ binding for GTK2.
#
# nixpkgs still has GTK2 itself (`pkgs.gtk2`), but dropped the gtkmm2 binding in
# 2026 together with the other GTK2-era C++ wrappers.  The Baidu client's
# `libbrowserengine.so` is linked against libgtkmm-2.4.so.1 / libgdkmm-2.4.so.1
# and the app's own JS bundle dlopen()s a library that needs them, so the
# binding has to come from somewhere; this is the old nixpkgs expression,
# unchanged apart from the dependencies that moved to versioned attribute names
# (`glibmm_2_4`, `cairomm_1_0`, `pangomm_1_4`).
{ lib, stdenv, fetchurl, pkg-config, gtk2, glibmm_2_4, cairomm_1_0, pangomm_1_4, atkmm }:

stdenv.mkDerivation {
  pname = "gtkmm";
  version = "2.24.5";

  src = fetchurl {
    url = "mirror://gnome/sources/gtkmm/2.24/gtkmm-2.24.5.tar.xz";
    hash = "sha256-BoClO3v5C05L9ETR2J5t9Bx3fgusyW6cCfxN0vX+a3I=";
  };

  outputs = [ "out" "dev" ];

  nativeBuildInputs = [ pkg-config ];

  propagatedBuildInputs = [ glibmm_2_4 gtk2 atkmm cairomm_1_0 pangomm_1_4 ];

  enableParallelBuilding = true;

  # The test programs need a display and only exercise GTK itself; there is
  # nothing here that a headless build could learn from them.
  doCheck = false;

  meta = {
    description = "C++ interface to the GTK2 graphical user interface library";
    homepage = "https://gtkmm.org/";
    license = lib.licenses.lgpl2Plus;
    platforms = lib.platforms.unix;
  };
}
