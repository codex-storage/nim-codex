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
import pkg/nimcrypto

push: {.upraises: [].}

import pkg/datastore
import pkg/stew/byteutils
import ../stores
import ../contracts/requests

export requests

type
  AvailabilityId* = distinct array[32, byte]
  Availability* = object
    id*: AvailabilityId
    size*: UInt256
    duration*: UInt256
    minPrice*: UInt256
    slotId*: ?SlotId
  Reservations* = ref object
    repo: RepoStore
  GetNext* = proc(): Future[?Availability] {.upraises: [], gcsafe, closure.}
  AvailabilityIter* = ref object
    finished*: bool
    next*: GetNext
  AvailabilityError* = object of CodexError
  AvailabilityNotExistsError* = object of AvailabilityError
  AvailabilityAlreadyExistsError* = object of AvailabilityError
  AvailabilityReserveFailedError* = object of AvailabilityError
  AvailabilityReleaseFailedError* = object of AvailabilityError
  AvailabilityDeleteFailedError* = object of AvailabilityError
  AvailabilityPutFailedError* = object of AvailabilityError
  AvailabilityGetFailedError* = object of AvailabilityError
  AvailabilityUpdateError* = object of AvailabilityError

const
  SalesKey = (CodexMetaKey / "sales").tryGet # TODO: move to sales module
  ReservationsKey = (SalesKey / "reservations").tryGet

proc new*(
  T: type Reservations,
  repo: RepoStore): Reservations =

  T(repo: repo)

proc init*(
  _: type Availability,
  size: UInt256,
  duration: UInt256,
  minPrice: UInt256): Availability =

  var id: array[32, byte]
  doAssert randomBytes(id) == 32
  Availability(id: AvailabilityId(id), size: size, duration: duration, minPrice: minPrice)

func toArray*(id: AvailabilityId): array[32, byte] =
  array[32, byte](id)

proc `==`*(x, y: AvailabilityId): bool {.borrow.}
proc `==`*(x, y: Availability): bool =
  x.id == y.id and
  x.size == y.size and
  x.duration == y.duration and
  x.minPrice == y.minPrice

proc toErr[E1: ref CatchableError, E2: AvailabilityError](
  e1: E1,
  _: type E2,
  msg: string = "see inner exception"): ref E2 =

  return newException(E2, msg, e1)

proc writeValue*(
  writer: var JsonWriter,
  value: SlotId | AvailabilityId) {.upraises:[IOError].} =

  mixin writeValue
  writer.writeValue value.toArray

proc readValue*[T: SlotId | AvailabilityId](
  reader: var JsonReader,
  value: var T) {.upraises: [SerializationError, IOError].} =

  mixin readValue
  value = T reader.readValue(T.distinctBase)

func used*(availability: Availability): bool =
  availability.slotId.isSome

func key(id: AvailabilityId): ?!Key =
  (ReservationsKey / id.toArray.toHex)

func key*(availability: Availability): ?!Key =
  return availability.id.key

func available*(self: Reservations): uint =
  return self.repo.quotaMaxBytes - self.repo.totalUsed

func available*(self: Reservations, bytes: uint): bool =
  return bytes < self.available()

proc exists*(
  self: Reservations,
  id: AvailabilityId): Future[?!bool] {.async.} =

  without key =? id.key, err:
    return failure(err)

  let exists = await self.repo.metaDs.contains(key)
  return success(exists)

proc get*(
  self: Reservations,
  id: AvailabilityId): Future[?!Availability] {.async.} =

  if exists =? (await self.exists(id)) and not exists:
    let err = newException(AvailabilityNotExistsError,
      "Availability does not exist")
    return failure(err)

  without key =? id.key, err:
    return failure(err)

  without serialized =? await self.repo.metaDs.get(key), err:
    return failure(err)

  without availability =? Json.decode(serialized, Availability).catch, err:
    return failure(err)

  return success availability

proc update(
  self: Reservations,
  availability: Availability,
  slotId: ?SlotId): Future[?!void] {.async.} =

  without var updated =? await self.get(availability.id), err:
    return failure(err)

  updated.slotId = slotId

  without key =? availability.key, err:
    return failure(err)

  if err =? (await self.repo.metaDs.put(
    key,
    @(updated.toJson.toBytes))).errorOption:
    return failure(err)

  return success()

proc reserve*(
  self: Reservations,
  availability: Availability): Future[?!void] {.async.} =

  if exists =? (await self.exists(availability.id)) and exists:
    let err = newException(AvailabilityAlreadyExistsError,
      "Availability already exists")
    return failure(err)

  without key =? availability.key, err:
    return failure(err)

  if err =? (await self.repo.metaDs.put(
    key,
    @(availability.toJson.toBytes))).errorOption:
    return failure(err)

  # TODO: reconcile data sizes -- availability uses UInt256 and RepoStore
  # uses uint, thus the need to truncate
  if reserveInnerErr =? (await self.repo.reserve(
    availability.size.truncate(uint))).errorOption:

    let reserveErr = reserveInnerErr.toErr(AvailabilityReserveFailedError,
      "Availability reservation failed")

    # rollback persisted availability
    if rollbackInnerErr =? (await self.repo.metaDs.delete(key)).errorOption:
      let rollbackErr = rollbackInnerErr.toErr(AvailabilityDeleteFailedError,
        "Failed to delete persisted availability during rollback")
      rollbackInnerErr.parent = reserveErr
      return failure(rollbackErr)

    return failure(reserveErr)

  return success()

# TODO: call site not yet determined. Perhaps reuse of Availabilty should be set
# on creation (from the REST endpoint). Reusable availability wouldn't get
# released after contract completion. Non-reusable availability would.
proc release*(
  self: Reservations,
  id: AvailabilityId): Future[?!void] {.async.} =

  without availability =? (await self.get(id)), err:
    return failure(err.toErr(AvailabilityGetFailedError))

  without key =? id.key, err:
    return failure(err)

  if err =? (await self.repo.metaDs.delete(key)).errorOption:
    return failure(err.toErr(AvailabilityDeleteFailedError))

  # TODO: reconcile data sizes -- availability uses UInt256 and RepoStore
  # uses uint, thus the need to truncate
  if releaseInnerErr =? (await self.repo.release(
    availability.size.truncate(uint))).errorOption:

    let releaseErr = releaseInnerErr.toErr(AvailabilityReleaseFailedError)

    # rollback delete
    if rollbackInnerErr =? (await self.repo.metaDs.put(
      key,
      @(availability.toJson.toBytes))).errorOption:

      let rollbackErr = rollbackInnerErr.toErr(
        AvailabilityPutFailedError,
        "Failed to restore persisted availability during rollback")
      rollbackInnerErr.parent = releaseErr
      return failure(rollbackErr)

    return failure(releaseErr)

  return success()


proc markUsed*(
  self: Reservations,
  availability: Availability,
  slotId: SlotId): Future[?!void] {.async.} =

  return await self.update(availability, some slotId)

proc markUnused*(
  self: Reservations,
  availability: Availability): Future[?!void] {.async.} =

  return await self.update(availability, none SlotId)

iterator items*(self: AvailabilityIter): Future[?Availability] =
  while not self.finished:
    yield self.next()

proc availabilities*(
  self: Reservations): Future[?!AvailabilityIter] {.async.} =

  var iter = AvailabilityIter()
  let query = Query.init(ReservationsKey)

  without results =? await self.repo.metaDs.query(query), err:
    return failure(err)

  proc next(): Future[?Availability] {.async.} =
    await idleAsync()
    iter.finished = results.finished
    if not results.finished and
      r =? (await results.next()) and
      serialized =? r.data and
      serialized.len > 0:

      return some Json.decode(string.fromBytes(serialized), Availability)

    return none Availability

  iter.next = next
  return success iter

proc unused*(r: Reservations): Future[?!seq[Availability]] {.async.} =
  var ret: seq[Availability] = @[]

  without availabilities =? (await r.availabilities), err:
    return failure(err)

  for a in availabilities:
    if availability =? (await a) and not availability.used:
      ret.add availability

  return success(ret)

proc find*(
  self: Reservations,
  size, duration, minPrice: UInt256,
  used: bool): Future[?Availability] {.async.} =

  without availabilities =? (await self.availabilities), err:
    error "failed to get all availabilities", error = err.msg
    return none Availability

  for a in availabilities:
    if availability =? (await a):
      let satisfiesUsed = (used and availability.used) or
                          (not used and not availability.used)
      if satisfiesUsed and
        size <= availability.size and
        duration <= availability.duration and
        minPrice >= availability.minPrice:
        return some availability

proc find*(
  self: Reservations,
  slotId: SlotId): Future[?Availability] {.async.} =

  without availabilities =? (await self.availabilities), err:
    error "failed to get all availabilities", error = err.msg
    return none Availability

  for a in availabilities:
    if availability =? (await a) and
       availability.slotId == some slotId:
        return some availability
