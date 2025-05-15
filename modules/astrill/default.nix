# modules/astrill/default.nix
{ config, lib, pkgs, ... }:

with lib;
let
  cfg = config.services.astrill;
in {
  options.services.astrill = {
    enable = mkEnableOption "Astrill VPN client";
    package = mkOption {
      type = types.package;
      default = pkgs.astrill or pkgs.nur.repos.laishulu.astrill or (
        throw "Astrill package not found in pkgs or NUR."
      );
      description = "The Astrill VPN package to use.";
    };
  };

  config = mkIf cfg.enable {
    # Include Astrill package and required GTK2 theme engines
    environment.systemPackages = [
      cfg.package
      pkgs.gtk2-x11
      pkgs.xorg.libX11
    ];

    security.wrappers.asproxy = {
      owner = "root";
      group = "root";
      capabilities = "cap_net_admin,cap_net_raw+ep";
      source = "${cfg.package}/libexec/astrill/asproxy";
    };
    security.wrappers.astrill = {
      owner = "root";
      group = "root";
      capabilities = "cap_net_admin,cap_net_raw+ep";
      source = "${cfg.package}/libexec/astrill/astrill";
    };

    # Service to handle initialization (asproxy --init and setcap)
    systemd.services.astrill-init = {
      description = "Astrill VPN Initialization";
      wantedBy = [ "multi-user.target" ];
      before = [ "astrill-reconnect.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "astrill-init" ''
          echo "Initializing Astrill proxy..."
          ${cfg.package}$/libexec/astrill/asproxy --init
          echo "Astrill initialization complete."
        '';
        RemainAfterExit = true;
        User = "root"; # Ensure it runs as root for setcap and initialization
      };
    };

    # Service for Astrill reconnect functionality
    systemd.services.astrill-reconnect = {
      description = "Astrill VPN Reconnect Service";
      wantedBy = [ "multi-user.target" ];
      after = [ "astrill-init.service" "network.target" ];
      serviceConfig = {
        ExecStart = "${cfg.package}/bin/astrill";
        Restart = "on-failure";
        User = "root"; # May need to run as root depending on Astrill requirements
      };
    };

    # Optional: Update menus and icon caches if tools are available
    systemd.services.astrill-update-resources = {
      description = "Astrill Menu and Icon Cache Update";
      wantedBy = [ "multi-user.target" ];
      after = [ "astrill-init.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "astrill-update-resources" ''
          echo "Updating menus if available..."
          if command -v update-menus >/dev/null 2>&1; then
            update-menus
          fi
          echo "Updating icon cache if available..."
          if command -v update-icon-caches >/dev/null 2>&1; then
            update-icon-caches /usr/share/icons/hicolor
          fi
          echo "Please restart your web browser for all changes to take effect."
        '';
        RemainAfterExit = true;
      };
    };
  };
}
