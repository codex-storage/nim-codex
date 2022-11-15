## Nim-Codex
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
import std/strutils
import std/typetraits

import pkg/chronicles
import pkg/chronicles/helpers
import pkg/chronicles/topics_registry
import pkg/confutils/defs
import pkg/confutils/std/net
import pkg/metrics
import pkg/metrics/chronos_httpserver
import pkg/stew/shims/net as stewnet
import pkg/libp2p
import pkg/ethers

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

  CodexConf* = object
    logLevel* {.
      defaultValue: "INFO"
      desc: "Sets the log level",
      name: "log-level" }: string

    logFormat* {.
      hidden
      desc: "Specifies what kind of logs should be written to stdout (auto, colors, nocolors, json)"
      defaultValueDesc: "auto"
      defaultValue: LogKind.Auto
      name: "log-format" }: LogKind

    metricsEnabled* {.
      desc: "Enable the metrics server"
      defaultValue: false
      name: "metrics" }: bool

    metricsAddress* {.
      desc: "Listening address of the metrics server"
      defaultValue: ValidIpAddress.init("127.0.0.1")
      defaultValueDesc: "127.0.0.1"
      name: "metrics-address" }: ValidIpAddress

    metricsPort* {.
      desc: "Listening HTTP port of the metrics server"
      defaultValue: 8008
      name: "metrics-port" }: Port

    dataDir* {.
      desc: "The directory where codex will store configuration and data."
      defaultValue: defaultDataDir()
      defaultValueDesc: ""
      abbr: "d"
      name: "data-dir" }: OutDir

    case cmd* {.
      command
      defaultValue: noCommand }: StartUpCommand

    of noCommand:
      listenAddrs* {.
        desc: "Multi Addresses to listen on"
        defaultValue: @[
          MultiAddress.init("/ip4/0.0.0.0/tcp/0")
          .expect("Should init multiaddress")]
        defaultValueDesc: "/ip4/0.0.0.0/tcp/0"
        abbr: "i"
        name: "listen-addrs" }: seq[MultiAddress]

      nat* {.
        # TODO: change this once we integrate nat support
        desc: "IP Addresses to announce behind a NAT"
        defaultValue: ValidIpAddress.init("127.0.0.1")
        defaultValueDesc: "127.0.0.1"
        abbr: "a"
        name: "nat" }: ValidIpAddress

      discoveryIp* {.
        desc: "Discovery listen address"
        defaultValue: ValidIpAddress.init(IPv4_any())
        defaultValueDesc: "0.0.0.0"
        abbr: "e"
        name: "disc-ip" }: ValidIpAddress

      discoveryPort* {.
        desc: "Discovery (UDP) port"
        defaultValue: 8090.Port
        defaultValueDesc: "8090"
        abbr: "u"
        name: "disc-port" }: Port

      netPrivKeyFile* {.
        desc: "Source of network (secp256k1) private key file path or name"
        defaultValue: "key"
        name: "net-privkey" }: string

      bootstrapNodes* {.
        desc: "Specifies one or more bootstrap nodes to use when connecting to the network."
        abbr: "b"
        name: "bootstrap-node" }: seq[SignedPeerRecord]

      maxPeers* {.
        desc: "The maximum number of peers to connect to"
        defaultValue: 160
        name: "max-peers" }: int

      agentString* {.
        defaultValue: "Codex"
        desc: "Node agent string which is used as identifier in network"
        name: "agent-string" }: string

      apiPort* {.
        desc: "The REST Api port",
        defaultValue: 8080
        defaultValueDesc: "8080"
        name: "api-port"
        abbr: "p" }: int

      cacheSize* {.
        desc: "The size in MiB of the block cache, 0 disables the cache - might help on slow hardrives"
        defaultValue: 0
        defaultValueDesc: "0"
        name: "cache-size"
        abbr: "c" }: Natural

      persistence* {.
        desc: "Enables persistence mechanism, requires an Ethereum node"
        defaultValue: false
        name: "persistence"
      .}: bool

      ethProvider* {.
        desc: "The URL of the JSON-RPC API of the Ethereum node"
        defaultValue: "ws://localhost:8545"
        name: "eth-provider"
      .}: string

      ethAccount* {.
        desc: "The Ethereum account that is used for storage contracts"
        defaultValue: EthAddress.none
        name: "eth-account"
      .}: Option[EthAddress]

      ethDeployment* {.
        desc: "The json file describing the contract deployment"
        defaultValue: string.none
        name: "eth-deployment"
      .}: Option[string]

    of initNode:
      discard

  EthAddress* = ethers.Address

const
  gitRevision* = strip(staticExec("git rev-parse --short HEAD"))[0..5]

  nimBanner* = staticExec("nim --version | grep Version")

  #TODO add versionMajor, Minor & Fix when we switch to semver
  codexVersion* = gitRevision

  codexFullVersion* =
    "Codex build " & codexVersion & "\p" &
    nimBanner

proc defaultDataDir*(): string =
  let dataDir = when defined(windows):
    "AppData" / "Roaming" / "Codex"
  elif defined(macosx):
    "Library" / "Application Support" / "Codex"
  else:
    ".cache" / "codex"

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

func parseCmdArg*(T: type EthAddress, address: TaintedString): T =
  EthAddress.init($address).get()

# no idea why confutils needs this:
proc completeCmdArg*(T: type EthAddress; val: TaintedString): seq[string] =
  discard

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

proc updateLogLevel*(logLevel: string) {.raises: [Defect, ValueError].} =
  # Updates log levels (without clearing old ones)
  let directives = logLevel.split(";")
  try:
    setLogLevel(parseEnum[LogLevel](directives[0]))
  except ValueError:
    raise (ref ValueError)(msg: "Please specify one of TRACE, DEBUG, INFO, NOTICE, WARN, ERROR or FATAL")

  if directives.len > 1:
    for topicName, settings in parseTopicDirectives(directives[1..^1]):
      if not setTopicState(topicName, settings.state, settings.logLevel):
        warn "Unrecognized logging topic", topic = topicName

proc setupLogging*(conf: CodexConf) =
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

  try:
    updateLogLevel(conf.logLevel)
  except ValueError as err:
    try:
      stderr.write "Invalid value for --log-level. " & err.msg & "\n"
    except IOError:
      echo "Invalid value for --log-level. " & err.msg
    quit QuitFailure

proc setupMetrics*(config: CodexConf) =
  if config.metricsEnabled:
    let metricsAddress = config.metricsAddress
    notice "Starting metrics HTTP server",
      url = "http://" & $metricsAddress & ":" & $config.metricsPort & "/metrics"
    try:
      startMetricsHttpServer($metricsAddress, config.metricsPort)
    except CatchableError as exc:
      raiseAssert exc.msg
    except Exception as exc:
      raiseAssert exc.msg # TODO fix metrics
