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
import ./stpstore
import ./timing

export stpnetwork, stpstore, por, timing

type
  StorageProofs* = object
    store*: BlockStore
    network*: StpNetwork
    porStore*: StpStore

proc upload*(
  self: StorageProofs,
  cid: Cid,
  indexes: openArray[int],
  host: ca.Address): Future[?!void] {.async.} =
  ## Upload authenticators
  ##

  without por =? (await self.porStore.retrieve(cid)):
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
  manifest: Manifest): Future[?!void] {.async.} =
  ## Setup storage authentication
  ##

  without cid =? manifest.cid:
    return failure("Unable to retrieve Cid from manifest!")

  let
    (spk, ssk) = keyGen()
    por = await PoR.init(
      StoreStream.new(self.store, manifest),
      ssk,
      spk,
      manifest.blockSize)

  return await self.porStore.store(por, cid)

proc init*(
  T: type StorageProofs,
  network: StpNetwork,
  store: BlockStore,
  porStore: StpStore): StorageProofs =

  var
    self = T(
      store: store,
      porStore: porStore,
      network: network)

  proc tagsHandler(msg: TagsMessage) {.async, gcsafe.} =
    discard

  self.network.tagsHandler = tagsHandler
  self
