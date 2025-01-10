 { self, config, lib, pkgs, ... }:

let
  inherit (lib)
    types mkEnableOption mkOption mkIf literalExpression
    mdDoc;
  
  toml = pkgs.formats.toml { };

  cfg = config.services.nim-codex;
in
{
  options = {
    services.nim-codex = {
      enable = mkEnableOption "Nim Codex Node service.";

      package = mkOption {
        type = types.package;
        default = pkgs.callPackage ./default.nix { src = self; };
        defaultText = literalExpression "pkgs.codex";
        description = mdDoc "Package to use as Nim Codex node.";
      };

      settings = mkOption {
        default = { };
        type = toml.type;
        description = ''Structured settings object that will be used to generate a TOML config file.'';
      };
    };
  };

  config = mkIf cfg.enable {
    environment.etc = {
      "nim-codex/config.toml".source = toml.generate "config.toml" cfg.settings;
    };
    systemd.services.nim-codex = {
      description = "Nim Codex Node";
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
        ExecStart = "${cfg.package}/bin/codex --config-file=/etc/nim-codex/config.toml";
        Restart = "on-failure";
      };
      restartIfChanged = true;
      restartTriggers = [
        "/etc/nim-codex/config.toml"
      ];
    };
  };
}
