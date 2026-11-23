{ config, lib, pkgs, ... }:

# USB redirection for the CMCC Cloud PC client.
#
# The vendor's `chuanyun-redirect` is a root daemon: the viewer asks it over a
# System V message queue to hand a USB device to the cloud PC, and it claims the
# device on the host (libusbipd) and adds udev permissions.  The .deb runs it
# from a systemd unit we do not ship, which is why the client's USB list is dead
# without this module.
#
# The daemon itself runs inside the package's own FHS sandbox (it is a
# UOS/glibc-2.31 binary); this module only has to start it as root and give it
# a writable runtime directory.

let
  cfg = config.services.cmcc-jtydn-usb;
in
{
  options.services.cmcc-jtydn-usb = {
    enable = lib.mkEnableOption "USB redirection for the CMCC Cloud PC client";

    package = lib.mkOption {
      type = lib.types.package;
      default =
        if pkgs ? cmcc-jtydn then
          pkgs.cmcc-jtydn
        else if pkgs ? nur && pkgs.nur ? repos && pkgs.nur.repos ? laishulu
                && pkgs.nur.repos.laishulu ? cmcc-jtydn then
          # NUR convention: this repository is exposed as nur.repos.laishulu
          pkgs.nur.repos.laishulu.cmcc-jtydn
        else
          throw ''
            services.cmcc-jtydn-usb.package is not set and the package cannot be
            found (neither pkgs.cmcc-jtydn nor pkgs.nur.repos.laishulu.cmcc-jtydn).
            Import the flake's nixosModule, apply the overlay, or set the option
            explicitly.'';
      defaultText = lib.literalExpression "pkgs.cmcc-jtydn";
      description = ''
        The cmcc-jtydn package to take <literal>bin/cmcc-jtydn-redirect</literal>
        from.  It has to come from this repository (or its overlay), the
        attribute does not exist in nixpkgs.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.cmcc-jtydn-redirect = {
      description = "CMCC Cloud PC USB redirection (chuanyun-redirect)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" "systemd-udevd.service" ];
      wants = [ "network.target" ];

      # The daemon sandboxes itself with bubblewrap and needs to write under
      # /run/cmcc-jtydn (udev rules for the freshly attached device) and to
      # touch USB sysfs entries, so no additional hardening here.
      serviceConfig = {
        ExecStart = "${cfg.package}/bin/cmcc-jtydn-redirect";
        # the daemon sandbox binds /run/cmcc-jtydn/udev over /etc/udev/rules.d
        # and appends the VID:PID permissions file there
        ExecStartPre = [ "+${lib.getExe' pkgs.coreutils "mkdir"} -p /run/cmcc-jtydn/udev" ];
        # the daemon exits cleanly after processing a stale "stop" message
        # from a previous session, so always come back and idle
        Restart = "always";
        RestartSec = 3;
        RuntimeDirectory = "cmcc-jtydn";
        RuntimeDirectoryMode = "0755";
        LimitNOFILE = 65535;
        PrivateTmp = false;
        ProtectSystem = false;
        ProtectHome = false;
      };
    };

    # Let the desktop user see USB devices (the daemon still owns the actual
    # claim, it runs as root).
    services.udev.extraRules = ''
      # CMCC Cloud PC client: USB redirection
      SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", TAG+="uaccess"
    '';
  };
}
