# pkgs/astrill/default.nix
{ pkgs,
  lib,
  stdenv,
  fetchurl,
  dpkg,
  libcap,
  systemd, # Needed for autoPatchelfHook if binaries link libsystemd, and for systemd unit
  autoPatchelfHook,
  glib,
  gtk2,
  libX11,
  openssl,
  makeWrapper # To wrap the executable if needed (e.g. for env vars, though not strictly here)
}:

stdenv.mkDerivation rec {
  pname = "astrill";
  version = "3.10.0.3073";

  src = fetchurl {
    url = "https://www.astrilldownloads.com/astrill-setup-linux64.deb";
    sha256 = "1j1p83rhafhgzmhvnpk39j397xz3gzj9w7hkw8h3vzjd4j9h0457";
  };

  nativeBuildInputs = [ dpkg autoPatchelfHook makeWrapper ];

  # systemd is added here because autoPatchelfHook might need it
  # if astrill binaries link against libsystemd.so.
  # It's also conceptually a build input if we're installing systemd units.
  buildInputs = [ libcap glib gtk2 libX11 openssl systemd ];

  # Runtime dependencies that autoPatchelfHook will use to patch binaries
  # These are often the same as buildInputs, but it's good to be explicit.
  # autoPatchelfHook will look for libraries from these packages.
  # Ensure all runtime deps of the pre-compiled binaries are listed.
  propagatedBuildInputs = [
    glib # For GSettings, GIO schemas if used
    gtk2
    libX11
    openssl
    libcap
    systemd # If astrill links libsystemd
  ];


  unpackPhase = "dpkg-deb -x $src .";

  installPhase = ''
  runHook preInstall

  # Define where the application's core files will reside within $out
  local appInstallPath="$out/libexec/${pname}"

  # Create necessary directories
  mkdir -p "$appInstallPath" \
           "$out/bin" \
           "$out/lib/systemd/system" \
           "$out/share/applications" \
           "$out/share/icons"

  # Copy main application files from the unpacked .deb's usr/local/Astrill
  echo "Copying application files from usr/local/Astrill/* to $appInstallPath/"
  if [ -d usr/local/Astrill ]; then
    cp -r usr/local/Astrill/* "$appInstallPath/"
    echo "Files copied to $appInstallPath:"
    ls -l "$appInstallPath/"
  else
    echo "ERROR: usr/local/Astrill directory not found in unpacked .deb"
    find . -type d # Debug: show directory structure of unpacked .deb
    exit 1
  fi

  # Check if astrill binary exists in appInstallPath
  if [ -f "$appInstallPath/astrill" ]; then
    echo "astrill binary found at $appInstallPath/astrill"
    # Ensure it's executable
    chmod +x "$appInstallPath/astrill"
    ls -l "$appInstallPath/astrill"
  else
    echo "ERROR: astrill binary not found at $appInstallPath/astrill"
    echo "Contents of $appInstallPath:"
    ls -l "$appInstallPath/"
    echo "Searching for astrill binary in unpacked .deb..."
    find . -name "astrill" -type f
    exit 1
  fi

  # Copy systemd service file to the standard Nix location
  if [ -f etc/systemd/system/astrill-reconnect.service ]; then
    install -Dm644 etc/systemd/system/astrill-reconnect.service \
      "$out/lib/systemd/system/astrill-reconnect.service"
  else
    echo "WARNING: systemd service file not found at etc/systemd/system/astrill-reconnect.service"
  fi

  # Copy .desktop file and other shared resources (like icons)
  if [ -f usr/share/applications/Astrill.desktop ]; then
    install -Dm644 usr/share/applications/Astrill.desktop \
      "$out/share/applications/Astrill.desktop"
    echo "Installed Astrill.desktop from usr/share/applications/"
  elif [ -f "$appInstallPath/Astrill.desktop" ]; then
    install -Dm644 "$appInstallPath/Astrill.desktop" \
      "$out/share/applications/Astrill.desktop"
    echo "Installed Astrill.desktop from $appInstallPath/"
  else
    echo "WARNING: Astrill.desktop not found in expected locations"
    find . -name "Astrill.desktop" -type f
  fi

  # Copy icons if they exist
  if [ -d usr/share/icons ]; then
    cp -r usr/share/icons/* "$out/share/icons/"
    echo "Icons copied to $out/share/icons/"
  fi

  # Patch paths in configuration files
  if [ -f "$out/lib/systemd/system/astrill-reconnect.service" ]; then
    substituteInPlace "$out/lib/systemd/system/astrill-reconnect.service" \
      --replace "/usr/local/Astrill/astrill" "$appInstallPath/astrill" \
      --replace "/usr/local/Astrill" "$appInstallPath"
  fi

  if [ -f "$appInstallPath/Astrill.desktop" ]; then
    substituteInPlace "$appInstallPath/Astrill.desktop" \
      --replace "/usr/local/Astrill/astrill" "/run/wrappers/bin/astrill" \
      --replace "/usr/local/Astrill" "$appInstallPath"
  fi

  if [ -f "$out/share/applications/Astrill.desktop" ]; then
    substituteInPlace "$out/share/applications/Astrill.desktop" \
      --replace "/usr/local/Astrill/astrill" "/run/wrappers/bin/astrill" \
      --replace "/usr/local/Astrill" "$appInstallPath"
    echo "Contents of patched Astrill.desktop:"
    cat "$out/share/applications/Astrill.desktop"
  fi

  # Create a symlink for the binary in $out/bin
  if [ -f "$appInstallPath/astrill" ]; then
    ln -s "$appInstallPath/astrill" "$out/bin/astrill"
    echo "Symlink created: $out/bin/astrill -> $appInstallPath/astrill"
    ls -l "$out/bin/astrill"
  else
    echo "ERROR: Cannot create symlink, astrill binary not found at $appInstallPath/astrill"
    exit 1
  fi

  runHook postInstall
'';

  # Ensure autoPatchelfHook can find systemd libraries if needed by astrill binaries
  # It will search in buildInputs and propagatedBuildInputs
  # autoPatchelfHook will patch binaries in $out, including those in $appInstallPath

  meta = with lib; {
    description = "VPN configuration tool for Astrill's servers";
    homepage = "http://astrill.com/";
    license = licenses.unfree;
    platforms = [ "x86_64-linux" ];
    maintainers = with maintainers; [ ]; # Add your Nixpkgs GitHub username
  };
}
