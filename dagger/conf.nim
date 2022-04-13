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
import std/terminal
import std/options
import std/typetraits

import pkg/chronicles
import pkg/chronicles/topics_registry
import pkg/confutils/defs
import pkg/confutils/std/net
import pkg/stew/shims/net as stewnet
import pkg/libp2p

import ./discovery
import ./stores/cachestore

export DefaultCacheSizeMiB, net

type
  StartUpCommand* {.pure.} = enum
    noCommand,
    initNode

  LogKind* = enum
    Auto = "auto"
    Colors = "colors"
    NoColors = "nocolors"
    Json = "json"
    None = "none"

  DaggerConf* = object
    logLevel* {.
      defaultValue: LogLevel.INFO
      desc: "Sets the log level",
      name: "log-level" }: LogLevel

    logFormat* {.
      hidden
      desc: "Specifies what kind of logs should be written to stdout (auto, colors, nocolors, json)"
      defaultValueDesc: "auto"
      defaultValue: LogKind.Auto
      name: "log-format" }: LogKind


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
        name: "listen-port" }: seq[Port]

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
        name: "bootstrap-nodes" }: seq[SignedPeerRecord]

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

proc parseCmdArg*(T: type SignedPeerRecord, uri: TaintedString): T =
  var res: SignedPeerRecord
  try:
    if not res.fromURI(uri):
      warn "Invalid SignedPeerRecord uri", uri=uri
      quit QuitFailure
  except CatchableError as exc:
    warn "Invalid SignedPeerRecord uri", uri=uri, error=exc.msg
    quit QuitFailure
  res

# silly chronicles, colors is a compile-time property
proc stripAnsi(v: string): string =
  var
    res = newStringOfCap(v.len)
    i: int

  while i < v.len:
    let c = v[i]
    if c == '\x1b':
      var
        x = i + 1
        found = false

      while x < v.len: # look for [..m
        let c2 = v[x]
        if x == i + 1:
          if c2 != '[':
            break
        else:
          if c2 in {'0'..'9'} + {';'}:
            discard # keep looking
          elif c2 == 'm':
            i = x + 1
            found = true
            break
          else:
            break
        inc x

      if found: # skip adding c
        continue
    res.add c
    inc i

  res

proc setupLogging*(conf: DaggerConf) =
  when defaultChroniclesStream.outputs.type.arity != 2:
    warn "Logging configuration options not enabled in the current build"
  else:
    proc noOutput(logLevel: LogLevel, msg: LogOutputStr) = discard
    proc writeAndFlush(f: File, msg: LogOutputStr) =
      try:
        f.write(msg)
        f.flushFile()
      except IOError as err:
        logLoggingFailure(cstring(msg), err)

    proc stdoutFlush(logLevel: LogLevel, msg: LogOutputStr) =
      writeAndFlush(stdout, msg)

    proc noColorsFlush(logLevel: LogLevel, msg: LogOutputStr) =
      writeAndFlush(stdout, stripAnsi(msg))

    defaultChroniclesStream.outputs[1].writer = noOutput

    defaultChroniclesStream.outputs[0].writer =
      case conf.logFormat:
      of LogKind.Auto:
        if isatty(stdout):
          stdoutFlush
        else:
          noColorsFlush
      of LogKind.Colors: stdoutFlush
      of LogKind.NoColors: noColorsFlush
      of LogKind.Json:
        defaultChroniclesStream.outputs[1].writer = stdoutFlush
        noOutput
      of LogKind.None:
        noOutput

    setLogLevel(conf.logLevel)
