## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

# {.push raises: [Defect].}

import std/os
import std/options

import pkg/chronicles
import pkg/confutils/defs
import pkg/libp2p

import ./rng

const
  DefaultTcpListenMultiAddr = "/ip4/0.0.0.0/tcp/0"

type
  StartUpCommand* {.pure.} = enum
    noCommand,
    initNode

  DaggerConf* = object
    logLevel* {.
      defaultValue: LogLevel.INFO
      desc: "Sets the log level" }: LogLevel

    daggerDir* {.
      desc: "The directory where dagger will store config data."
      # defaultValue: config.defaultDataDir()
      defaultValue: "~/.config/dagger"
      defaultValueDesc: ""
      abbr: "d" }: OutDir

    repoDir* {.
      desc: "The directory where dagger will store all data."
      # defaultValue: config.defaultDataDir() / "repo"
      defaultValue: "~/.config/dagger/repo"
      defaultValueDesc: ""
      abbr: "r" }: OutDir

    privateKey* {.
      desc: "The private key for this instance"
      }: Option[PrivateKey]

    case cmd* {.
      command
      defaultValue: noCommand }: StartUpCommand

    of noCommand:
      listenAddrs* {.
        desc: "Specifies one or more listening multiaddrs for the node to listen on."
        defaultValue: @[MultiAddress.init(DefaultTcpListenMultiAddr).tryGet()]
        # defaultValueDesc: $DefaultTcpListenMultiAddr
        abbr: "a"
        name: "listen-addrs" }: seq[MultiAddress]

      bootstrapNodes* {.
        desc: "Specifies one or more bootstrap nodes to use when connecting to the network."
        abbr: "b"
        name: "bootstrap-nodes" }: seq[MultiAddress]

      maxPeers* {.
        desc: "The maximum number of peers to connect to"
        defaultValue: 160
        name: "max-peers" }: int

      agentString* {.
        defaultValue: "Dagger"
        desc: "Node agent string which is used as identifier in network"
        name: "agent-string" }: string

      apiPort* {.
        desc: "The REST Api port",
        defaultValue: 8080
        defaultValueDesc: "8080"
        abbr: "p" }: int

    of initNode:
      privateKeyPath* {.
        desc: "Private key path"
        defaultValue: ""
        name: "key-path"}: InputFile

proc defaultDataDir*(#[config: DaggerConf]#): string =
  let dataDir = when defined(windows):
    "AppData" / "Roaming" / "Dagger"
  elif defined(macosx):
    "Library" / "Application Support" / "Dagger"
  else:
    ".cache" / "dagger"

  getHomeDir() / dataDir

echo defaultDataDir()

func parseCmdArg*(T: type MultiAddress, input: TaintedString): T
                 {.raises: [ValueError, LPError, Defect].} =
  MultiAddress.init($input).tryGet()
