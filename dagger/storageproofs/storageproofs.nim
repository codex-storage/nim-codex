## Nim-Dagger
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/os
import std/strformat
import pkg/stew/io2
import pkg/protobuf_serialization

import ../stores
import ../manifest
import ../streams
import ../utils

import ./por
import ./por/serialization
import ./authexchange

export authexchange

type
  StorageProofs* = object
    store*: BlockStore
    authexchange*: AuthExchange
    authDir*: string
    postfixLen*: int

template authPath*(self: StorageProofs, cid: Cid): string =
  self.authDir / ($cid)[^self.postfixLen..^1] / $cid

proc setupProofs*(
  self: StorageProofs,
  manifest: Manifest): Future[?!void] {.async.} =

  let
    cid = manifest.cid.get()
    (spk, ssk) = keyGen()
    por = await PoR.init(
      StoreStream.new(self.store, manifest),
      ssk,
      spk,
      manifest.blockSize)
    parentDir = self.authPath(cid).parentDir

  if io2.createPath(parentDir).isErr:
    trace "Unable to create storage proofs prefix dir", dir = parentDir
    return failure("Unable to create storage proofs prefix dir ${parentDir}")

  let path = self.authPath(cid)
  if (
    let res = io2.writeFile(path, Protobuf.encode(por.toMessage()));
    res.isErr):
    let error = io2.ioErrorMsg(res.error)
    trace "Unable to store storage proofs", path, cid = cid, error
    return failure(
      &"Unable to store storage proofs path = ${path} cid = ${$cid} error = ${error}")

  return success()

proc getAuthenticators(self: StorageProofs, cid: Cid): seq[seq[byte]] =
  let path = self.authPath(cid)
  var data: seq[byte]
  if (
    let res = io2.readFile(path, data);
    res.isErr):
    let error = io2.ioErrorMsg(res.error)
    trace "Cannot retrieve authenticators from fs", path , error

  let porMessage = Protobuf.decode(data, PoRMessage)
  return porMessage.authenticators

# proc upload*(
#   self: StorageProofs,
#   manifest: Manifest,
#   hosts: seq[PeerID]): Future[?!void] {.async.} =
#   discard

# proc proof*() =
#   discard

# proc verify*() =
#   discard

proc init*(
  T: type StorageProofs,
  store: BlockStore,
  authExchange: AuthExchange,
  authDir: string): StorageProofs =
  T(
    store: store,
    authDir: authDir,
    authExchange: authExchange)
