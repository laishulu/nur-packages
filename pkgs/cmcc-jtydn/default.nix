{
  # cmcc-jtydn — China Mobile Cloud PC (家庭云电脑) UOS/Linux client, unpacked
  # from the vendor .deb and run inside a buildFHSEnv.
  #
  # The vendor ships a prebuilt Electron 22 application; there is no source to
  # build, so this package only unpacks the .deb and wraps it.  Everything that
  # needs a normal FHS layout (glibc loader, gtk3, nss, ...) comes from the
  # buildFHSEnv sandbox, which keeps the unpatched vendor binaries working.
  lib,
  pkgs,
}:

let
  # Only `pkgs` is taken as an argument: the repository is evaluated against
  # several channels (NUR uses nixpkgs-unstable, the CI matrix also builds with
  # nixos-24.05), and individual attribute names move between releases -- a
  # plain `{ libgbm, ... }:` list simply fails to evaluate on an older channel.
  inherit (pkgs) stdenv fetchurl dpkg buildFHSEnv bash runCommand coreutils perl
    gawk util-linux;

  # xrdb/xrandr only became top-level attributes after 24.05; on the channels
  # where they are absent they still exist under `xorg`.  A plain
  # `inherit (pkgs) xrdb` aborts the evaluation of the whole repository on
  # those channels, which is exactly what the CI matrix hits.
  xrdb = pkgs.xrdb or pkgs.xorg.xrdb;
  xrandr = pkgs.xrandr or pkgs.xorg.xrandr;

  # Packages of the FHS sandbox, taken by attribute name so that the ones a
  # given nixpkgs does not provide are skipped instead of breaking evaluation
  # (`libgbm` for instance only became a top-level attribute after 24.05).
  available = p: names: map (n: builtins.getAttr n p)
    (builtins.filter (n: builtins.hasAttr n p) names);

  version = "2.23.1";

  deps = import ./deps.nix { inherit lib stdenv fetchurl dpkg perl version; };
  inherit (deps) openssl11 debianLibs;

  shims = import ./shims.nix { inherit pkgs stdenv version; };
  inherit (shims) keyboardFix displayFix;

  # The download endpoint is a "latest" short link maintained by the vendor; the
  # hash pins the exact build.  If the vendor publishes a new version the hash
  # mismatch fails the build on purpose — bump `version` and `hash` together.
  # Human-readable download page: https://soho.komect.com/clientDownload
  src = fetchurl {
    name = "CMCC-JTYDN-UOSx86-${version}.deb";
    url = "https://dl.soho.komect.com/upgrade/download/app/ad2bcdde85d84d6a";
    hash = "sha256-ZfpaCT1zv+9AcwSzLtRaHHYdSxBevc+i/+pn6d51EgI=";
  };

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

  # Both wrappers (the client and the USB daemon) need the same three-layer
  # library search: FHS first, then the Debian 10 sonames the FHS lacks, then
  # the vendor bundle.  The first two layers are symlink mirrors, so this script
  # builds them once per state directory and caches the result; the caller gets
  # "<fhs>:<debian>" on stdout and appends its own vendor directories.
  libLayers = mkScript {
    name = "cmcc-jtydn-lib-layers";
    text = ''
      set -eu
      state="''\${1:?usage: cmcc-jtydn-lib-layers <state-dir>}"
      fhs_libs="$state/.fhs-libs"
      deb_libs="$state/.debian-libs"

      # The mirror is only valid for the sandbox it was built in; a client
      # upgrade or a different nixpkgs changes the listing.
      sig="$({
        for libdir in /usr/lib /usr/lib64 /lib /lib64; do
          [ -d "$libdir" ] || continue
          printf '%s\n' "$libdir"
          ls -1 "$libdir" 2>/dev/null || true
        done
      } | ${coreutils}/bin/cksum)"

      if [ -f "$state/.libs-sig" ] && [ -d "$fhs_libs" ] && [ -d "$deb_libs" ] \
         && [ "$(${coreutils}/bin/cat "$state/.libs-sig")" = "$sig" ]; then
        printf '%s:%s\n' "$fhs_libs" "$deb_libs"
        exit 0
      fi

      rm -rf "$fhs_libs" "$deb_libs"
      mkdir -p "$fhs_libs" "$deb_libs"
      for libdir in /usr/lib /usr/lib64 /lib /lib64; do
        [ -d "$libdir" ] || continue
        for f in "$libdir"/*.so*; do
          [ -e "$f" ] || continue
          b="''\${f##*/}"
          [ -e "$fhs_libs/$b" ] || ln -s "$f" "$fhs_libs/$b"
        done
      done
      # Keep only the Debian sonames the FHS does not provide: a buster library
      # duplicating a nixpkgs one (libharfbuzz.so.0) would drag in its own
      # buster chain (libgraphite2, libicu63, ...).
      for f in /debian-libs/lib/*.so*; do
        [ -e "$f" ] || continue
        b="''\${f##*/}"
        [ -e "$fhs_libs/$b" ] && continue
        ln -s "$f" "$deb_libs/$b"
      done
      printf '%s' "$sig" > "$state/.libs-sig"
      printf '%s:%s\n' "$fhs_libs" "$deb_libs"
    '';
  };

  # Unpack the .deb once.  The output keeps the vendor layout:
  #   $out/opt/chuanyun-vdi-client/...      (Electron app + native addons)
  #   $out/share/icons/.../cmcc-jtydn.png
  app = stdenv.mkDerivation {
    pname = "cmcc-jtydn-unpacked";
    inherit version src;

    nativeBuildInputs = [ dpkg ];

    # dpkg-deb -x is exactly what the postinst would put under /opt; we skip all
    # maintainer-script side effects (setuid, setcap, udev, systemd).
    unpackPhase = ''
      runHook preUnpack
      mkdir -p unpacked
      dpkg-deb -x "$src" unpacked
      runHook postUnpack
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/opt"
      cp -a unpacked/opt/chuanyun-vdi-client "$out/opt/"
      mkdir -p "$out/share/icons/hicolor/256x256/apps"
      cp unpacked/usr/share/icons/hicolor/0x0/apps/cmcc-jtydn.png \
         "$out/share/icons/hicolor/256x256/apps/cmcc-jtydn.png"
      runHook postInstall
    '';

    # Do not touch the vendor ELFs: they are unpatched on purpose and run inside
    # the FHS sandbox below.
    dontStrip = true;
    dontPatchELF = true;
    dontBuild = true;
    # Keep the vendor tree byte-identical: no patchShebangs rewrites either.
    dontFixup = true;
  };

  # Runs *inside* the FHS sandbox.  The writable copy of the client lives under
  # $XDG_DATA_HOME (prepared by the launcher below), so the app can keep writing
  # to its own resources/.../config and logs directories like on a normal distro.
  inner = mkScript {
    name = "cmcc-jtydn-inner";
    text = ''
      set -eu

      state="''${XDG_DATA_HOME:-$HOME/.local/share}/cmcc-jtydn/${version}/app"
      addon="$state/resources/app.asar.unpacked/node_modules/chuanyunAddOn/ccsdk/uos"
      netdetect="$state/resources/app.asar.unpacked/node_modules/netdetectAddOn/ntsdk"
      qoe_dir="$state/resources/app.asar.unpacked/node_modules/chuanyunAddOn-zte/ccsdk"

      # Library search precedence, first match wins:
      #
      #   1. the FHS sandbox (nixpkgs: current glibc, gtk3, X11, our OpenSSL 1.1)
      #   2. Debian 10 libraries for the sonames nixpkgs dropped long ago
      #      (libjpeg.so.8, libx264.so.155, libaom.so.0, ...)
      #   3. the vendor bundle (Qt 5.12, FFmpeg 58, GStreamer, ICU)
      #
      # The vendor directory used to come first.  That is what made the client
      # die with "version `GLIBC_2.x' not found": its libm/libmount/libpcre2
      # are older than the FHS ones and shadowed them for every consumer.
      #
      # The FHS libraries are not on this path at all, they are found through
      # the sandbox's ld cache -- so they are mirrored into a directory that is
      # placed in front, giving an explicit order instead of relying on
      # "LD_LIBRARY_PATH beats ld.so.cache".
      # Layers 1+2 are symlink mirrors built (and cached) by the shared helper,
      # so both wrappers get the same order:
      libpath="$("${libLayers}/bin/cmcc-jtydn-lib-layers" "$state")"
      if [ -d "$addon/lib" ]; then
        libpath="$libpath:$addon/lib"
      fi
      if [ -d "$netdetect/lib" ]; then
        libpath="$libpath:$netdetect/lib"
      fi
      export LD_LIBRARY_PATH="$libpath''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

      if [ -d "$addon/lib" ]; then
        # Plugin directories are dlopen()ed, not linked against, so they are
        # safe to point at the vendor tree even though the libs above are not.
        export GST_PLUGIN_PATH="$addon/lib''${GST_PLUGIN_PATH:+:$GST_PLUGIN_PATH}"
        export GST_PLUGIN_PATH_1_0="$addon/lib''${GST_PLUGIN_PATH_1_0:+:$GST_PLUGIN_PATH_1_0}"
        export CY_BIN_PATH="$addon/bin"
      fi

      # `iw` and friends are installed into /usr/sbin inside the sandbox; make
      # sure helpers that shell out to them find them even with a minimal PATH.
      export PATH="''${PATH:-/usr/bin:/bin}:/usr/sbin:/sbin"
      # Self-check: `cmcc-jtydn --check-libs` runs ldd over the main binary and
      # every vendor helper and prints the libraries that are still missing.
      # Missing libraries are the only thing this wrapper can get wrong, so this
      # turns a round of trial and error into one command.
      if [ "''${1:-}" = "--check-libs" ]; then
        shift
        status=0
        for f in "$state/cmcc-jtydn" "$addon"/bin/* "$netdetect"/bin/* "$qoe_dir"/bin/*; do
          [ -f "$f" ] || continue
          # Skip non-ELF files (shell helpers, configs).
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
          echo "cmcc-jtydn: no missing shared libraries"
        fi
        exit "$status"
      fi

      if [ ! -x "$state/cmcc-jtydn" ]; then
        echo "cmcc-jtydn: writable copy not found at $state" >&2
        echo "cmcc-jtydn: run the 'cmcc-jtydn' launcher instead of this script" >&2
        exit 1
      fi

      cd "$state"

      # Two LD_PRELOAD shims, both only for this process tree:
      #   keyboardFix - keysym lookups of modifier keys (see above);
      #   displayFix  - never asks the guest to grow past its own resolution
      #                 (see above).
      preload=""
      if [ "''${CMCC_NO_KB_FIX:-0}" != 1 ]; then
        preload="${keyboardFix}/lib/libcmcc-kbd.so"
      fi
      if [ "''${CMCC_NO_DISPLAY_FIX:-0}" != 1 ]; then
        preload="''${preload:+$preload:}${displayFix}/lib/libcmcc-display.so"
      fi
      if [ -n "$preload" ]; then
        export LD_PRELOAD="$preload''${LD_PRELOAD:+:$LD_PRELOAD}"
      fi

      # Qt 5.12 here is not scale-aware: on a HiDPI screen it sees the physical
      # size (e.g. 3840x2160) and asks the guest for it, which some cloud PCs
      # cannot drive (black screen).  A scale-aware client would ask for the
      # *logical* size, so cap the request at physical * 96 / Xft.dpi.  Only the
      # SPICE request is affected; the local UI keeps its own rendering.
      if [ "''${CMCC_NO_DISPLAY_FIX:-0}" != 1 ] && [ -z "''${CMCC_MAX_DISPLAY:-}" ]; then
        max_dpi="$(${xrdb}/bin/xrdb -query 2>/dev/null \
          | ${gawk}/bin/awk -F':[[:space:]]*' '/^Xft[.]dpi/ { print $2; exit }')"
        max_geom="$(${xrandr}/bin/xrandr --current 2>/dev/null \
          | ${gawk}/bin/awk '/ connected/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+x[0-9]+/) { print $i; exit } }')"
        max_geom="''${max_geom%%+*}"
        case "''${max_dpi%%.*}" in
          *[!0-9]* | "") max_dpi=96 ;;
          *) max_dpi="''${max_dpi%%.*}" ;;
        esac
        case "$max_geom" in
          [0-9]*x[0-9]*)
            if [ "$max_dpi" -gt 96 ]; then
              max_w="$(${gawk}/bin/awk -v v="''${max_geom%%x*}" -v d="$max_dpi" \
                'BEGIN { printf "%d", v * 96 / d }')"
              max_h="$(${gawk}/bin/awk -v v="''${max_geom##*x}" -v d="$max_dpi" \
                'BEGIN { printf "%d", v * 96 / d }')"
              export CMCC_MAX_DISPLAY="''${max_w}x''${max_h}"
            fi
            ;;
        esac
      fi

      # The ZTE branches ship a QoE agent that upstream starts from a systemd
      # unit (`zqoe.service`) with absolute /opt paths.  Without it the client
      # logs "connect ECONNREFUSED /tmp/my.sock" forever and reports no network
      # quality.  It is started here directly instead of through the vendor's
      # monitor_qoe.sh: that script is a `while true` loop which respawns the
      # agent every five seconds, so closing the client left a process tree that
      # was impossible to get rid of.  Set CMCC_NO_QOE=1 to leave it off.
      qoe_pid=""
      if [ "''${CMCC_NO_QOE:-0}" != 1 ] && [ -x "$qoe_dir/bin/QoEAgent" ]; then
        mkdir -p "$qoe_dir/log"
        ( cd "$qoe_dir/bin" && exec ./QoEAgent >/dev/null 2>&1 ) &
        qoe_pid=$!
        sleep 1
      fi

      # The client runs as a child rather than through `exec`, so that the agent
      # can be cleaned up afterwards; termination signals are forwarded to it,
      # otherwise killing the wrapper would leave Electron running.
      #
      # The .deb relies on a setuid chrome-sandbox (chmod 4755 in its postinst);
      # a setuid binary cannot live in the Nix store, so the Chromium sandbox is
      # disabled.  With unprivileged user namespaces enabled the app still gets
      # the namespace sandbox, only the SUID helper is skipped.
      "$state/cmcc-jtydn" \
        --no-sandbox \
        --disable-setuid-sandbox \
        "$@" &
      app_pid=$!

      forward_term() {
        kill -TERM "$app_pid" 2>/dev/null || true
      }
      trap forward_term INT TERM HUP

      set +e
      wait "$app_pid"
      rc=$?
      set -e
      trap - INT TERM HUP

      if [ -n "$qoe_pid" ]; then
        kill -TERM "$qoe_pid" 2>/dev/null || true
        sleep 1
        kill -KILL "$qoe_pid" 2>/dev/null || true
        # In case the agent forked itself away from the pid we started.
        pkill -f "$qoe_dir/bin/QoEAgent" 2>/dev/null || true
      fi

      exit "$rc"
    '';
  };

  # Runtime libraries shared by everything in the vendor tree: the Electron
  # app, the Qt viewer and the USB/IP daemon are built against the same UOS
  # stack, so both FHS sandboxes below start from this list.
  clientLibs = [
      # Runtime deps declared in the .deb's control file
      "gtk3"
      "glib"
      "nss"
      "nspr"
      "libnotify"
      "libXScrnSaver"
      "libXtst"
      "xdg-utils"
      "at-spi2-atk"
      "libuuid"
      "libsecret"

      # Remaining Chromium/Electron and GTK stack requirements.
      # `mesa` alone does not provide libgbm.so.1 — that one lives in a separate
      # output, so it has to be listed explicitly or Electron dies at startup
      # with "error while loading shared libraries: libgbm.so.1".
      "alsa-lib"
      "at-spi2-core"
      "atk"
      "cairo"
      "cups"
      "dbus"
      "expat"
      "fontconfig"
      "freetype"
      "gdk-pixbuf"
      "libdrm"
      "libgbm"
      "libglvnd"
      "libpng"
      "libpulseaudio"
      "libusb1"
      "libva"
      "libvdpau"
      "libxcrypt"
      "libxkbcommon"
      "libxshmfence"
      "mesa"
      "pango"
      "pcre2"
      # Provide the shaper explicitly: otherwise the loader may pick the Debian
      # 10 libharfbuzz from the fallback layer, which in turn wants libgraphite2
      # and libicu63 -- libraries from that same old generation that are not
      # worth dragging in.
      "harfbuzz"
      "graphite2"
      "icu"
      # nixpkgs libsndfile (pulled in indirectly) needs the current mpg123
      # symbols; without an explicit copy an older libmpg123 from the fallback
      # layers gets picked and the helper dies with
      # "undefined symbol: mpg123_info2".
      "mpg123"
      "udev"
      "vulkan-loader"
      "zlib"
      "libX11"
      "libXcomposite"
      "libXcursor"
      "libXdamage"
      "libXext"
      "libXfixes"
      "libXi"
      "libXrandr"
      "libXrender"
      "libxcb"

      # Used by the native addons (USB redirect / filesystem redirect / QoE)
      "fuse3"

      # The remote-view helper (`ccsdk/uos/bin/chuanyun-view`) is a separate
      # vendor Qt5 process spawned by the app; it needs the X/Qt runtime that
      # Electron itself does not, so these are listed explicitly rather than
      # relying on transitive deps of gtk3.
      "pixman"
      "libwebp"
      "libICE"
      "libSM"
      "libXau"
      "libXdmcp"
      "libXxf86vm"

      # The netdetect addon shells out to `iw` to look at the wireless link.
      "iw"

      # Tools the launcher and the app expect in a normal distro PATH, plus
      # pkill for the QoE agent cleanup on exit.
      "coreutils"
      "procps"
  ];

  fhs = buildFHSEnv {
    name = "cmcc-jtydn-fhs";

    targetPkgs = p: available p clientLibs
    # Not plain attribute names: the locally built OpenSSL 1.1, the Debian 10
    # library set, and `glibc.bin` (ldd for the --check-libs self-check).
    ++ [ debianLibs openssl11 p.glibc.bin ];

    # The Debian 10 libraries are mounted on their own, at /debian-libs, and are
    # only searched after the FHS libraries.  Merging them into /usr/lib would
    # let a buster library replace the nixpkgs one of the same name
    # (libharfbuzz, for example) and pull in the whole buster dependency chain.
    extraBwrapArgs = [ "--ro-bind ${debianLibs} /debian-libs" ];

    runScript = "${inner}/bin/cmcc-jtydn-inner";
  };

  # --- USB redirection ------------------------------------------------------
  #
  # `chuanyun-redirect` (the USB/IP bridge the viewer talks to over the SysV
  # queue from the black-screen fix) is a UOS/glibc-2.31 binary with a Debian
  # interpreter, and the .deb runs it as root from a systemd unit so it can
  # unbind kernel drivers, claim the device through libusbipd and add udev
  # rules.  It therefore gets its own FHS sandbox, started by the systemd
  # service in modules/cmcc-jtydn-usb.nix.
  redirectInner = mkScript {
    name = "cmcc-jtydn-redirect-inner";
    text = ''
      set -eu

      appdir="''${1:?usage: cmcc-jtydn-redirect-inner <vendor-app-dir>}"
      addon="$appdir/resources/app.asar.unpacked/node_modules/chuanyunAddOn/ccsdk/uos"
      [ -x "$addon/bin/chuanyun-redirect" ] || {
        echo "cmcc-jtydn-redirect: $addon/bin/chuanyun-redirect not found" >&2
        exit 1
      }

      # Same layered library search as the client wrapper: the vendor lib dir
      # must not shadow the sandbox's newer glib2/cairo/libm (it is an old UOS
      # layer), so mirror the FHS libraries first, add only the buster sonames
      # the FHS lacks, and let the vendor dir fill the rest.
      # This script runs as root from the systemd unit, so the scratch
      # directory must not live in world-writable /tmp: a user could pre-create
      # /tmp/cmcc-jtydn-redirect (or a symlink inside it) and make root write
      # through it.  /run/cmcc-jtydn is created by RuntimeDirectory and is
      # root-only; a manual non-root run keeps its own XDG_RUNTIME_DIR.
      if [ "$(id -u)" = 0 ]; then
        state=/run/cmcc-jtydn/state
        mkdir -p "$state"
        chmod 700 "$state"
      else
        state="''${XDG_RUNTIME_DIR:-/tmp}/cmcc-jtydn-redirect"
        mkdir -p "$state"
      fi
      libpath="$("${libLayers}/bin/cmcc-jtydn-lib-layers" "$state")"
      export LD_LIBRARY_PATH="$libpath:$addon/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
      export PATH="''${PATH:-/usr/bin:/bin}:/usr/sbin:/sbin"

      cd "$addon/bin"
      exec ./chuanyun-redirect "$@"
    '';
  };

  redirectFhs = buildFHSEnv {
    name = "cmcc-jtydn-redirect-fhs";

    targetPkgs = p: available p clientLibs ++ [ debianLibs ];

    # the vendor tree is read-only, so give the daemon writable state instead
    extraBwrapArgs = [
      "--ro-bind ${debianLibs} /debian-libs"
      "--bind-try /run/cmcc-jtydn/udev /etc/udev/rules.d"
    ];

    runScript = "${redirectInner}/bin/cmcc-jtydn-redirect-inner";
  };

  # Runs as root (systemd unit), from the read-only vendor tree in the store.
  redirect = mkScript {
    name = "cmcc-jtydn-redirect";
    text = ''
      set -eu
      exec "${redirectFhs}/bin/cmcc-jtydn-redirect-fhs" \
        "${app}/opt/chuanyun-vdi-client" "$@"
    '';
  };

  # Launcher that runs outside the sandbox: it materialises a writable copy of
  # the vendor tree (the /opt directory in the .deb is written to at runtime by
  # the addons), then enters the FHS environment.
  client = mkScript {
    name = "cmcc-jtydn";
    text = ''
      set -eu

      state="''${XDG_DATA_HOME:-$HOME/.local/share}/cmcc-jtydn/${version}"

      if [ ! -f "$state/.complete" ]; then
        # Two clients started at once must not rm -rf each other's copy, and an
        # interrupted copy must not leave a 1.1 GB directory behind.
        ${coreutils}/bin/mkdir -p "''${state%/*}"
        exec 9>"$state.lock"
        ${util-linux}/bin/flock 9
        if [ ! -f "$state/.complete" ]; then
          echo "cmcc-jtydn: preparing a writable copy of the client in $state (about 1.1 GB, first run only)" >&2
          tmp="$state.tmp.$$"
          cleanup_tmp() {
            if [ -n "''${tmp:-}" ]; then
              ${coreutils}/bin/rm -rf "$tmp"
            fi
          }
          trap cleanup_tmp EXIT
          ${coreutils}/bin/rm -rf "$state".tmp.*
          ${coreutils}/bin/rm -rf "$tmp"
          ${coreutils}/bin/mkdir -p "$tmp"
          ${coreutils}/bin/cp -a "${app}/opt/chuanyun-vdi-client" "$tmp/app"
          ${coreutils}/bin/chmod -R u+w "$tmp/app"
          ${coreutils}/bin/rm -rf "$state"
          ${coreutils}/bin/mv "$tmp" "$state"
          tmp=
          trap - EXIT
          ${coreutils}/bin/touch "$state/.complete"
        fi
        exec 9>&-
      fi

      exec "${fhs}/bin/cmcc-jtydn-fhs" "$@"
    '';
  };

  package = stdenv.mkDerivation {
    pname = "cmcc-jtydn";
    inherit version;

    dontUnpack = true;
    dontBuild = true;
    dontStrip = true;

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/bin" "$out/share/applications" \
               "$out/share/icons/hicolor/256x256/apps"

      install -m755 ${client}/bin/cmcc-jtydn "$out/bin/cmcc-jtydn"
      install -m755 ${redirect}/bin/cmcc-jtydn-redirect "$out/bin/cmcc-jtydn-redirect"
      install -m644 ${app}/share/icons/hicolor/256x256/apps/cmcc-jtydn.png \
                    "$out/share/icons/hicolor/256x256/apps/cmcc-jtydn.png"

      # The vendor .desktop file hardcodes Exec=/opt/chuanyun-vdi-client/cmcc-jtydn;
      # ours points at the wrapper instead.
      cat > "$out/share/applications/cmcc-jtydn.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=CMCC Cloud PC
Name[zh_CN]=移动云电脑
Comment=China Mobile cloud desktop client (家庭云电脑 / 川云 VDI)
Comment[zh_CN]=中国移动云电脑客户端（家庭云电脑 / 川云 VDI）
Exec=cmcc-jtydn %U
Icon=cmcc-jtydn
Terminal=false
Categories=Network;RemoteAccess;
StartupWMClass=chuanyun-vdi-client
EOF
      chmod 644 "$out/share/applications/cmcc-jtydn.desktop"

      # Optional root daemon for USB redirection; the NixOS module in
      # modules/cmcc-jtydn-usb.nix wires up the same ExecStart.
      mkdir -p "$out/lib/systemd/system"
      cat > "$out/lib/systemd/system/cmcc-jtydn-redirect.service" <<EOF
[Unit]
Description=CMCC Cloud PC USB redirection (chuanyun-redirect)
After=network.target systemd-udevd.service
Wants=network.target

[Service]
Type=simple
# the sandbox binds this over /etc/udev/rules.d so the daemon can append the
# VID:PID permissions file there instead of failing on the read-only host path
ExecStartPre=-${coreutils}/bin/mkdir -p /run/cmcc-jtydn/udev
ExecStart=$out/bin/cmcc-jtydn-redirect
# the daemon exits cleanly when it processes a stale "stop" message, so come
# back and idle instead of staying dead
Restart=always
RestartSec=3
RuntimeDirectory=cmcc-jtydn
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

      runHook postInstall
    '';

    meta = {
      description = "China Mobile Cloud PC client (cmcc-jtydn, Electron/川云 VDI)";
      homepage = "https://soho.komect.com/clientDownload";
      license = lib.licenses.unfree;
      platforms = [ "x86_64-linux" ];
      mainProgram = "cmcc-jtydn";
      sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    };
  };
in
package
