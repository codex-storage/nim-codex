## Nim-Codex
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/chronos
import pkg/upraises
import pkg/json_serialization
import pkg/stint

push: {.upraises: [].}

import pkg/datastore
import pkg/stew/byteutils
import ../stores
import ../namespaces

type
  Availability* = object
    id*: array[32, byte]
    size*: UInt256
    duration*: UInt256
    minPrice*: UInt256
  Reservations* = object
    availability: RepoStore
    state: Datastore
  NotAvailableError* = object of CodexError

const
  SalesKey = (CodexMetaKey / "sales").tryGet # TODO: move to sales module
  ReservationsKey = (SalesKey / "reservations").tryGet

proc new*(_: type Reservations, repo: RepoStore, data: Datastore): Reservations =
  let r = Reservations(availability: repo, state: data)
  return r

proc available*(self: Reservations): Future[uint] {.async.} =
  # TODO: query RepoStore when API is ready
  return 100_000_000.uint

proc available*(self: Reservations, bytes: uint): Future[bool] {.async.} =
  return bytes < (await self.available)

proc key(availability: Availability): Key =
  (ReservationsKey / $availability.id).tryGet

proc reserve*(self: Reservations,
              availability: Availability): Future[?!void] {.async.} =

  # TODO: reconcile data sizes -- availability uses UInt256 and RepoStore
  # uses uint, thus the need to truncate
  if err =? (await self.availability.reserve(
    availability.size.truncate(uint))).errorOption:
    return failure(err)

  if err =? (await self.state.put(
    availability.key,
    @(availability.toJson.toBytes))).errorOption:
    return failure(err)

  return success()

proc release*(self: Reservations,
              availability: Availability): Future[?!void] {.async.} =

  # TODO: reconcile data sizes -- availability uses UInt256 and RepoStore
  # uses uint, thus the need to truncate
  if err =? (await self.availability.release(
    availability.size.truncate(uint))).errorOption:
    return failure(err)

  if err =? (await self.state.delete(availability.key)).errorOption:
    return failure(err)

  return success()
