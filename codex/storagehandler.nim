## Nim-Codex
## Copyright (c) 2024 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/sequtils

import pkg/libp2p
import pkg/chronos
import pkg/questionable
import pkg/questionable/results

import ./stores
import ./manifest
import ./contracts
import ./errors
import ./blocktype as bt

import ./node

export contracts, node

type
  StorageHandler* = ref object of RootObj
    node*: CodexNodeRef

proc onStore(
  self: StorageHandler,
  request: StorageRequest,
  slot: UInt256,
  blocksCb: BlocksCb): Future[?!void] {.async.} =
  ## store data in local storage
  ##

  without cid =? Cid.init(request.content.cid):
    trace "Unable to parse Cid", cid
    let error = newException(CodexError, "Unable to parse Cid")
    return failure(error)

  without manifest =? (await fetchManifest(self.node, cid)), error:
    trace "Unable to fetch manifest for cid", cid
    return failure(error)

  trace "Fetching block for manifest", cid
  let expiry = request.expiry.toSecondsSince1970
  proc expiryUpdateOnBatch(blocks: seq[bt.Block]): Future[?!void] {.async.} =
    let ensureExpiryFutures = blocks.mapIt(self.node.blockStore.ensureExpiry(it.cid, expiry))
    if updateExpiryErr =? (await allFutureResult(ensureExpiryFutures)).errorOption:
      return failure(updateExpiryErr)

    if not blocksCb.isNil and onBatchErr =? (await blocksCb(blocks)).errorOption:
      return failure(onBatchErr)

    return success()

  if fetchErr =? (await self.node.fetchBatched(manifest, onBatch = expiryUpdateOnBatch)).errorOption:
    let error = newException(CodexError, "Unable to retrieve blocks")
    error.parent = fetchErr
    return failure(error)

  return success()

proc onExpiryUpdate(
  self: StorageHandler,
  rootCid: string,
  expiry: SecondsSince1970): Future[?!void] {.async.} =
  without cid =? Cid.init(rootCid):
    trace "Unable to parse Cid", cid
    let error = newException(CodexError, "Unable to parse Cid")
    return failure(error)

  return await self.node.updateExpiry(cid, expiry)

proc onClear(self: StorageHandler, request: StorageRequest, slotIndex: UInt256) =
# TODO: remove data from local storage
  discard

proc onProve(self: StorageHandler, slot: Slot, challenge: ProofChallenge): Future[seq[byte]] {.async.} =
  # TODO: generate proof
  return @[42'u8]

proc init*(_: type StorageHandler, node: CodexNodeRef): StorageHandler =
  let
    self = StorageHandler(node: node)

  if hostContracts =? self.node.contracts.host:
    hostContracts.sales.onStore =
      proc(
        request: StorageRequest,
        slot: UInt256,
        onBatch: BatchProc): Future[?!void] = self.onStore(request, slot, onBatch)

    hostContracts.sales.onExpiryUpdate =
      proc(rootCid: string, expiry: SecondsSince1970): Future[?!void] =
        self.onExpiryUpdate(rootCid, expiry)

    hostContracts.sales.onClear =
      proc(request: StorageRequest, slotIndex: UInt256) =
      # TODO: remove data from local storage
      self.onClear(request, slotIndex)

    hostContracts.sales.onProve =
      proc(slot: Slot, challenge: ProofChallenge): Future[seq[byte]] =
        # TODO: generate proof
        self.onProve(slot, challenge)

  self
