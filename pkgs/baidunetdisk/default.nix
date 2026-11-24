{
  # baidunetdisk — Baidu Netdisk (百度网盘) Linux client, unpacked from the
  # vendor .deb and run inside a buildFHSEnv.
  #
  # The client is a prebuilt Electron 22 application with a pile of vendor
  # shared objects next to it (libbrowserengine, libkernel, libdls, ...); there
  # is no source to build, so this package only unpacks the .deb and wraps it.
  # Everything that expects a normal FHS layout (glibc loader, gtk3, gtk2,
  # nss, ...) comes from the buildFHSEnv sandbox, which keeps the unpatched
  # vendor binaries working.
  lib,
  pkgs,
}:

let
  # Only `pkgs` is taken as an argument: the repository is evaluated against
  # several channels (NUR uses nixpkgs-unstable, the CI matrix also builds with
  # older releases), and individual attribute names move between releases -- a
  # plain `{ gtk3, ... }:` argument list simply fails to evaluate on a channel
  # where one of them is missing.
  inherit (pkgs) stdenv fetchurl dpkg buildFHSEnv bash runCommand;

  # The download endpoint is maintained by the vendor; the hash pins the exact
  # build.  If Baidu publishes a new version the hash mismatch fails the build
  # on purpose -- bump `version` and `hash` together.  The 4.17.7 line (the one
  # the download page still links) is the old Electron 11 client; the 8.x line
  # is what the vendor actually ships now.
  # Download page: https://pan.baidu.com/download
  version = "8.9.7";

  src = fetchurl {
    name = "baidunetdisk_${version}_amd64.deb";
    url = "https://issuecdn.baidupcs.com/issue/netdisk/LinuxGuanjia/${version}/baidunetdisk_${version}_amd64.deb";
    hash = "sha256-bApd9P6Q9/GqXgfppwROPk0bbMqnvqvcH3+cwl+jsxw=";
  };

  # Packages of the FHS sandbox, taken by attribute name so that the ones a
  # given nixpkgs does not provide are skipped instead of breaking evaluation.
  available = p: names: map (n: builtins.getAttr n p)
    (builtins.filter (n: builtins.hasAttr n p) names);

  # gtk2 is marked for removal in current nixpkgs (its last release was 2020),
  # and simply evaluating it aborts.  The vendor's libbrowserengine.so is built
  # against the GTK2 C++ bindings and there is no way to relink a proprietary
  # blob, so the marker is cleared locally instead of patching the client.  The
  # build itself is unaffected -- nixpkgs still carries the GTK2 sources and
  # builds them from the binary cache.
  gtk2 = pkgs.gtk2.overrideAttrs (old: {
    meta = builtins.removeAttrs old.meta [ "problems" ];
  });

  # The gtkmm2 binding itself is gone from nixpkgs, so it is built here from
  # the old expression (see ./gtkmm2.nix).
  gtkmm2 = pkgs.callPackage ./gtkmm2.nix { inherit gtk2; };

  # Runtime libraries of the FHS sandbox.  Collected from the .deb's control
  # file, the NEEDED entries of the Electron binary and of the vendor .so files,
  # plus the usual Chromium runtime (GPU, audio, printing, accessibility).
  runtimeLibs = [
    # Electron / Chromium runtime
    "gtk3"
    "glib"
    "nss"
    "nspr"
    "atk"
    "at-spi2-atk"
    "at-spi2-core"
    "cairo"
    "pango"
    "gdk-pixbuf"
    "expat"
    "fontconfig"
    "freetype"
    "libdrm"
    "libgbm"
    "alsa-lib"
    "cups"
    "dbus"
    "libxcb"
    "libxkbcommon"
    "libX11"
    "libXcomposite"
    "libXdamage"
    "libXext"
    "libXfixes"
    "libXrandr"
    "libXrender"
    "libXcursor"
    "libXi"
    "libXinerama"
    "libXau"
    "libXdmcp"
    "libXt"
    "libXmu"
    "libXpm"
    "libglvnd"
    "mesa"
    "vulkan-loader"
    # VA-API: `mesa` only ships the radeon/nouveau/virtio/d3d12 drivers.  Intel
    # hardware needs iHD_drv_video.so from intel-media-driver, otherwise libva
    # finds no driver at all and Chromium logs "vaGetDriverNames() failed".
    "libva"
    "intel-media-driver"
    # `vainfo` for the --check-vaapi self-check below.
    "libva-utils"
    "wayland"
    "pciutils"
    "libpulseaudio"
    "libsecret"
    "libnotify"
    "libkrb5"
    "udev"
    "libappindicator"
    "libXtst"
    "libXScrnSaver"
    "zlib"
    "libpng"
    "harfbuzz"
    "libthai"
    "fribidi"
    "libdatrie"
    "pcre2"
    "libffi"

    # Tools the client shells out to (`xdg-open` for opening download folders,
    # `stat`/`ps` in the vendor's helper scripts), plus what the --check-libs
    # self-check itself needs.
    "xdg-utils"
    "procps"
    "util-linux"
    "coreutils"
    "gnugrep"

    # Icon/settings data so file dialogs and the tray do not render blank.
    "shared-mime-info"
    "gsettings-desktop-schemas"
    "hicolor-icon-theme"

    # GTK2 stack: gtk2 itself is passed separately (see above), these are the
    # C++ bindings and their immediate runtime dependencies.
    "glibmm_2_4"
    "cairomm_1_0"
    "pangomm_1_4"
    "atkmm"
    "libsigcxx_2_0"
  ];

  # Small helper: render a bash script with an explicit interpreter path, so it
  # does not rely on /bin/bash existing on the target system.
  mkScript = { name, text }: runCommand name { } ''
    mkdir -p "$out/bin"
    cat > "$out/bin/${name}" <<'SCRIPT_EOF'
#!${bash}/bin/bash
${text}
SCRIPT_EOF
    chmod 755 "$out/bin/${name}"
  '';

  # Unpack the .deb once.  The output keeps the vendor layout:
  #   $out/opt/baidunetdisk/...          (Electron app, native addons, asar)
  #   $out/share/icons/.../baidunetdisk.svg
  app = stdenv.mkDerivation {
    pname = "baidunetdisk-unpacked";
    inherit version src;

    nativeBuildInputs = [ dpkg ];

    # dpkg-deb -x is exactly what the postinst would put under /opt; all
    # maintainer-script side effects (desktop database, DDE file-manager
    # entries, mimeapps.list edits) are skipped.
    unpackPhase = ''
      runHook preUnpack
      mkdir -p unpacked
      dpkg-deb -x "$src" unpacked
      runHook postUnpack
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/opt"
      cp -a unpacked/opt/baidunetdisk "$out/opt/"
      mkdir -p "$out/share/icons/hicolor/scalable/apps"
      cp unpacked/usr/share/icons/hicolor/scalable/apps/baidunetdisk.svg \
         "$out/share/icons/hicolor/scalable/apps/baidunetdisk.svg"
      runHook postInstall
    '';

    # Do not touch the vendor ELFs: they are unpatched on purpose and run inside
    # the FHS sandbox below.  The app also keeps its own asar/update files
    # byte-identical, so no fixup hook may rewrite anything.
    dontStrip = true;
    dontPatchELF = true;
    dontBuild = true;
    dontFixup = true;
  };

  # Runs *inside* the FHS sandbox.
  inner = mkScript {
    name = "baidunetdisk-inner";
    text = ''
      set -eu

      appdir="${app}/opt/baidunetdisk"

      # `baidunetdisk --check-libs` runs ldd over the main binaries and every
      # vendor .so and prints what is still missing.  Missing libraries are the
      # only thing this wrapper can get wrong, so this turns a round of trial
      # and error into one command.
      if [ "''${1:-}" = "--check-libs" ]; then
        shift
        status=0
        for f in "$appdir/baidunetdisk" "$appdir"/baidunetdiskhost \
                 "$appdir"/netdisk_service "$appdir"/chrome_crashpad_handler \
                 "$appdir"/*.so; do
          [ -f "$f" ] || continue
          # Skip non-ELF files (configs, .pak, .json, ...).
          if [ "$(head -c 4 "$f" 2>/dev/null)" != "$(printf '\177ELF')" ]; then
            continue
          fi
          report="$(ldd "$f" 2>/dev/null | grep 'not found' || true)"
          if [ -n "$report" ]; then
            echo "== $f"
            echo "$report"
            status=1
          fi
        done
        if [ "$status" = 0 ]; then
          echo "baidunetdisk: no missing shared libraries"
        fi
        exit "$status"
      fi

      # `baidunetdisk --check-vaapi` prints libva's view of the hardware: the
      # driver that gets loaded and the decode profiles it offers.  The X11
      # backend prints a non-fatal "vaGetDriverNames() failed" line before the
      # driver line; that is libva's own bookkeeping, not a missing driver.
      if [ "''${1:-}" = "--check-vaapi" ]; then
        shift
        exec vainfo "$@"
      fi

      if [ ! -x "$appdir/baidunetdisk" ]; then
        echo "baidunetdisk: $appdir/baidunetdisk not found" >&2
        exit 1
      fi

      # The .deb relies on a setuid chrome-sandbox (chmod 4755 in its postinst);
      # a setuid binary cannot live in the Nix store, so the Chromium sandbox is
      # disabled -- the vendor's own .desktop entry does the same.
      exec "$appdir/baidunetdisk" --no-sandbox "$@"
    '';
  };

  fhs = buildFHSEnv {
    name = "baidunetdisk-fhs";

    # `glibc.bin` brings /usr/bin/ldd for the --check-libs self-check.
    targetPkgs = p: available p runtimeLibs ++ [ gtk2 gtkmm2 p.glibc.bin ];

    # The D-Bus session bus socket lives under /run/user/$UID; the sandbox has
    # its own /run, so without this bind the client cannot reach the portal,
    # notification and tray services and logs "A connection to the bus can't be
    # made".
    #
    # A private /dev/shm keeps the vendor's fixed-name objects
    # (`sem.baidu_netdisk_service_mutex`, `netdisk_unite_message_queue`) inside
    # the sandbox.  They are system-wide on the host: netdisk_service opens the
    # existing semaphore with O_RDWR, and a leftover owned by another user
    # cannot be opened (nor unlinked, /dev/shm is sticky), so the service dies
    # with an uncaught boost::interprocess_exception -- "Permission denied".
    extraBwrapArgs = [
      "--bind-try" "/run/user" "/run/user"
      "--tmpfs" "/dev/shm"
    ];

    runScript = "${inner}/bin/baidunetdisk-inner";
  };

  package = stdenv.mkDerivation {
    pname = "baidunetdisk";
    inherit version;

    dontUnpack = true;
    dontBuild = true;
    dontStrip = true;

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/bin" "$out/share/applications" \
               "$out/share/icons/hicolor/scalable/apps"

      # The vendor .desktop file hardcodes Exec=/opt/baidunetdisk/baidunetdisk;
      # ours points at the wrapper instead.
      cat > "$out/bin/baidunetdisk" <<'EOF'
#!${bash}/bin/bash
exec "${fhs}/bin/baidunetdisk-fhs" "$@"
EOF
      chmod 755 "$out/bin/baidunetdisk"

      cp ${app}/share/icons/hicolor/scalable/apps/baidunetdisk.svg \
         "$out/share/icons/hicolor/scalable/apps/baidunetdisk.svg"

      cat > "$out/share/applications/baidunetdisk.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Baidu Netdisk
Name[zh_CN]=百度网盘
Name[zh_TW]=百度網盤
Comment=Baidu Netdisk client (百度网盘 Linux client)
Comment[zh_CN]=百度网盘客户端
Exec=baidunetdisk %U
Icon=baidunetdisk
Terminal=false
Categories=Network;FileTransfer;
MimeType=x-scheme-handler/baiduyunguanjia;
StartupWMClass=baidunetdisk
EOF
      chmod 644 "$out/share/applications/baidunetdisk.desktop"

      runHook postInstall
    '';

    meta = {
      description = "Baidu Netdisk client (百度网盘 Linux client, Electron)";
      homepage = "https://pan.baidu.com/download";
      license = lib.licenses.unfree;
      platforms = [ "x86_64-linux" ];
      mainProgram = "baidunetdisk";
      sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    };
  };
in
package
