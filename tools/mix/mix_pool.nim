## Copyright (c) 2026 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/[json, os, parseopt, strformat, strutils]

import pkg/libp2p/crypto/crypto
import pkg/libp2p/crypto/secp
import pkg/libp2p/multiaddress
import pkg/libp2p/peerid
import pkg/libp2p_mix/curve25519
import pkg/libp2p_mix/mix_node
import pkg/stew/byteutils
import pkg/results

const PoolFormatVersion = 1
const MixIdentityFileSize = 2 * FieldElementSize

when not defined(mixVersion):
  {.error: "mixVersion must be set at build time via -d:mixVersion:<value>".}
const mixVersion* {.strdefine.} = ""

proc fail(msg: string) {.noreturn.} =
  stderr.writeLine msg
  quit(1)

proc readBin(path: string): seq[byte] =
  if not fileExists(path):
    fail "File not found: " & path
  try:
    cast[seq[byte]](readFile(path))
  except IOError as exc:
    fail "Failed to read " & path & ": " & exc.msg

proc writeBin(path: string, data: openArray[byte]) =
  let parent = parentDir(path)
  if parent.len > 0 and not dirExists(parent):
    createDir(parent)
  try:
    writeFile(path, cast[string](@data))
    setFilePermissions(path, {fpUserRead, fpUserWrite})
  except IOError as exc:
    fail "Failed to write " & path & ": " & exc.msg
  except OSError as exc:
    fail "Failed to set permissions on " & path & ": " & exc.msg

proc pubInfoToJson(info: MixPubInfo): JsonNode =
  let (peerId, multiAddr, mixPubKey, libp2pPubKey) = info.get()
  %*{
    "peerId": $peerId,
    "multiAddr": $multiAddr,
    "mixPubKey": byteutils.toHex(fieldElementToBytes(mixPubKey)),
    "libp2pPubKey": byteutils.toHex(libp2pPubKey.getBytes()),
  }

proc pubInfoFromJson(node: JsonNode): MixPubInfo =
  let
    peerIdStr = node["peerId"].getStr()
    multiAddrStr = node["multiAddr"].getStr()
    mixPubKeyHex = node["mixPubKey"].getStr()
    libp2pPubKeyHex = node["libp2pPubKey"].getStr()

  let peerId = PeerId.init(peerIdStr).valueOr:
    fail "Invalid peerId in pool entry: " & peerIdStr & " (" & $error & ")"

  let multiAddr = MultiAddress.init(multiAddrStr).valueOr:
    fail "Invalid multiAddr in pool entry: " & multiAddrStr & " (" & $error & ")"

  let mixPubKey = bytesToFieldElement(hexToSeqByte(mixPubKeyHex)).valueOr:
    fail "Invalid mixPubKey in pool entry: " & error

  let libp2pPubKey = SkPublicKey.init(hexToSeqByte(libp2pPubKeyHex)).valueOr:
    fail "Invalid libp2pPubKey in pool entry: " & $error

  MixPubInfo.init(peerId, multiAddr, mixPubKey, libp2pPubKey)

proc readPool(path: string): JsonNode =
  if not fileExists(path):
    return %*{"version": PoolFormatVersion, "relays": newJArray()}

  let jsonPool =
    try:
      readFile(path)
    except IOError as exc:
      fail "Failed to read pool " & path & ": " & exc.msg

  let parsed =
    try:
      parseJson(jsonPool)
    except JsonParsingError as exc:
      fail "Pool file is not valid JSON: " & exc.msg

  if not parsed.hasKey("version") or parsed["version"].getInt() != PoolFormatVersion:
    fail(
      "Unsupported pool version (expected " & $PoolFormatVersion & " in " & path & ")"
    )
  if not parsed.hasKey("relays") or parsed["relays"].kind != JArray:
    fail "Pool file missing 'relays' array: " & path
  parsed

proc writePool(path: string, pool: JsonNode) =
  let parent = parentDir(path)
  if parent.len > 0 and not dirExists(parent):
    createDir(parent)
  try:
    writeFile(path, pool.pretty() & "\n")
  except IOError as exc:
    fail "Failed to write pool " & path & ": " & exc.msg

proc appendOrReplace(pool: JsonNode, entry: JsonNode) =
  let
    peerId = entry["peerId"].getStr()
    relays = pool["relays"]
  for i in 0 ..< relays.len:
    if relays[i]["peerId"].getStr() == peerId:
      relays.elems[i] = entry
      return
  relays.add(entry)

proc writeMixIdentity(path: string, mixPub, mixPriv: FieldElement) =
  let
    pubBytes = fieldElementToBytes(mixPub)
    privBytes = fieldElementToBytes(mixPriv)
  doAssert pubBytes.len == FieldElementSize and privBytes.len == FieldElementSize
  writeBin(path, pubBytes & privBytes)

proc readMixIdentity(path: string): tuple[pub: FieldElement, priv: FieldElement] =
  let raw = readBin(path)
  if raw.len != MixIdentityFileSize:
    fail(
      "Invalid mix-identity size at " & path & " (expected " & $MixIdentityFileSize &
        ", got " & $raw.len & ")"
    )
  let
    pub = bytesToFieldElement(raw.toOpenArray(0, FieldElementSize - 1)).valueOr:
      fail "Failed to parse mix pub key in " & path & ": " & error
    priv = bytesToFieldElement(
      raw.toOpenArray(FieldElementSize, MixIdentityFileSize - 1)
    ).valueOr:
      fail "Failed to parse mix priv key in " & path & ": " & error
  (pub: pub, priv: priv)

proc writeLibp2pKey(path: string, priv: PrivateKey) =
  let bytes = priv.getBytes().valueOr:
    fail "Failed to serialize libp2p key: " & $error
  writeBin(path, bytes)

proc readLibp2pKey(path: string): PrivateKey =
  let bytes = readBin(path)
  PrivateKey.init(bytes).valueOr:
    fail "Failed to parse libp2p key in " & path & ": " & $error

type
  InitArgs = object
    pool, outDir, ip: string
    count, basePort: int

  ExportArgs = object
    pool, dataDir, listenIp: string
    listenPort: int

  ListArgs = object
    pool: string

  RemoveArgs = object
    pool, peerId: string

proc cmdInit(args: InitArgs) =
  let rng = newRng()
  if rng.isNil:
    fail "Failed to create RNG"

  var pool = %*{"version": PoolFormatVersion, "relays": newJArray()}

  for i in 0 ..< args.count:
    let port = args.basePort + i
    var nodeInfo = MixNodeInfo.generateRandom(port, rng)

    let ma = MultiAddress.init(fmt"/ip4/{args.ip}/tcp/{port}").valueOr:
      fail "Failed to construct multiaddr: " & $error
    nodeInfo.multiAddr = ma
    let libp2pPubProto = PublicKey(scheme: Secp256k1, skkey: nodeInfo.libp2pPubKey)
    nodeInfo.peerId = PeerId.init(libp2pPubProto).valueOr:
      fail "Failed to derive peerId: " & $error

    let nodeDir = args.outDir / fmt"relay_{i}"
    writeMixIdentity(nodeDir / "mix-identity", nodeInfo.mixPubKey, nodeInfo.mixPrivKey)
    let libp2pPriv = PrivateKey(scheme: Secp256k1, skkey: nodeInfo.libp2pPrivKey)
    writeLibp2pKey(nodeDir / "key", libp2pPriv)

    pool["relays"].add(pubInfoToJson(nodeInfo.toMixPubInfo()))

  writePool(args.pool, pool)
  stdout.writeLine "Wrote pool with " & $args.count & " relays to " & args.pool
  stdout.writeLine "Per-node identity files under " & args.outDir & "/relay_<i>/"

proc cmdExport(args: ExportArgs) =
  if args.listenPort < 1 or args.listenPort > 65535:
    fail "--listen-port must be 1..65535"

  let
    (mixPub, mixPriv) = readMixIdentity(args.dataDir / "mix-identity")
    libp2pPriv = readLibp2pKey(args.dataDir / "key")

  if libp2pPriv.scheme != Secp256k1:
    fail "Mix requires a Secp256k1 libp2p key; got " & $libp2pPriv.scheme

  let libp2pPub = libp2pPriv.getPublicKey().valueOr:
    fail "Failed to derive libp2p public key: " & $error

  let peerId = PeerId.init(libp2pPub).valueOr:
    fail "Failed to derive peerId: " & $error

  let multiAddr = MultiAddress.init(fmt"/ip4/{args.listenIp}/tcp/{args.listenPort}").valueOr:
    fail "Failed to construct multiaddr: " & $error

  let
    pubInfo = MixPubInfo.init(peerId, multiAddr, mixPub, libp2pPub.skkey)
    pool = readPool(args.pool)
  pool.appendOrReplace(pubInfoToJson(pubInfo))
  writePool(args.pool, pool)
  stdout.writeLine "Added/updated relay " & $peerId & " (" & $multiAddr & ") in " &
    args.pool

proc cmdList(args: ListArgs) =
  let
    pool = readPool(args.pool)
    relays = pool["relays"]
  stdout.writeLine "Pool version " & $pool["version"].getInt() & ", " & $relays.len &
    " relays:"
  for entry in relays:
    stdout.writeLine "  " & entry["peerId"].getStr() & "  " & entry["multiAddr"].getStr()

proc cmdRemove(args: RemoveArgs) =
  let pool = readPool(args.pool)
  var
    relays = pool["relays"]
    filtered = newJArray()
    removed = 0
  for entry in relays:
    if entry["peerId"].getStr() == args.peerId:
      inc removed
    else:
      filtered.add(entry)
  pool["relays"] = filtered
  writePool(args.pool, pool)
  if removed == 0:
    stdout.writeLine "No matching peerId in pool; nothing changed."
  else:
    stdout.writeLine "Removed " & $removed & " entry(ies) for peerId " & args.peerId

proc usage(): string =
  """
mix_pool — manage a Mix relay pool stored as JSON.

Usage:
  mix_pool init   --pool=<file> --count=N [--ip=<addr>] [--base-port=<n>] [--outdir=<dir>]
  mix_pool export --pool=<file> --data-dir=<dir> --listen-ip=<addr> --listen-port=<port>
  mix_pool list   --pool=<file>
  mix_pool remove --pool=<file> --peer-id=<id>

Options (common):
  --pool=<file>       Path to pool.json (created if absent).
  -h, --help          Show this help.
  -v, --version       Show version and revision.

init:
  --count=N           Number of relays to generate.
  --ip=<addr>         Public IPv4 set into each relay's multiaddr. (default 127.0.0.1)
  --base-port=<n>     First TCP port; relay i uses base-port+i. (default 4242)
  --outdir=<dir>      Where to write each relay's identity files. (default ./relays)

export:
  --data-dir=<dir>    Existing storage data-dir (contains mix-identity and key).
  --listen-ip=<addr>  Public IPv4 to embed in the pool entry's multiaddr.
  --listen-port=<n>   Public TCP port (1..65535).

remove:
  --peer-id=<id>      Base58 PeerId of the entry to drop.
"""

proc parseSubcommand(): string =
  let params = commandLineParams()
  if params.len == 0:
    stdout.writeLine usage()
    quit(1)
  let first = params[0]
  if first in ["-h", "--help", "help"]:
    stdout.writeLine usage()
    quit(0)
  if first in ["-v", "--version", "version"]:
    stdout.writeLine mixVersion
    quit(0)
  if first.startsWith("-"):
    fail "Expected a subcommand as first argument; got: " & first & "\n" & usage()
  return first

proc dispatch() =
  let sub = parseSubcommand()
  var args = commandLineParams()
  args.delete(0)
  var p = initOptParser(args)

  case sub
  of "init":
    var a =
      InitArgs(pool: "", outDir: "./relays", ip: "127.0.0.1", count: 0, basePort: 4242)
    while true:
      p.next()
      case p.kind
      of cmdEnd:
        break
      of cmdShortOption, cmdLongOption:
        case p.key
        of "help", "h":
          stdout.writeLine usage()
          quit(0)
        of "pool":
          a.pool = expandTilde(p.val)
        of "count":
          try:
            a.count = parseInt(p.val)
          except ValueError:
            fail "init: --count must be an integer, got: " & p.val
        of "ip":
          a.ip = p.val
        of "base-port":
          try:
            a.basePort = parseInt(p.val)
          except ValueError:
            fail "init: --base-port must be an integer, got: " & p.val
        of "outdir":
          a.outDir = expandTilde(p.val)
        else:
          fail "init: unknown flag --" & p.key
      of cmdArgument:
        stderr.writeLine usage()
        quit(1)
    if a.pool.len == 0:
      fail "init: --pool=<file> is required"
    if a.count < 1:
      fail "init: --count=<n> must be >= 1"
    cmdInit(a)
  of "export":
    var a = ExportArgs(pool: "", dataDir: "", listenIp: "", listenPort: 0)
    while true:
      p.next()
      case p.kind
      of cmdEnd:
        break
      of cmdShortOption, cmdLongOption:
        case p.key
        of "help", "h":
          stdout.writeLine usage()
          quit(0)
        of "pool":
          a.pool = expandTilde(p.val)
        of "data-dir":
          a.dataDir = expandTilde(p.val)
        of "listen-ip":
          a.listenIp = p.val
        of "listen-port":
          try:
            a.listenPort = parseInt(p.val)
          except ValueError:
            fail "export: --listen-port must be an integer, got: " & p.val
        else:
          fail "export: unknown flag --" & p.key
      of cmdArgument:
        stderr.writeLine usage()
        quit(1)
    if a.pool.len == 0:
      fail "export: --pool=<file> is required"
    if a.dataDir.len == 0:
      fail "export: --data-dir=<dir> is required"
    if a.listenIp.len == 0:
      fail "export: --listen-ip=<addr> is required"
    if a.listenPort == 0:
      fail "export: --listen-port=<port> is required"
    cmdExport(a)
  of "list":
    var a = ListArgs(pool: "")
    while true:
      p.next()
      case p.kind
      of cmdEnd:
        break
      of cmdShortOption, cmdLongOption:
        case p.key
        of "help", "h":
          stdout.writeLine usage()
          quit(0)
        of "pool":
          a.pool = expandTilde(p.val)
        else:
          fail "list: unknown flag --" & p.key
      of cmdArgument:
        stderr.writeLine usage()
        quit(1)
    if a.pool.len == 0:
      fail "list: --pool=<file> is required"
    cmdList(a)
  of "remove":
    var a = RemoveArgs(pool: "", peerId: "")
    while true:
      p.next()
      case p.kind
      of cmdEnd:
        break
      of cmdShortOption, cmdLongOption:
        case p.key
        of "help", "h":
          stdout.writeLine usage()
          quit(0)
        of "pool":
          a.pool = expandTilde(p.val)
        of "peer-id":
          a.peerId = p.val
        else:
          fail "remove: unknown flag --" & p.key
      of cmdArgument:
        stderr.writeLine usage()
        quit(1)
    if a.pool.len == 0:
      fail "remove: --pool=<file> is required"
    if a.peerId.len == 0:
      fail "remove: --peer-id=<id> is required"
    cmdRemove(a)
  else:
    fail "Unknown subcommand: " & sub & "\n" & usage()

when isMainModule:
  dispatch()
