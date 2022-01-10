## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

import std/os
import std/options

import pkg/chronicles
import pkg/confutils/defs
import pkg/libp2p

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

    dataDir* {.
      desc: "The directory where dagger will store configuration and data."
      defaultValue: defaultDataDir()
      defaultValueDesc: ""
      abbr: "d"
      name: "data-dir" }: OutDir

    case cmd* {.
      command
      defaultValue: noCommand }: StartUpCommand

    of noCommand:
      listenAddrs* {.
        desc: "Specifies one or more listening multiaddrs for the node to listen on."
        defaultValue: @[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()]
        defaultValueDesc: "/ip4/0.0.0.0/tcp/0"
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
        name: "api-port"
        abbr: "p" }: int

    of initNode:
      discard

proc defaultDataDir*(): string =
  let dataDir = when defined(windows):
    "AppData" / "Roaming" / "Dagger"
  elif defined(macosx):
    "Library" / "Application Support" / "Dagger"
  else:
    ".cache" / "dagger"

  getHomeDir() / dataDir

func parseCmdArg*(T: type MultiAddress, input: TaintedString): T
                 {.raises: [ValueError, LPError, Defect].} =
  MultiAddress.init($input).tryGet()
