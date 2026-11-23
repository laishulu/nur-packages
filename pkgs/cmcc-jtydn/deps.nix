{ lib, stdenv, fetchurl, dpkg, perl, version }:

# Libraries the vendor ELFs need but nixpkgs no longer provides: OpenSSL 1.1
# (the VDI SDK still links libssl.so.1.1) and the Debian 10 runtime libraries
# the client was built against.  They are mounted / searched as their own layer
# by the FHS sandboxes in default.nix.
{
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

    srcs = let
      # One fetchurl per package; the table keeps the (name, url, hash)
      # triple readable when a soname has to be added or bumped.
      debDepts = [
        { name = "libwebp6.deb";
          url = "http://archive.debian.org/debian/pool/main/libw/libwebp/libwebp6_0.6.1-2+deb10u1_amd64.deb";
          hash = "sha256-9Njoj4f0FTC76K1F9gq4fjE+8evJA1+f8kZJ/J3XRqk="; }
        { name = "librsvg2-2.deb";
          url = "http://archive.debian.org/debian/pool/main/libr/librsvg/librsvg2-2_2.44.10-2.1+deb10u3_amd64.deb";
          hash = "sha256-qgrHLRPpc77frhcC12FcETEUftrHBPyyYXQ7ScFYEjY="; }
        { name = "libzvbi0.deb";
          url = "http://archive.debian.org/debian/pool/main/z/zvbi/libzvbi0_0.2.35-16_amd64.deb";
          hash = "sha256-j0oiyZ7X3OkpZLhjVXRwF1O//t9Ex4cE9wH4lfePJgQ="; }
        { name = "libsnappy1v5.deb";
          url = "http://archive.debian.org/debian/pool/main/s/snappy/libsnappy1v5_1.1.7-1_amd64.deb";
          hash = "sha256-55HtgvgWhEIZon42gO1QdTqJOjTzjz5p7QjEq8OJy/g="; }
        { name = "libaom0.deb";
          url = "http://archive.debian.org/debian/pool/main/a/aom/libaom0_1.0.0-3_amd64.deb";
          hash = "sha256-IvBx2bX7xivbAapJ+mpCOUj/2v7EDtpSufDeDTMiePE="; }
        { name = "libgsm1.deb";
          url = "http://archive.debian.org/debian/pool/main/libg/libgsm/libgsm1_1.0.18-2_amd64.deb";
          hash = "sha256-p2PahajWbCIqdO3rCliryoE+rgLVv1OwkVmGnBBIF+s="; }
        { name = "libopenjp2-7.deb";
          url = "http://archive.debian.org/debian/pool/main/o/openjpeg2/libopenjp2-7_2.3.0-2+deb10u2_amd64.deb";
          hash = "sha256-VRJzGHRJNgmeaXkTbGa/a+ZSgVFjkhX2V4kc/gIc/VY="; }
        { name = "libopus0.deb";
          url = "http://archive.debian.org/debian/pool/main/o/opus/libopus0_1.3-1_amd64.deb";
          hash = "sha256-eNLXKTL5dJASzzVuhpn19WxKcH7rHxjES1mSivesWHY="; }
        { name = "libshine3.deb";
          url = "http://archive.debian.org/debian/pool/main/s/shine/libshine3_3.1.1-2_amd64.deb";
          hash = "sha256-awnw1Xf1Ff7/wHEEghiibN3lNG1uJmH4YQCYl9sCBNI="; }
        { name = "libspeex1.deb";
          url = "http://archive.debian.org/debian/pool/main/s/speex/libspeex1_1.2~rc1.2-1+b2_amd64.deb";
          hash = "sha256-Io38+n3T/YWqO7YMId5FSJ484/InSoDKw5knl++OVC4="; }
        { name = "libtheora0.deb";
          url = "http://archive.debian.org/debian/pool/main/libt/libtheora/libtheora0_1.1.1+dfsg.1-15_amd64.deb";
          hash = "sha256-ygLp2BqsUSh2AfeIbbZ/dG//g6i3RK/EZHw0oJiBquI="; }
        { name = "libtwolame0.deb";
          url = "http://archive.debian.org/debian/pool/main/t/twolame/libtwolame0_0.3.13-4_amd64.deb";
          hash = "sha256-siiTo6H6Wpi3VAXvsnygf5ZFTZrBbMzJEWDqZ6DBgQI="; }
        { name = "libvorbis0a.deb";
          url = "http://archive.debian.org/debian/pool/main/libv/libvorbis/libvorbis0a_1.3.6-2_amd64.deb";
          hash = "sha256-yiWYaImjeP/pDJd3OfgYSFjMnDwP0ofC8p4ZNphVxvM="; }
        { name = "libvorbisenc2.deb";
          url = "http://archive.debian.org/debian/pool/main/libv/libvorbis/libvorbisenc2_1.3.6-2_amd64.deb";
          hash = "sha256-BP/nnnJMIwd4v4qYdaRVvSTYoVw7RTsqG1ElEgxKUEQ="; }
        { name = "libwavpack1.deb";
          url = "http://archive.debian.org/debian/pool/main/w/wavpack/libwavpack1_5.1.0-6+deb10u1_amd64.deb";
          hash = "sha256-xvh3Me6LyCe2Hwmk2nmIy2LadLsllPjODtFPGaYi5ms="; }
        { name = "libx264-155.deb";
          url = "http://archive.debian.org/debian/pool/main/x/x264/libx264-155_0.155.2917+git0a84d98-2_amd64.deb";
          hash = "sha256-N8i1vh3a3faryS0oQ3JHRYTF4c6y8uwSpClqfFXqW2A="; }
        { name = "libxvidcore4.deb";
          url = "http://archive.debian.org/debian/pool/main/x/xvidcore/libxvidcore4_1.3.5-1_amd64.deb";
          hash = "sha256-2jVxJLSOl8fFXYNrCTaI73CN50Rqa6HFRwjxMH97ehY="; }
        { name = "libsoxr0.deb";
          url = "http://archive.debian.org/debian/pool/main/libs/libsoxr/libsoxr0_0.1.2-3_amd64.deb";
          hash = "sha256-6K9NBAZbzKh28OK7GCS7DOcQouwQqbGjIOIQvrvD26c="; }
        { name = "libnuma1.deb";
          url = "http://archive.debian.org/debian/pool/main/n/numactl/libnuma1_2.0.12-1_amd64.deb";
          hash = "sha256-qyJ3oq9UBW98KwH5jArJ6lRnU6Nd4A50KFt6D2Z+p+c="; }
        { name = "libjson-glib-1.0-0.deb";
          url = "http://archive.debian.org/debian/pool/main/j/json-glib/libjson-glib-1.0-0_1.4.4-2_amd64.deb";
          hash = "sha256-WPhy32vFIafvSZDCpLMmSxofqxVEApen6S74gGfjCO0="; }
        { name = "liblz4-1.deb";
          url = "http://archive.debian.org/debian/pool/main/l/lz4/liblz4-1_1.8.3-1+deb10u1_amd64.deb";
          hash = "sha256-VX1fBGlFcUdFsCRly25xiw3DzhEpj5ciaUoQ0UmNCD0="; }
        { name = "libsdl2-2.0-0.deb";
          url = "http://archive.debian.org/debian/pool/main/libs/libsdl2/libsdl2-2.0-0_2.0.9+dfsg1-1_amd64.deb";
          hash = "sha256-oFjqpfOOBAD9H/xuonXBzKUok5VSIN3PRoTC1kr5qhk="; }
        { name = "libharfbuzz0b.deb";
          url = "http://archive.debian.org/debian/pool/main/h/harfbuzz/libharfbuzz0b_2.3.1-1_amd64.deb";
          hash = "sha256-ruHdb5iEwazdG21vSb1BkjXezQD0nNkn5L5MN68uzas="; }
        { name = "libjpeg-turbo8.deb";
          url = "http://archive.ubuntu.com/ubuntu/pool/main/libj/libjpeg-turbo/libjpeg-turbo8_2.0.3-0ubuntu1.20.04.3_amd64.deb";
          hash = "sha256-ruycjRHQJlM3YLk7QiB36w3zgYJJpu9P0hvod3CwbSo="; }
        { name = "libcroco3.deb";
          url = "http://archive.debian.org/debian/pool/main/libc/libcroco/libcroco3_0.6.12-3_amd64.deb";
          hash = "sha256-GssAmWt0d2h+Tz8S3n+/S2NYZqYWdnHyIB6j5nrwUzY="; }
        { name = "libxml2.deb";
          url = "http://archive.debian.org/debian/pool/main/libx/libxml2/libxml2_2.9.4+dfsg1-7+deb10u4_amd64.deb";
          hash = "sha256-4eR7MZXNja2idqe0UnY1spyuOpYJtQfV50hcxK07rVI="; }
        { name = "libogg0.deb";
          url = "http://archive.debian.org/debian/pool/main/libo/libogg/libogg0_1.3.2-1+b1_amd64.deb";
          hash = "sha256-/Y5LDhzhcdr/SA6v2GLY4/NzQ9x622CoUinznkUZJmM="; }
        { name = "libsndio7.0.deb";
          url = "http://archive.debian.org/debian/pool/main/s/sndio/libsndio7.0_1.5.0-3_amd64.deb";
          hash = "sha256-rzuUJfyhq60lvlF3T+wXXnXxuS96GQnpwnu79kTCNVA="; }
        { name = "libxinerama1.deb";
          url = "http://archive.debian.org/debian/pool/main/libx/libxinerama/libxinerama1_1.1.4-2_amd64.deb";
          hash = "sha256-9pLIVJNVce5E/jE1Qdip9nik8R3FE7xDudClAcbf8L0="; }
        { name = "libwayland-client0.deb";
          url = "http://archive.debian.org/debian/pool/main/w/wayland/libwayland-client0_1.16.0-1_amd64.deb";
          hash = "sha256-gm/dGmpf+gFBXxOOI42oWKriKsT0g1zt/sq3bdDcsBs="; }
        { name = "libwayland-cursor0.deb";
          url = "http://archive.debian.org/debian/pool/main/w/wayland/libwayland-cursor0_1.16.0-1_amd64.deb";
          hash = "sha256-7umQ6grWisQJmG6/khBrjeraVMws/RkpMXf1+TjDVpA="; }
        { name = "libwayland-egl1.deb";
          url = "http://archive.debian.org/debian/pool/main/w/wayland/libwayland-egl1_1.16.0-1_amd64.deb";
          hash = "sha256-oCHpqpqSJw+iWSEaDKabXoQo8yxugApKk/B2awpIpcY="; }
        { name = "libffi6.deb";
          url = "http://archive.debian.org/debian/pool/main/libf/libffi/libffi6_3.2.1-9_amd64.deb";
          hash = "sha256-1NdI2Jfo5TqiOerSOhhyShowCFzGykGowxs7Hhs0UvQ="; }
        { name = "libbsd0.deb";
          url = "http://archive.debian.org/debian/pool/main/libb/libbsd/libbsd0_0.9.1-2+deb10u1_amd64.deb";
          hash = "sha256-y5TxdSLPgb4MnGmrfKUnRccL2/tMK6ANIGLC6dz+nG8="; }
        { name = "libicu63.deb";
          url = "http://archive.debian.org/debian/pool/main/i/icu/libicu63_63.1-6+deb10u3_amd64.deb";
          hash = "sha256-OPZarsTuCI9lMwz2NsHNbt7zgQnIBVmDbs844jkKV2E="; }
      ];
    in map (d: fetchurl { inherit (d) name url hash; }) debDepts;

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
}
