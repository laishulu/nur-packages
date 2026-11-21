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
  inherit (pkgs) stdenv fetchurl dpkg buildFHSEnv bash runCommand coreutils perl;

  # Packages of the FHS sandbox, taken by attribute name so that the ones a
  # given nixpkgs does not provide are skipped instead of breaking evaluation
  # (`libgbm` for instance only became a top-level attribute after 24.05).
  available = p: names: map (n: builtins.getAttr n p)
    (builtins.filter (n: builtins.hasAttr n p) names);

  version = "2.23.1";

  # The vendor VDI SDK still links against libssl.so.1.1 / libcrypto.so.1.1.
  # nixpkgs removed `openssl_1_1` (end of life) — the attribute still exists but
  # merely throws, so probing it is useless.  Build the last 1.1.1 release
  # locally instead: shared libraries only, no tests.
  openssl11 = stdenv.mkDerivation {
    pname = "openssl-1.1.1-shared";
    version = "1.1.1w";

    src = fetchurl {
      url = "https://www.openssl.org/source/old/1.1.1/openssl-1.1.1w.tar.gz";
      hash = "sha256-zzCYlQy02FOtlcCEHx+cbT3BAtzPys1SHZOSUgi3asg=";
    };

    nativeBuildInputs = [ perl ];
    enableParallelBuilding = true;
    doCheck = false;

    # Pre-2024 C code against a modern toolchain: keep the
    # implicit-function-declaration diagnostics from being fatal (GCC 14+).
    NIX_CFLAGS_COMPILE = "-Wno-error=implicit-function-declaration";

    # `./config` shells out to `env perl` (the tarball's shebangs point at
    # /usr/bin/env, which does not exist in the build sandbox), so drive
    # Configure with an absolute interpreter instead.
    configurePhase = ''
      runHook preConfigure
      patchShebangs Configure
      ${perl}/bin/perl ./Configure linux-x86_64 \
        --prefix=$out --openssldir=$out/etc/ssl \
        shared
      runHook postConfigure
    '';

    meta = {
      description = "OpenSSL 1.1.1 shared libraries (required by the vendor VDI SDK)";
      license = lib.licenses.openssl;
    };
  };

  # Debian 10 (buster) runtime libraries for the vendor ELFs.  The client was
  # built on UOS 20 (buster based) and links against sonames that only ever
  # existed in that generation -- libjpeg.so.8, libx264.so.155, libaom.so.0,
  # libwebp.so.6, ...  The .deb does not bundle them (on UOS they came from the
  # system) and nixpkgs has long moved on, so the matching buster packages are
  # unpacked here and searched after the FHS libraries.
  #
  # libjpeg.so.8 is the one buster no longer ships, hence the Ubuntu
  # libjpeg-turbo8 build (same library, that distribution's soname).
  debianLibs = stdenv.mkDerivation {
    pname = "cmcc-jtydn-debian10-libs";
    inherit version;

    srcs = [
      (fetchurl { name = "libwebp6.deb"; url = "http://archive.debian.org/debian/pool/main/libw/libwebp/libwebp6_0.6.1-2+deb10u1_amd64.deb"; hash = "sha256-9Njoj4f0FTC76K1F9gq4fjE+8evJA1+f8kZJ/J3XRqk="; })
      (fetchurl { name = "librsvg2-2.deb"; url = "http://archive.debian.org/debian/pool/main/libr/librsvg/librsvg2-2_2.44.10-2.1+deb10u3_amd64.deb"; hash = "sha256-qgrHLRPpc77frhcC12FcETEUftrHBPyyYXQ7ScFYEjY="; })
      (fetchurl { name = "libzvbi0.deb"; url = "http://archive.debian.org/debian/pool/main/z/zvbi/libzvbi0_0.2.35-16_amd64.deb"; hash = "sha256-j0oiyZ7X3OkpZLhjVXRwF1O//t9Ex4cE9wH4lfePJgQ="; })
      (fetchurl { name = "libsnappy1v5.deb"; url = "http://archive.debian.org/debian/pool/main/s/snappy/libsnappy1v5_1.1.7-1_amd64.deb"; hash = "sha256-55HtgvgWhEIZon42gO1QdTqJOjTzjz5p7QjEq8OJy/g="; })
      (fetchurl { name = "libaom0.deb"; url = "http://archive.debian.org/debian/pool/main/a/aom/libaom0_1.0.0-3_amd64.deb"; hash = "sha256-IvBx2bX7xivbAapJ+mpCOUj/2v7EDtpSufDeDTMiePE="; })
      (fetchurl { name = "libgsm1.deb"; url = "http://archive.debian.org/debian/pool/main/libg/libgsm/libgsm1_1.0.18-2_amd64.deb"; hash = "sha256-p2PahajWbCIqdO3rCliryoE+rgLVv1OwkVmGnBBIF+s="; })
      (fetchurl { name = "libopenjp2-7.deb"; url = "http://archive.debian.org/debian/pool/main/o/openjpeg2/libopenjp2-7_2.3.0-2+deb10u2_amd64.deb"; hash = "sha256-VRJzGHRJNgmeaXkTbGa/a+ZSgVFjkhX2V4kc/gIc/VY="; })
      (fetchurl { name = "libopus0.deb"; url = "http://archive.debian.org/debian/pool/main/o/opus/libopus0_1.3-1_amd64.deb"; hash = "sha256-eNLXKTL5dJASzzVuhpn19WxKcH7rHxjES1mSivesWHY="; })
      (fetchurl { name = "libshine3.deb"; url = "http://archive.debian.org/debian/pool/main/s/shine/libshine3_3.1.1-2_amd64.deb"; hash = "sha256-awnw1Xf1Ff7/wHEEghiibN3lNG1uJmH4YQCYl9sCBNI="; })
      (fetchurl { name = "libspeex1.deb"; url = "http://archive.debian.org/debian/pool/main/s/speex/libspeex1_1.2~rc1.2-1+b2_amd64.deb"; hash = "sha256-Io38+n3T/YWqO7YMId5FSJ484/InSoDKw5knl++OVC4="; })
      (fetchurl { name = "libtheora0.deb"; url = "http://archive.debian.org/debian/pool/main/libt/libtheora/libtheora0_1.1.1+dfsg.1-15_amd64.deb"; hash = "sha256-ygLp2BqsUSh2AfeIbbZ/dG//g6i3RK/EZHw0oJiBquI="; })
      (fetchurl { name = "libtwolame0.deb"; url = "http://archive.debian.org/debian/pool/main/t/twolame/libtwolame0_0.3.13-4_amd64.deb"; hash = "sha256-siiTo6H6Wpi3VAXvsnygf5ZFTZrBbMzJEWDqZ6DBgQI="; })
      (fetchurl { name = "libvorbis0a.deb"; url = "http://archive.debian.org/debian/pool/main/libv/libvorbis/libvorbis0a_1.3.6-2_amd64.deb"; hash = "sha256-yiWYaImjeP/pDJd3OfgYSFjMnDwP0ofC8p4ZNphVxvM="; })
      (fetchurl { name = "libvorbisenc2.deb"; url = "http://archive.debian.org/debian/pool/main/libv/libvorbis/libvorbisenc2_1.3.6-2_amd64.deb"; hash = "sha256-BP/nnnJMIwd4v4qYdaRVvSTYoVw7RTsqG1ElEgxKUEQ="; })
      (fetchurl { name = "libwavpack1.deb"; url = "http://archive.debian.org/debian/pool/main/w/wavpack/libwavpack1_5.1.0-6+deb10u1_amd64.deb"; hash = "sha256-xvh3Me6LyCe2Hwmk2nmIy2LadLsllPjODtFPGaYi5ms="; })
      (fetchurl { name = "libx264-155.deb"; url = "http://archive.debian.org/debian/pool/main/x/x264/libx264-155_0.155.2917+git0a84d98-2_amd64.deb"; hash = "sha256-N8i1vh3a3faryS0oQ3JHRYTF4c6y8uwSpClqfFXqW2A="; })
      (fetchurl { name = "libxvidcore4.deb"; url = "http://archive.debian.org/debian/pool/main/x/xvidcore/libxvidcore4_1.3.5-1_amd64.deb"; hash = "sha256-2jVxJLSOl8fFXYNrCTaI73CN50Rqa6HFRwjxMH97ehY="; })
      (fetchurl { name = "libsoxr0.deb"; url = "http://archive.debian.org/debian/pool/main/libs/libsoxr/libsoxr0_0.1.2-3_amd64.deb"; hash = "sha256-6K9NBAZbzKh28OK7GCS7DOcQouwQqbGjIOIQvrvD26c="; })
      (fetchurl { name = "libnuma1.deb"; url = "http://archive.debian.org/debian/pool/main/n/numactl/libnuma1_2.0.12-1_amd64.deb"; hash = "sha256-qyJ3oq9UBW98KwH5jArJ6lRnU6Nd4A50KFt6D2Z+p+c="; })
      (fetchurl { name = "libjson-glib-1.0-0.deb"; url = "http://archive.debian.org/debian/pool/main/j/json-glib/libjson-glib-1.0-0_1.4.4-2_amd64.deb"; hash = "sha256-WPhy32vFIafvSZDCpLMmSxofqxVEApen6S74gGfjCO0="; })
      (fetchurl { name = "liblz4-1.deb"; url = "http://archive.debian.org/debian/pool/main/l/lz4/liblz4-1_1.8.3-1+deb10u1_amd64.deb"; hash = "sha256-VX1fBGlFcUdFsCRly25xiw3DzhEpj5ciaUoQ0UmNCD0="; })
      (fetchurl { name = "libsdl2-2.0-0.deb"; url = "http://archive.debian.org/debian/pool/main/libs/libsdl2/libsdl2-2.0-0_2.0.9+dfsg1-1_amd64.deb"; hash = "sha256-oFjqpfOOBAD9H/xuonXBzKUok5VSIN3PRoTC1kr5qhk="; })
      (fetchurl { name = "libharfbuzz0b.deb"; url = "http://archive.debian.org/debian/pool/main/h/harfbuzz/libharfbuzz0b_2.3.1-1_amd64.deb"; hash = "sha256-ruHdb5iEwazdG21vSb1BkjXezQD0nNkn5L5MN68uzas="; })
      (fetchurl { name = "libjpeg-turbo8.deb"; url = "http://archive.ubuntu.com/ubuntu/pool/main/libj/libjpeg-turbo/libjpeg-turbo8_2.0.3-0ubuntu1.20.04.3_amd64.deb"; hash = "sha256-ruycjRHQJlM3YLk7QiB36w3zgYJJpu9P0hvod3CwbSo="; })
      (fetchurl { name = "libcroco3.deb"; url = "http://archive.debian.org/debian/pool/main/libc/libcroco/libcroco3_0.6.12-3_amd64.deb"; hash = "sha256-GssAmWt0d2h+Tz8S3n+/S2NYZqYWdnHyIB6j5nrwUzY="; })
      (fetchurl { name = "libxml2.deb"; url = "http://archive.debian.org/debian/pool/main/libx/libxml2/libxml2_2.9.4+dfsg1-7+deb10u4_amd64.deb"; hash = "sha256-4eR7MZXNja2idqe0UnY1spyuOpYJtQfV50hcxK07rVI="; })
      (fetchurl { name = "libogg0.deb"; url = "http://archive.debian.org/debian/pool/main/libo/libogg/libogg0_1.3.2-1+b1_amd64.deb"; hash = "sha256-/Y5LDhzhcdr/SA6v2GLY4/NzQ9x622CoUinznkUZJmM="; })
      (fetchurl { name = "libsndio7.0.deb"; url = "http://archive.debian.org/debian/pool/main/s/sndio/libsndio7.0_1.5.0-3_amd64.deb"; hash = "sha256-rzuUJfyhq60lvlF3T+wXXnXxuS96GQnpwnu79kTCNVA="; })
      (fetchurl { name = "libxinerama1.deb"; url = "http://archive.debian.org/debian/pool/main/libx/libxinerama/libxinerama1_1.1.4-2_amd64.deb"; hash = "sha256-9pLIVJNVce5E/jE1Qdip9nik8R3FE7xDudClAcbf8L0="; })
      (fetchurl { name = "libwayland-client0.deb"; url = "http://archive.debian.org/debian/pool/main/w/wayland/libwayland-client0_1.16.0-1_amd64.deb"; hash = "sha256-gm/dGmpf+gFBXxOOI42oWKriKsT0g1zt/sq3bdDcsBs="; })
      (fetchurl { name = "libwayland-cursor0.deb"; url = "http://archive.debian.org/debian/pool/main/w/wayland/libwayland-cursor0_1.16.0-1_amd64.deb"; hash = "sha256-7umQ6grWisQJmG6/khBrjeraVMws/RkpMXf1+TjDVpA="; })
      (fetchurl { name = "libwayland-egl1.deb"; url = "http://archive.debian.org/debian/pool/main/w/wayland/libwayland-egl1_1.16.0-1_amd64.deb"; hash = "sha256-oCHpqpqSJw+iWSEaDKabXoQo8yxugApKk/B2awpIpcY="; })
      (fetchurl { name = "libffi6.deb"; url = "http://archive.debian.org/debian/pool/main/libf/libffi/libffi6_3.2.1-9_amd64.deb"; hash = "sha256-1NdI2Jfo5TqiOerSOhhyShowCFzGykGowxs7Hhs0UvQ="; })
      (fetchurl { name = "libbsd0.deb"; url = "http://archive.debian.org/debian/pool/main/libb/libbsd/libbsd0_0.9.1-2+deb10u1_amd64.deb"; hash = "sha256-y5TxdSLPgb4MnGmrfKUnRccL2/tMK6ANIGLC6dz+nG8="; })
      (fetchurl { name = "libicu63.deb"; url = "http://archive.debian.org/debian/pool/main/i/icu/libicu63_63.1-6+deb10u3_amd64.deb"; hash = "sha256-OPZarsTuCI9lMwz2NsHNbt7zgQnIBVmDbs844jkKV2E="; })
    ];

    nativeBuildInputs = [ dpkg ];
    dontUnpack = true;
    dontStrip = true;
    dontPatchELF = true;

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/lib" "$out/.deps"
      for deb in $srcs; do
        dpkg-deb -x "$deb" "$out/.deps"
      done
      find "$out/.deps" -name '*.so*' \( -type f -o -type l \) \
        -exec cp -a {} "$out/lib/" \;
      rm -rf "$out/.deps"
      runHook postInstall
    '';
  };

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
      fhs_libs="$state/.fhs-libs"
      rm -rf "$fhs_libs"
      mkdir -p "$fhs_libs"
      for libdir in /usr/lib /usr/lib64 /lib /lib64; do
        [ -d "$libdir" ] || continue
        for f in "$libdir"/*.so*; do
          [ -e "$f" ] || continue
          b="''${f##*/}"
          if [ ! -e "$fhs_libs/$b" ]; then
            ln -s "$f" "$fhs_libs/$b"
          fi
        done
      done

      # From the mounted Debian set, keep only sonames the FHS does not already
      # provide.  A buster library duplicating a nixpkgs one (libharfbuzz.so.0)
      # would otherwise drag in its own buster chain (libgraphite2, libicu63,
      # ...) and break startup for everyone.
      deb_libs="$state/.debian-libs"
      rm -rf "$deb_libs"
      mkdir -p "$deb_libs"
      for f in /debian-libs/lib/*.so*; do
        [ -e "$f" ] || continue
        b="''${f##*/}"
        if [ -e "$fhs_libs/$b" ]; then
          continue
        fi
        ln -s "$f" "$deb_libs/$b"
      done

      libpath="$fhs_libs:$deb_libs"
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

      # The ZTE branches ship a QoE agent that upstream starts from a systemd
      # unit (`zqoe.service`) with absolute /opt paths.  Without it the client
      # logs "connect ECONNREFUSED /tmp/my.sock" forever and reports no network
      # quality.  It is started here directly instead of through the vendor's
      # monitor_qoe.sh: that script is a `while true` loop which respawns the
      # agent every five seconds, so closing the client left a process tree that
      # was impossible to get rid of.  USB redirection is still not provided (it
      # needs a root setuid helper).  Set CMCC_NO_QOE=1 to leave the agent off.
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
        pkill -f "QoEAgent" 2>/dev/null || true
      fi

      exit "$rc"
    '';
  };

  fhs = buildFHSEnv {
    name = "cmcc-jtydn-fhs";

    targetPkgs = p: available p [
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
    ]
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

  # Launcher that runs outside the sandbox: it materialises a writable copy of
  # the vendor tree (the /opt directory in the .deb is written to at runtime by
  # the addons), then enters the FHS environment.
  client = mkScript {
    name = "cmcc-jtydn";
    text = ''
      set -eu

      state="''${XDG_DATA_HOME:-$HOME/.local/share}/cmcc-jtydn/${version}"

      if [ ! -f "$state/.complete" ]; then
        echo "cmcc-jtydn: preparing a writable copy of the client in $state (about 1.1 GB, first run only)" >&2
        tmp="$state.tmp.$$"
        ${coreutils}/bin/rm -rf "$tmp"
        ${coreutils}/bin/mkdir -p "$tmp"
        ${coreutils}/bin/cp -a "${app}/opt/chuanyun-vdi-client" "$tmp/app"
        ${coreutils}/bin/chmod -R u+w "$tmp/app"
        ${coreutils}/bin/rm -rf "$state"
        ${coreutils}/bin/mv "$tmp" "$state"
        ${coreutils}/bin/touch "$state/.complete"
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
