## This file contains the lifecycle request type that will be handled.
## CREATE_NODE: create a new Logos Storage node with the provided config.json.
## START_NODE: start the provided Logos Storage node.
## STOP_NODE: stop the provided Logos Storage node.

import std/[options, json, strutils, net, os]
import codexdht/discv5/spr
import stew/shims/parseutils
import contractabi/address
import chronos
import chronicles
import results
import confutils
import confutils/std/net
import confutils/defs
import libp2p
import json_serialization
import json_serialization/std/[options, net]
import ../../alloc
import ../../../codex/conf
import ../../../codex/utils
import ../../../codex/utils/[keyutils, fileutils]
import ../../../codex/units

from ../../../codex/codex import CodexServer, new, start, stop, close

logScope:
  topics = "libstorage libstoragelifecycle"

type NodeLifecycleMsgType* = enum
  CREATE_NODE
  START_NODE
  STOP_NODE
  CLOSE_NODE

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
  val = ThreadCount(r.readValue(int))

proc readValue*(r: var JsonReader, val: var NBytes) =
  val = NBytes(r.readValue(int))

proc readValue*(r: var JsonReader, val: var Duration) =
  var dur: Duration
  let input = r.readValue(string)
  let count = parseDuration(input, dur)
  if count == 0:
    raise newException(SerializationError, "Cannot parse the duration: " & input)
  val = dur

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

proc createStorage(
    configJson: cstring
): Future[Result[CodexServer, string]] {.async: (raises: []).} =
  var conf: CodexConf

  try:
    conf = CodexConf.load(
      version = codexFullVersion,
      envVarsPrefix = "storage",
      cmdLine = @[],
      secondarySources = proc(
          config: CodexConf, sources: auto
      ) {.gcsafe, raises: [ConfigurationError].} =
        if configJson.len > 0:
          sources.addConfigFileContent(Json, $(configJson))
      ,
    )
  except ConfigurationError as e:
    return err("Failed to create Storage: unable to load configuration: " & e.msg)

  conf.setupLogging()

  try:
    {.gcsafe.}:
      updateLogLevel(conf.logLevel)
  except ValueError as err:
    return err("Failed to create Storage: invalid value for log level: " & err.msg)

  conf.setupMetrics()

  if not (checkAndCreateDataDir((conf.dataDir).string)):
    # We are unable to access/create data folder or data folder's
    # permissions are insecure.
    return err(
      "Failed to create Storage: unable to access/create data folder or data folder's permissions are insecure."
    )

  if not (checkAndCreateDataDir((conf.dataDir / "repo"))):
    # We are unable to access/create data folder or data folder's
    # permissions are insecure.
    return err(
      "Failed to create Storage: unable to access/create data folder or data folder's permissions are insecure."
    )

  let keyPath =
    if isAbsolute(conf.netPrivKeyFile):
      conf.netPrivKeyFile
    else:
      conf.dataDir / conf.netPrivKeyFile
  let privateKey = setupKey(keyPath)
  if privateKey.isErr:
    return err("Failed to create Storage: unable to get the private key.")
  let pk = privateKey.get()

  conf.apiBindAddress = string.none

  let server =
    try:
      CodexServer.new(conf, pk)
    except Exception as exc:
      return err("Failed to create Storage: " & exc.msg)

  return ok(server)

proc process*(
    self: ptr NodeLifecycleRequest, storage: ptr CodexServer
): Future[Result[string, string]] {.async: (raises: []).} =
  defer:
    destroyShared(self)

  case self.operation
  of CREATE_NODE:
    storage[] = (
      await createStorage(
        self.configJson # , self.appCallbacks
      )
    ).valueOr:
      error "Failed to CREATE_NODE.", error = error
      return err($error)
  of START_NODE:
    try:
      await storage[].start()
    except Exception as e:
      error "Failed to START_NODE.", error = e.msg
      return err(e.msg)
  of STOP_NODE:
    try:
      await storage[].stop()
    except Exception as e:
      error "Failed to STOP_NODE.", error = e.msg
      return err(e.msg)
  of CLOSE_NODE:
    try:
      await storage[].close()
    except Exception as e:
      error "Failed to STOP_NODE.", error = e.msg
      return err(e.msg)
  return ok("")
