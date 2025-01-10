{ config, lib, pkgs, ... }:

let
  inherit (lib)
    types mkEnableOption mkOption mkIf length
    escapeShellArgs literalExpression optionalString
    concatStringsSep boolToString optionalAttrs;

  cfg = config.services.codex;
in {
  options = {
    services.codex = {
      enable = mkEnableOption "Codex Node service.";

      package = mkOption {
        type = types.package;
        default = pkgs.callPackage ../nix/default.nix { };
        defaultText = literalExpression "pkgs.codex";
        description = lib.mdDoc "Package to use as Codex node.";
      };

      service = {
        user = mkOption {
          type = types.str;
          default = "codex";
          description = "User for Codex service.";
        };

        group = mkOption {
          type = types.str;
          default = "codex";
          description = "Group for Codex service user.";
        };
      };

      configFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Path to the Codex configuration file.";
      };

      dataDir = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Directory for Codex data.";
      };

      logLevel = mkOption {
        type = types.str;
        default = "info";
        description = "Sets the log level [=info].";
      };

      logFormat = mkOption {
        type = types.str;
        default = "auto";
        description = "Specifies what kind of logs should be written to stdout (auto, colors, nocolors, json) [=auto].";
      };

    };
  };

  config = mkIf cfg.enable {
    users.users = optionalAttrs (cfg.service.user == "codex") {
      codex = {
        group = cfg.service.group;
        home = cfg.dataDir;
        description = "Codex service user";
        isSystemUser = true;
      };
    };

    users.groups = optionalAttrs (cfg.service.user == "codex") {
      codex = { };
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir or "/var/lib/codex"} 0755 codex codex"
    ];

    systemd.services.codex = {
      description = "Codex Node";
      wantedBy = [ "multi-user.target" ];
      requires = [ "network.target" ];
      serviceConfig = {
        User = cfg.service.user;
        Group = cfg.service.group;
        ExecStart = ''
          ${cfg.package}/bin/codex \
          ${optionalString (cfg.configFile != null) "--config-file=${cfg.configFile}"} \
          ${optionalString (cfg.dataDir != null) "--data-dir=${cfg.dataDir}"} \
          --log-level=${cfg.logLevel} \
          --log-format=${cfg.logFormat} \
        '';
        Restart = "on-failure";
      };
    };
  };
}
