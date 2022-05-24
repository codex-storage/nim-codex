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
import pkg/contractabi/address as cta

import ../stores
import ../manifest
import ../streams
import ../utils

import ./por
import ./stpnetwork
import ./porstore

export stpnetwork

type
  StorageProofs* = object
    store*: BlockStore
    network*: StpNetwork
    porStore*: PorStore

proc upload*(
  self: StorageProofs,
  manifest: Manifest,
  host: cta.Address): Future[?!void] {.async.} =
  let cid = manifest.cid.get()
  without por =? (await self.porStore.retrieve(cid)):
    trace "Unable to retrieve por data from store", cid
    return failure("Unable to retrieve por data from store")

  return await self.network.submitAuthenticators(
    cid,
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

  let
    cid = manifest.cid.get()
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
  porStore: PorStore): StorageProofs =
  T(
    store: store,
    porStore: PorStore,
    network: StpNetwork)
