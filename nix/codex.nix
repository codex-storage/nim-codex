{ config, lib, pkgs, ... }:

let
  inherit (lib)
    types mkEnableOption mkOption mkIf literalExpression;
  
  toml = pkgs.formats.toml { };

  cfg = config.services.codex;
in
{
  options = {
    services.codex = {
      enable = mkEnableOption "Codex Node service.";

      package = mkOption {
        type = types.package;
        default = pkgs.callPackage ./default.nix { };
        defaultText = literalExpression "pkgs.codex";
        description = lib.mdDoc "Package to use as Codex node.";
      };

      configFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Path to the Codex configuration file.";
      };

      configObject = lib.mkOption {
        default = { };
        type = toml.type;
        description = ''Structured settings object that will be used to generate a TOML config file.'';
      };
    };
  };

  config = mkIf cfg.enable {
    environment.etc = {
      "codex/config.toml".source = toml.generate "config.toml" cfg.configObject;
    };
    systemd.services.codex = {
      description = "Codex Node";
      wantedBy = [ "multi-user.target" ];
      requires = [ "network.target" ];
      serviceConfig = {
        DynamicUser = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "full";
        NoNewPrivileges = true;
        PrivateDevices = true;
        MemoryDenyWriteExecute = true;
        ExecStart = ''${cfg.package}/bin/codex --config-file=${if cfg.configFile != null then cfg.configFile else "/etc/codex/config.toml"}'';
        Restart = "on-failure";
      };
    };
  };
}
