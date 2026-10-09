# Home-manager module for Yanyu speech-to-text
#
# Provides a systemd user service for autostart.
# Usage: imports = [ yanyu.homeManagerModules.default ];
#        services.yanyu.enable = true;
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.yanyu;
in
{
  options.services.yanyu = {
    enable = lib.mkEnableOption "Yanyu speech-to-text user service";

    package = lib.mkOption {
      type = lib.types.package;
      defaultText = lib.literalExpression "yanyu.packages.\${system}.yanyu";
      description = "The Yanyu package to use.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.user.services.yanyu = {
      Unit = {
        Description = "Yanyu speech-to-text";
        After = [ "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
      };
      Service = {
        ExecStart = "${cfg.package}/bin/yanyu";
        Restart = "on-failure";
        RestartSec = 5;
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };
  };
}
