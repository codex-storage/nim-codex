## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

# {.push raises: [Defect].}

import pkg/chronicles
import pkg/confutils
import pkg/libp2p

import std/os

type
  StartUpCommand* = enum
    noCommand
    # TODO: add commands that a
    # hipotetical client will be able
    # to execute against the daemon
    #
    # upload,
    # stream,
    # download,
    # etc...

  DaggerConf* = object
    logLevel* {.
      defaultValue: LogLevel.INFO
      desc: "Sets the log level" }: LogLevel

    apiPort* {.
      desc: "The REST Api port",
      defaultValue: 8080
      defaultValueDesc: "8080"
      abbr: "p" }: int

    case cmd* {.
      command
      defaultValue: noCommand }: StartUpCommand

    of noCommand:
      daggerDir* {.
        desc: "The directory where dagger will store config data."
        defaultValue: config.defaultDataDir()
        defaultValueDesc: ""
        abbr: "d" }: OutDir

      repoDir* {.
        desc: "The directory where dagger will store all data."
        defaultValue: config.defaultDataDir() / "repo"
        defaultValueDesc: ""
        abbr: "r" }: OutDir

      listenAddrs* {.
        desc: "Specifies one or more listening multiaddrs for the node to listen on."
        defaultValue: MultiAddress.init("/ip4/0.0.0.0/tcp/0")
        defaultValueDesc: "0.0.0.0:0"
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
        defaultValue: "Dagger",
        desc: "Node agent string which is used as identifier in network"
        name: "agent-string" }: string

func parseCmdArg*(T: type MultiAddress, input: TaintedString): T
                 {.raises: [ValueError, Defect].} =
  ?MultiAddress.init(input)

proc defaultDataDir(config: DaggerConf): string =
  let dataDir = when defined(windows):
    "AppData" / "Roaming" / "Dagger"
  elif defined(macosx):
    "Library" / "Application Support" / "Dagger"
  else:
    ".cache" / "dagger"

  getHomeDir() / dataDir
