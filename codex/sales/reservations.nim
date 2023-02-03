## Nim-Codex
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/typetraits
import pkg/chronos
import pkg/chronicles
import pkg/upraises
import pkg/json_serialization
import pkg/json_serialization/std/options
import pkg/stint

push: {.upraises: [].}

import pkg/datastore
import pkg/stew/byteutils
import ../stores
import ../namespaces
import ../contracts/requests

type
  Availability* = object
    id*: array[32, byte]
    size*: UInt256
    duration*: UInt256
    minPrice*: UInt256
    slotId*: ?SlotId
  Reservations* = object
    repo: RepoStore
    persist: Datastore
  # AvailabilityNotExistsError* = object of CodexError

const
  SalesKey = (CodexMetaKey / "sales").tryGet # TODO: move to sales module
  ReservationsKey = (SalesKey / "reservations").tryGet

proc new*(T: type Reservations,
          repo: RepoStore,
          data: Datastore): Reservations =

  T(repo: repo, persist: data)

proc init*(_: type Availability,
          size: UInt256,
          duration: UInt256,
          minPrice: UInt256): Availability =

  var id: array[32, byte]
  doAssert randomBytes(id) == 32
  Availability(id: id, size: size, duration: duration, minPrice: minPrice)

proc key(availability: Availability): ?!Key =
  (ReservationsKey / $availability.id)

proc writeValue*(writer: var JsonWriter, value: SlotId) {.raises:[IOError].} =
  mixin writeValue
  writer.writeValue value.toArray

proc readValue*(reader: var JsonReader, value: var SlotId)
  {.raises: [SerializationError, IOError].} =

  mixin readValue
  value = SlotId reader.readValue(SlotId.distinctBase)

proc available*(self: Reservations): uint =
  return self.repo.quotaMaxBytes - self.repo.totalUsed

proc available*(self: Reservations, bytes: uint): bool =
  return bytes < self.available()

proc reserve*(self: Reservations,
              availability: Availability): Future[?!void] {.async.} =

  # TODO: reconcile data sizes -- availability uses UInt256 and RepoStore
  # uses uint, thus the need to truncate
  if err =? (await self.repo.reserve(
    availability.size.truncate(uint))).errorOption:
    return failure(err)

  without key =? availability.key, err:
    return failure(err)

  if err =? (await self.persist.put(
    key,
    @(availability.toJson.toBytes))).errorOption:
    return failure(err)

  return success()

# TODO: call site not yet determined. Perhaps reuse of Availabilty should be set
# on creation (from the REST endpoint). Reusable availability wouldn't get
# released after contract completion. Non-reusable availability would.
proc release*(self: Reservations,
              availability: Availability): Future[?!void] {.async.} =

  # TODO: reconcile data sizes -- availability uses UInt256 and RepoStore
  # uses uint, thus the need to truncate
  if err =? (await self.repo.release(
    availability.size.truncate(uint))).errorOption:
    return failure(err)

  without key =? availability.key, err:
    return failure(err)

  if err =? (await self.persist.delete(key)).errorOption:
    return failure(err)

  return success()

proc update(self: Reservations,
             availability: Availability,
             slotId: ?SlotId): Future[?!void] {.async.} =

  without key =? availability.key, err:
    return failure(err)

  without serialized =? await self.persist.get(key), err:
    return failure(err)

  without var updated =? Json.decode(serialized, Availability).catch, err:
    return failure(err)

  updated.slotId = slotId

  if err =? (await self.persist.put(
    key,
    @(updated.toJson.toBytes))).errorOption:
    return failure(err)

  return success()

proc markUsed*(self: Reservations,
               availability: Availability,
               slotId: SlotId): Future[?!void] {.async.} =

  return await self.update(availability, some slotId)

proc markUnused*(self: Reservations,
                 availability: Availability): Future[?!void] {.async.} =

  return await self.update(availability, none SlotId)

proc availabilities*(self: Reservations): Future[?!seq[Availability]] {.async.} =
  var availabilities: seq[Availability] = @[]
  let query = Query.init(ReservationsKey)

  without results =? await self.persist.query(query), err:
    return failure(err)

  for fItem in results.items:
    without item =? (await fItem), err:
      return failure(err)

    let serialized = $ item.data
    without availability =? Json.decode(serialized, Availability).catch, err:
      return failure(err)
    availabilities.add availability

  return success(availabilities)

proc find*(self: Reservations,
           size, duration, minPrice: UInt256,
           used: bool): Future[?Availability] {.async.} =

  without availabilities =? (await self.availabilities), err:
    error "failed to get all availabilities", error = err.msg
    return none Availability

  for availability in availabilities:
    let satisfiesUsed = (used and availability.slotId.isSome) or
                        (not used and availability.slotId.isNone)
    if satisfiesUsed and
       size <= availability.size and
       duration <= availability.duration and
       minPrice >= availability.minPrice:
      return some availability
