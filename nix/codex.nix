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

      metrics = {
        enable = lib.mkEnableOption "Enable the metrics server.";
        address = mkOption {
          type = types.str;
          default = "127.0.0.1";
          description = "Listening address of the metrics server.";
        };

        port = mkOption {
          type = types.int;
          default = 8008;
          description = "Listening HTTP port of the metrics server.";
        };
      };

      listenAddrs = mkOption {
        type = types.nullOr (types.listOf types.str);
        default = null;
        description = "Multi Addresses to listen on.";
      };

      nat = mkOption {
        type = types.nullOr (types.listOf types.str);
        default = null;
        description = "IP Addresses to announce behind a NAT.";
      };

      discIp = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Discovery listen address.";
      };

      discPort = mkOption {
        type = types.nullOr types.int;
        default = null;
        description = "Discovery (UDP) port.";
      };

      netPrivKey = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Source of network (secp256k1) private key file path or name.";
      };

      bootstrapNodes = mkOption {
        type = types.nullOr (types.listOf types.str);
        default = null;
        description = "Specifies one or more bootstrap nodes to use when connecting to the network.";
      };

      maxPeers = mkOption {
        type = types.nullOr types.int;
        default = null;
        description = "The maximum number of peers to connect to.";
      };

      agentString = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Node agent string used as identifier in the network.";
      };

      apiBindAddr = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "The REST API bind address.";
      };

      apiPort = mkOption {
        type = types.nullOr types.int;
        default = null;
        description = "The REST API port.";
      };

      apiCorsOrigin = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "The REST API CORS allowed origin for downloading data.";
      };

      repoKind = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Backend for main repo store (fs, sqlite, leveldb).";
      };

      storageQuota = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "The size of the total storage quota dedicated to the node.";
      };

      blockTtl = mkOption {
        type = types.nullOr types.int;
        default = null;
        description = "Default block timeout in seconds - 0 disables the ttl.";
      };

      blockMaintenanceInterval = mkOption {
        type = types.nullOr types.int;
        default = null;
        description = "Time interval in seconds for block maintenance cycles.";
      };

      blockMaintenanceNumber = mkOption {
        type = types.nullOr types.int;
        default = null;
        description = "Number of blocks to check every maintenance cycle.";
      };

      cacheSize = mkOption {
        type = types.nullOr types.int;
        default = null;
        description = "The size of the block cache. 0 disables the cache.";
      };

      persistence = {
        enable = mkEnableOption "Enable the 'persistence' subcommand.";

        ethProvider = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "The URL of the JSON-RPC API of the Ethereum node.";
        };

        ethAccount = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "The Ethereum account that is used for storage contracts.";
        };

        ethPrivateKey = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "File containing Ethereum private key for storage contracts.";
        };

        marketplaceAddress = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Address of deployed Marketplace contract.";
        };

        validator = mkEnableOption "Enables validator, requires an Ethereum node.";

        validatorMaxSlots = mkOption {
          type = types.nullOr types.int;
          default = null;
          description = "Maximum number of slots that the validator monitors.";
        };

        validatorGroups = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Slot validation groups.";
        };

        validatorGroupIndex = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Slot validation group index.";
        };

        rewardRecipient = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Address to send payouts to (eg rewards and refunds).";
        };
      };

      prover = {
        enable = mkEnableOption "Enable the 'persistence prover' subcommand.";

        circuitDir = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Directory where Codex will store proof circuit data.";
        };

        circomR1cs = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "The r1cs file for the storage circuit.";
        };

        circomWasm = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "The wasm file for the storage circuit.";
        };

        circomZkey = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "The zkey file for the storage circuit.";
        };

        circomNoZkey = mkEnableOption "Ignore the zkey file - use only for testing!";

        proofSamples = mkOption {
          type = types.nullOr types.int;
          default = null;
          description = "Number of samples to prove.";
        };

        maxSlotDepth = mkOption {
          type = types.nullOr types.int;
          default = null;
          description = "The maximum depth of the slot tree.";
        };

        maxDatasetDepth = mkOption {
          type = types.nullOr types.int;
          default = null;
          description = "The maximum depth of the dataset tree.";
        };

        maxBlockDepth = mkOption {
          type = types.nullOr types.int;
          default = null;
          description = "The maximum depth of the network block merkle tree.";
        };

        maxCellElements = mkOption {
          type = types.nullOr types.int;
          default = null;
          description = "The maximum number of elements in a cell.";
        };
      };

      extraArgs = mkOption {
        type = types.nullOr (types.listOf types.str);
        default = null;
        description = "Additional arguments to pass to the Codex binary.";
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
          --metrics=${boolToString cfg.metrics.enable} ${optionalString cfg.metrics.enable ''--metrics-address=${cfg.metrics.address} --metrics-port=${toString cfg.metrics.port} ''}\
          ${optionalString (cfg.listenAddrs != null) (concatStringsSep " " (map (addr: "--listen-addrs=${addr}") cfg.listenAddrs))} \
          ${optionalString (cfg.nat != null) (concatStringsSep " " (map (addr: "--nat=${addr}") cfg.nat))} \
          ${optionalString (cfg.discIp != null) "--disc-ip=${cfg.discIp}"} \
          ${optionalString (cfg.discPort != null) "--disc-port=${toString cfg.discPort}"} \
          ${optionalString (cfg.netPrivKey != null) "--net-privkey=${cfg.netPrivKey}"} \
          ${optionalString (cfg.bootstrapNodes != null) (concatStringsSep " " (map (node: "--bootstrap-node=${node}") cfg.bootstrapNodes))} \
          ${optionalString (cfg.maxPeers != null) "--max-peers=${toString cfg.maxPeers}"} \
          ${optionalString (cfg.agentString != null) "--agent-string=${cfg.agentString}"} \
          ${optionalString (cfg.apiBindAddr != null) "--api-bindaddr=${cfg.apiBindAddr}"} \
          ${optionalString (cfg.apiPort != null) "--api-port=${toString cfg.apiPort}"} \
          ${optionalString (cfg.apiCorsOrigin != null) "--api-cors-origin=${cfg.apiCorsOrigin}"} \
          ${optionalString (cfg.repoKind != null) "--repo-kind=${cfg.repoKind}"} \
          ${optionalString (cfg.storageQuota != null) "--storage-quota=${cfg.storageQuota}"} \
          ${optionalString (cfg.blockTtl != null) "--block-ttl=${toString cfg.blockTtl}"} \
          ${optionalString (cfg.blockMaintenanceInterval != null) "--block-mi=${toString cfg.blockMaintenanceInterval}"} \
          ${optionalString (cfg.blockMaintenanceNumber != null) "--block-mn=${toString cfg.blockMaintenanceNumber}"} \
          ${optionalString (cfg.cacheSize != null) "--cache-size=${toString cfg.cacheSize}"} \
          ${mkIf cfg.subcommands.persistence.enable ''
            persistence \
            ${optionalString (cfg.subcommands.persistence.ethProvider != null) "--eth-provider=${cfg.subcommands.persistence.ethProvider}"} \
            ${optionalString (cfg.subcommands.persistence.ethAccount != null) "--eth-account=${cfg.subcommands.persistence.ethAccount}"} \
            ${optionalString (cfg.subcommands.persistence.ethPrivateKey != null) "--eth-private-key=${cfg.subcommands.persistence.ethPrivateKey}"} \
            ${optionalString (cfg.subcommands.persistence.marketplaceAddress != null) "--marketplace-address=${cfg.subcommands.persistence.marketplaceAddress}"} \
            --validator=${boolToString cfg.subcommands.persistence.validator} \
            ${optionalString (cfg.subcommands.persistence.validatorMaxSlots != null) "--validator-max-slots=${cfg.subcommands.persistence.validatorMaxSlots}"} \
            ${optionalString (cfg.subcommands.persistence.validatorGroups != null) "--validator-groups=${cfg.subcommands.persistence.validatorGroups}"} \
            ${optionalString (cfg.subcommands.persistence.validatorGroupIndex != null) "--validator-group-index=${cfg.subcommands.persistence.validatorGroupIndex}"} \
            ${optionalString (cfg.subcommands.persistence.rewardRecipient != null) "--reward-recipient=${cfg.subcommands.persistence.rewardRecipient}"} \
          ''} \
          ${mkIf cfg.subcommands.prover.enable ''
            "persistence prover" \
            ${optionalString (cfg.subcommands.prover.circuitDir != null) "--circuit-dir=${cfg.subcommands.prover.circuitDir}"} \
            ${optionalString (cfg.subcommands.prover.circomR1cs != null) "--circom-r1cs=${cfg.subcommands.prover.circomR1cs}"} \
            ${optionalString (cfg.subcommands.prover.circomWasm != null) "--circom-wasm=${cfg.subcommands.prover.circomWasm}"} \
            ${optionalString (cfg.subcommands.prover.circomZkey != null) "--circom-zkey=${cfg.subcommands.prover.circomZkey}"} \
            --circom-no-zkey=${boolToString cfg.subcommands.prover.circomNoZkey} \
            ${optionalString (cfg.subcommands.prover.proofSamples != null) "--proof-samples=${cfg.subcommands.prover.proofSamples}"} \
            ${optionalString (cfg.subcommands.prover.maxSlotDepth != null) "--max-slot-depth=${cfg.subcommands.prover.maxSlotDepth}"} \
            ${optionalString (cfg.subcommands.prover.maxDatasetDepth != null) "--max-dataset-depth=${cfg.subcommands.prover.maxDatasetDepth}"} \
            ${optionalString (cfg.subcommands.prover.maxBlockDepth != null) "--max-block-depth=${cfg.subcommands.prover.maxBlockDepth}"} \
            ${optionalString (cfg.subcommands.prover.maxCellElements != null) "--max-cell-elements=${cfg.subcommands.prover.maxCellElements}"} \
          ''}
          ${optionalString (cfg.extraArgs != null) (concatStringsSep " " cfg.extraArgs)}
        '';
        Restart = "on-failure";
      };
    };
  };
}
