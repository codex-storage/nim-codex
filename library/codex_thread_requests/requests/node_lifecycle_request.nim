## This file contains the lifecycle request type that will be handled.

import std/[options, json, strutils, net, os]
import confutils/defs
import codexdht/discv5/spr
import stew/shims/parseutils
import contractabi/address
import chronos
import chronicles
import results
import confutils
import confutils/std/net
import libp2p
import json_serialization
import json_serialization/std/[options, net]
import ../../alloc
import ../../../codex/conf
import ../../../codex/utils
import ../../../codex/utils/[keyutils, fileutils]

from ../../../codex/codex import CodexServer, new, start, stop

type NodeLifecycleMsgType* = enum
  CREATE_NODE
  START_NODE
  STOP_NODE

proc readValue*[T: InputFile | InputDir | OutPath | OutDir | OutFile](
    r: var JsonReader, val: var T
) =
  val = T(r.readValue(string))

proc readValue*(r: var JsonReader, val: var MultiAddress) =
  val = MultiAddress.init(r.readValue(string)).get()

proc readValue*(r: var JsonReader, val: var NatConfig) =
  let res = NatConfig.parse(r.readValue(string))
  if res.isErr:
    raise
      newException(SerializationError, "Cannot parse the NAT config: " & res.error())
  val = res.get()

proc readValue*(r: var JsonReader, val: var SignedPeerRecord) =
  let res = SignedPeerRecord.parse(r.readValue(string))
  if res.isErr:
    raise
      newException(SerializationError, "Cannot parse the signed peer: " & res.error())
  val = res.get()

proc readValue*(r: var JsonReader, val: var ThreadCount) =
  let res = ThreadCount.parse(r.readValue(string))
  if res.isErr:
    raise
      newException(SerializationError, "Cannot parse the thread count: " & res.error())
  val = res.get()

proc readValue*(r: var JsonReader, val: var NBytes) =
  let res = NBytes.parse(r.readValue(string))
  if res.isErr:
    raise newException(SerializationError, "Cannot parse the NBytes: " & res.error())
  val = res.get()

proc readValue*(r: var JsonReader, val: var Duration) =
  var dur: Duration
  let input = r.readValue(string)
  let count = parseDuration(input, dur)
  if count == 0:
    raise newException(SerializationError, "Cannot parse the duration: " & input)
  val = dur

proc readValue*(r: var JsonReader, val: var EthAddress) =
  val = EthAddress.init(r.readValue(string)).get()

type NodeLifecycleRequest* = object
  operation: NodeLifecycleMsgType
  configJson: cstring

proc createShared*(
    T: type NodeLifecycleRequest, op: NodeLifecycleMsgType, configJson: cstring = ""
): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  ret[].configJson = configJson.alloc()
  return ret

proc destroyShared(self: ptr NodeLifecycleRequest) =
  deallocShared(self[].configJson)
  deallocShared(self)

proc createCodex(
    configJson: cstring
): Future[Result[CodexServer, string]] {.async: (raises: []).} =
  var conf: CodexConf

  try:
    conf = CodexConf.load(
      version = codexFullVersion,
      envVarsPrefix = "codex",
      cmdLine = @[],
      secondarySources = proc(
          config: CodexConf, sources: auto
      ) {.gcsafe, raises: [ConfigurationError].} =
        if configJson.len > 0:
          sources.addConfigFileContent(Json, $(configJson))
      ,
    )
  except ConfigurationError as e:
    return err("Failed to load configuration: " & e.msg)

  conf.setupLogging()
  conf.setupMetrics()

  if not (checkAndCreateDataDir((conf.dataDir).string)):
    # We are unable to access/create data folder or data folder's
    # permissions are insecure.
    return err(
      "Unable to access/create data folder or data folder's permissions are insecure."
    )

  if not (checkAndCreateDataDir((conf.dataDir / "repo"))):
    # We are unable to access/create data folder or data folder's
    # permissions are insecure.
    return err(
      "Unable to access/create data folder or data folder's permissions are insecure."
    )

  debug "Repo dir initialized", dir = conf.dataDir / "repo"

  let keyPath =
    if isAbsolute(conf.netPrivKeyFile):
      conf.netPrivKeyFile
    else:
      conf.dataDir / conf.netPrivKeyFile
  let privateKey = setupKey(keyPath).expect("Should setup private key!")

  let server =
    try:
      CodexServer.new(conf, privateKey)
    except Exception as exc:
      return err("Failed to start Codex: " & exc.msg)

  return ok(server)

proc process*(
    self: ptr NodeLifecycleRequest, codex: ptr CodexServer
): Future[Result[string, string]] {.async: (raises: []).} =
  defer:
    destroyShared(self)

  case self.operation
  of CREATE_NODE:
    codex[] = (
      await createCodex(
        self.configJson # , self.appCallbacks
      )
    ).valueOr:
      error "CREATE_NODE failed", error = error
      return err($error)
  of START_NODE:
    try:
      await codex[].start()
    except Exception as e:
      error "START_NODE failed", error = e.msg
      return err(e.msg)
  of STOP_NODE:
    try:
      await codex[].stop()
    except Exception as e:
      error "STOP_NODE failed", error = e.msg
      return err(e.msg)

  return ok("")
