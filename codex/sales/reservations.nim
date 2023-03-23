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
import pkg/questionable
import pkg/questionable/results

push: {.upraises: [].}

import pkg/datastore
import pkg/stew/byteutils
import ../stores
import ../contracts/requests

export requests

type
  AvailabilityId* = distinct array[32, byte]
  Availability* = ref object
    id*: AvailabilityId
    size*: UInt256
    duration*: UInt256
    minPrice*: UInt256
    used*: bool
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

proc new*(
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

func key(id: AvailabilityId): ?!Key =
  (ReservationsKey / id.toArray.toHex)

func key*(availability: Availability): ?!Key =
  return availability.id.key

func available*(self: Reservations): uint = self.repo.available

func available*(self: Reservations, bytes: uint): bool =
  self.repo.available(bytes)

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
  availability: Availability): Future[?!void] {.async.} =

  without key =? availability.key, err:
    return failure(err)

  if err =? (await self.repo.metaDs.put(
    key,
    @(availability.toJson.toBytes))).errorOption:
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

  let bytes = availability.size.truncate(uint)

  if reserveErr =? (await self.repo.reserve(bytes)).errorOption:
    return failure(reserveErr.toErr(AvailabilityReserveFailedError))

  if err =? (await self.update(availability)).errorOption:
    let updateErr = err.toErr(AvailabilityUpdateError, "failure creating availability")

    # rollback the reserve
    if rollbackErr =? (await self.repo.release(bytes)).errorOption:
      rollbackErr.parent = updateErr
      return failure(rollbackErr)

    return failure(updateErr)

  return success()

proc partialRelease*(
  self: Reservations,
  id: AvailabilityId,
  bytes: uint): Future[?!void] {.async.} =

  without availability =? (await self.get(id)), err:
    return failure(err.toErr(AvailabilityGetFailedError))

  without key =? id.key, err:
    return failure(err)

  if releaseErr =? (await self.repo.release(bytes)).errorOption:
    return failure(releaseErr.toErr(AvailabilityReleaseFailedError))

  availability.size = (availability.size.truncate(uint) - bytes).u256

  if err =? (await self.update(availability)).errorOption:
    let updateErr = err.toErr(AvailabilityUpdateError, "failure updating availability size")

    # rollback the release
    if rollbackErr =? (await self.repo.reserve(bytes)).errorOption:
      rollbackErr.parent = updateErr
      return failure(rollbackErr)

    return failure(updateErr)

  return success()


proc markUsed*(
  self: Reservations,
  id: AvailabilityId): Future[?!void] {.async.} =

  without availability =? (await self.get(id)), err:
    return failure(err.toErr(AvailabilityGetFailedError))

  availability.used = true
  return await self.update(availability)

proc markUnused*(
  self: Reservations,
  id: AvailabilityId): Future[?!void] {.async.} =

  without availability =? (await self.get(id)), err:
    return failure(err.toErr(AvailabilityGetFailedError))

  availability.used = false
  return await self.update(availability)

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
    if availability =? (await a) and
      used == availability.used and
      size <= availability.size and
      duration <= availability.duration and
      minPrice >= availability.minPrice:

      return some availability
