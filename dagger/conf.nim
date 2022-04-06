## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/upraises

push: {.upraises: [].}

import std/os
import std/options

import pkg/chronicles
import pkg/confutils/defs
import pkg/confutils/std/net
import pkg/stew/shims/net as stewnet
import pkg/libp2p

import ./stores/cachestore

export DefaultCacheSizeMiB, net

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
      listenPorts* {.
        desc: "Specifies one or more listening ports for the node to listen on."
        defaultValue: @[Port(0)]
        defaultValueDesc: "0"
        abbr: "l"
        name: "listen-ports" }: seq[Port]

      # TODO We should have two options: the listen IP and the public IP
      # Currently, they are tied together, so we can't be discoverable
      # behind a NAT
      listenIp* {.
        desc: "The public IP"
        defaultValue: ValidIpAddress.init("0.0.0.0")
        defaultValueDesc: "0.0.0.0"
        abbr: "i"
        name: "listen-ip" }: ValidIpAddress

      discoveryPort* {.
        desc: "Specify the discovery (UDP) port"
        defaultValue: Port(8090)
        defaultValueDesc: "8090"
        name: "udp-port" }: Port

      netPrivKeyFile* {.
        desc: "Source of network (secp256k1) private key file (random|<path>)"
        defaultValue: "random"
        name: "net-privkey" }: string

      bootstrapNodes* {.
        desc: "Specifies one or more bootstrap nodes to use when connecting to the network."
        abbr: "b"
        name: "bootstrap-nodes" }: seq[string]

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

      cacheSize* {.
        desc: "The size in MiB of the block cache, 0 disables the cache"
        defaultValue: DefaultCacheSizeMiB
        defaultValueDesc: $DefaultCacheSizeMiB
        name: "cache-size"
        abbr: "c" }: Natural

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
