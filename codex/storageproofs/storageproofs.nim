## Nim-Dagger
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/chronos
import pkg/chronicles
import pkg/questionable
import pkg/questionable/results
import pkg/contractabi/address as ca

import ../stores
import ../manifest
import ../streams
import ../utils

import ./por
import ./stpnetwork
import ./stpproto
import ./stpstore

export stpnetwork, stpstore, por, stpproto

type
  StorageProofs* = object
    store*: BlockStore
    network*: StpNetwork
    stpStore*: StpStore

proc upload*(
    self: StorageProofs,
    cid: Cid,
    indexes: seq[int],
    host: ca.Address
): Future[?!void] {.async.} =
  ## Upload authenticators
  ##

  without por =? (await self.stpStore.retrieve(cid)):
    trace "Unable to retrieve por data from store", cid
    return failure("Unable to retrieve por data from store")

  return await self.network.uploadTags(
    cid,
    indexes,
    por.authenticators,
    host)

# proc proof*() =
#   discard

# proc verify*() =
#   discard

proc setupProofs*(
    self: StorageProofs,
    manifest: Manifest
): Future[?!void] {.async.} =
  ## Setup storage authentication
  ##

  without cid =? manifest.cid:
    return failure("Unable to retrieve Cid from manifest!")

  let
    (spk, ssk) = keyGen()
    por = await PoR.init(
      SeekableStoreStream.new(self.store, manifest),
      ssk,
      spk,
      manifest.blockSize)

  return await self.stpStore.store(por.toMessage(), cid)

proc init*(
    T: type StorageProofs,
    network: StpNetwork,
    store: BlockStore,
    stpStore: StpStore
): StorageProofs =

  var
    self = T(
      store: store,
      stpStore: stpStore,
      network: network)

  proc tagsHandler(msg: TagsMessage) {.async, gcsafe.} =
    try:
      await self.stpStore.store(msg.cid, msg.tags).tryGet()
      trace "Stored tags", cid = $msg.cid, tags = msg.tags.len
    except CatchableError as exc:
      trace "Exception attempting to store tags", exc = exc.msg

  self.network.tagsHandler = tagsHandler
  self
