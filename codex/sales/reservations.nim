## Nim-Codex
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.
##
##                                                       +--------------------------------------+
##                                                       |            RESERVATION               |
## +--------------------------------------+              |--------------------------------------|
## |            AVAILABILITY              |              | ReservationId  | id             | PK |
## |--------------------------------------|              |--------------------------------------|
## | AvailabilityId | id            | PK  |<-||-------o<-| AvailabilityId | availabilityId | FK |
## |--------------------------------------|              |--------------------------------------|
## | UInt256        | size          |     |              | UInt256        | size           |    |
## |--------------------------------------|              |--------------------------------------|
## | UInt256        | duration      |     |              | SlotId         | slotId         |    |
## |--------------------------------------|              +--------------------------------------+
## | UInt256        | minPrice      |     |
## |--------------------------------------|
## | UInt256        | maxCollateral |     |
## +--------------------------------------+

import pkg/upraises
push: {.upraises: [].}

import std/typetraits
import pkg/chronos
import pkg/chronicles
import pkg/datastore
import pkg/nimcrypto
import pkg/questionable
import pkg/questionable/results
import pkg/stint
import pkg/stew/byteutils
import ../stores
import ../contracts/requests
import ../utils/json

export requests

logScope:
  topics = "sales reservations"

type
  AvailabilityId* = distinct array[32, byte]
  ReservationId* = distinct array[32, byte]
  SomeStorableObject = Availability | Reservation
  SomeStorableId = AvailabilityId | ReservationId
  Availability* = object
    id* {.serialize.}: AvailabilityId
    size* {.serialize.}: UInt256
    duration* {.serialize.}: UInt256
    minPrice* {.serialize.}: UInt256
    maxCollateral* {.serialize.}: UInt256
    # used*: bool
  Reservation* = ref object
    id* {.serialize.}: ReservationId
    availabilityId* {.serialize.}: AvailabilityId
    size* {.serialize.}: UInt256
    slotId* {.serialize.}: SlotId
  Reservations* = ref object
    repo: RepoStore
    onAvailabilityAdded: ?OnAvailabilityAdded
    onMarkUnused: ?OnAvailabilityAdded
  GetNext* = proc(): Future[?Availability] {.upraises: [], gcsafe, closure.}
  OnAvailabilityAdded* = proc(availability: Availability): Future[void] {.upraises: [], gcsafe.}
  AvailabilityIter* = ref object
    finished*: bool
    next*: GetNext
  ReservationsError* = object of CodexError
  AlreadyExistsError* = object of ReservationsError
  ReserveFailedError* = object of ReservationsError
  ReleaseFailedError* = object of ReservationsError
  DeleteFailedError* = object of ReservationsError
  GetFailedError* = object of ReservationsError
  UpdateFailedError* = object of ReservationsError
  BytesOutOfBoundsError* = object of ReservationsError

const
  SalesKey = (CodexMetaKey / "sales").tryGet # TODO: move to sales module
  ReservationsKey = (SalesKey / "reservations").tryGet

proc new*(T: type Reservations,
          repo: RepoStore): Reservations =

  T(repo: repo)

proc init*(
  _: type Availability,
  size: UInt256,
  duration: UInt256,
  minPrice: UInt256,
  maxCollateral: UInt256): Availability =

  var id: array[32, byte]
  doAssert randomBytes(id) == 32
  Availability(id: AvailabilityId(id), size: size, duration: duration, minPrice: minPrice, maxCollateral: maxCollateral)

proc init*(
  _: type Reservation,
  availabilityId: AvailabilityId,
  size: UInt256,
  slotId: SlotId
): Reservation =

  var id: array[32, byte]
  doAssert randomBytes(id) == 32
  Reservation(id: ReservationId(id), availabilityId: availabilityId, size: size, slotId: slotId)

func toArray(id: SomeStorableId): array[32, byte] =
  array[32, byte](id)

proc `==`*(x, y: AvailabilityId): bool {.borrow.}
proc `==`*(x, y: ReservationId): bool {.borrow.}
proc `==`*(x, y: Reservation): bool =
  x.id == y.id and
  x.availabilityId == y.availabilityId and
  x.size == y.size and
  x.slotId == y.slotId
proc `==`*(x, y: Availability): bool =
  x.id == y.id and
  x.size == y.size and
  x.duration == y.duration and
  x.maxCollateral == y.maxCollateral and
  x.minPrice == y.minPrice

proc `$`*(id: SomeStorableId): string = id.toArray.toHex

proc toErr[E1: ref CatchableError, E2: ReservationsError](
  e1: E1,
  _: type E2,
  msg: string = e1.msg): ref E2 =

  return newException(E2, msg, e1)

proc writeValue*(
  writer: var JsonWriter,
  value: SomeStorableId) {.upraises:[IOError].} =
  ## used for chronicles' logs

  mixin writeValue
  writer.writeValue %value

proc `onAvailabilityAdded=`*(self: Reservations,
                            onAvailabilityAdded: OnAvailabilityAdded) =
  self.onAvailabilityAdded = some onAvailabilityAdded

func key*(id: AvailabilityId): ?!Key =
  ## sales / reservations / <availabilityId>
  (ReservationsKey / $id)

func key*(reservationId: ReservationId, availabilityId: AvailabilityId): ?!Key =
  ## sales / reservations / <availabilityId> / <reservationId>
  (availabilityId.key / $reservationId)

func key*(availability: Availability): ?!Key =
  return availability.id.key

func key*(reservation: Reservation): ?!Key =
  return key(reservation.id, reservation.availabilityId)

func available*(self: Reservations): uint = self.repo.available

func hasAvailable*(self: Reservations, bytes: uint): bool =
  self.repo.available(bytes)

proc exists*(
  self: Reservations,
  key: Key): Future[bool] {.async.} =

  let exists = await self.repo.metaDs.contains(key)
  return exists

proc getImpl(
  self: Reservations,
  key: Key): Future[?!seq[byte]] {.async.} =

  if exists =? (await self.exists(key)) and not exists:
    let err = newException(GetFailedError, "object with key " & $key & " does not exist")
    return failure(err)

  without serialized =? await self.repo.metaDs.get(key), err:
    return failure(err.toErr(GetFailedError))

  return success serialized

proc get*(
  self: Reservations,
  key: Key,
  T: type SomeStorableObject): Future[?!T] {.async.} =

  without serialized =? await self.getImpl(key), err:
    return failure(err)

  without obj =? T.fromJson(serialized), err:
    return failure(err.toErr(GetFailedError))

  return success obj

proc update(
  self: Reservations,
  obj: SomeStorableObject): Future[?!void] {.async.} =

  trace "updating " & $(obj.type), id = obj.id, size = obj.size

  without key =? obj.key, err:
    return failure(err)

  if err =? (await self.repo.metaDs.put(
    key,
    @(obj.toJson.toBytes)
  )).errorOption:
    return failure(err.toErr(UpdateFailedError))

  return success()

proc delete(
  self: Reservations,
  key: Key): Future[?!void] {.async.} =

  trace "deleting object", key

  if exists =? (await self.exists(key)) and not exists:
    return success()

  if err =? (await self.repo.metaDs.delete(key)).errorOption:
    return failure(err.toErr(DeleteFailedError))

  return success()

proc deleteReservation*(
  self: Reservations,
  reservationId: ReservationId,
  availabilityId: AvailabilityId): Future[?!void] {.async.} =

  trace "deleting reservation", reservationId, availabilityId

  without key =? key(reservationId, availabilityId), err:
    return failure(err)

  without reservation =? (await self.get(key, Reservation)), error:
    return failure(error)

  if reservation.size > 0.u256:
    # return remaining bytes to availability
    without availabilityKey =? availabilityId.key, error:
      return failure(error)

    without var availability =? await self.get(availabilityKey, Availability), error:
      return failure(error)

    availability.size += reservation.size

    if updateErr =? (await self.update(availability)).errorOption:
      return failure(updateErr)

  if err =? (await self.repo.metaDs.delete(key)).errorOption:
    return failure(err.toErr(DeleteFailedError))

  return success()

proc createAvailability*(
  self: Reservations,
  size: UInt256,
  duration: UInt256,
  minPrice: UInt256,
  maxCollateral: UInt256): Future[?!Availability] {.async.} =

  let availability = Availability.init(
    size, duration, minPrice, maxCollateral
  )

  without key =? availability.key, err:
    return failure(err)

  if exists =? (await self.exists(key)) and exists:
    let err = newException(AlreadyExistsError,
      "Availability already exists")
    return failure(err)

  let bytes = availability.size.truncate(uint)

  if reserveErr =? (await self.repo.reserve(bytes)).errorOption:
    return failure(reserveErr.toErr(ReserveFailedError))

  if updateErr =? (await self.update(availability)).errorOption:

    # rollback the reserve
    trace "rolling back reserve"
    if rollbackErr =? (await self.repo.release(bytes)).errorOption:
      rollbackErr.parent = updateErr
      return failure(rollbackErr)

    return failure(updateErr)

  if onAvailabilityAdded =? self.onAvailabilityAdded:
    try:
      await onAvailabilityAdded(availability)
    except CatchableError as e:
      # we don't have any insight into types of errors that `onProcessSlot` can
      # throw because it is caller-defined
      warn "Unknown error during 'onAvailabilityAdded' callback",
        availabilityId = availability.id, error = e.msg

  return success(availability)

proc createReservation*(
  self: Reservations,
  availabilityId: AvailabilityId,
  slotSize: UInt256,
  slotId: SlotId
): Future[?!Reservation] {.async.} =

  let reservation = Reservation.init(availabilityId, slotSize, slotId)

  without key =? reservation.key, error:
    return failure(error)

  if exists =? (await self.exists(key)) and exists:
    let err = newException(AlreadyExistsError,
      "Reservation already exists")
    return failure(err)

  without availabilityKey =? availabilityId.key, error:
    return failure(error)

  without var availability =? await self.get(availabilityKey, Availability), error:
    return failure(error)

  if availability.size < slotSize:
    let error = newException(BytesOutOfBoundsError, "trying to reserve an " &
      "amount of bytes that is greater than the total size of the Availability")
    return failure(error)

  if createResErr =? (await self.update(reservation)).errorOption:
    return failure(createResErr)

  # reduce availability size by the slot size, which is now accounted for in
  # the newly created Reservation
  availability.size -= slotSize

  # remove availabilities with no reserved bytes remaining
  if availability.size == 0.u256:
    without key =? availability.key, error:
      return failure(error)

    if err =? (await self.delete(key)).errorOption:
      # rollbackRelease(err)
      return failure(err)

  # otherwise, update availability with reduced size
  elif updateErr =? (await self.update(availability)).errorOption:

    trace "rolling back reservation creation"

    without key =? reservation.key, keyError:
      keyError.parent = updateErr
      return failure(keyError)

    # rollback the reservation creation
    if rollbackErr =? (await self.delete(key)).errorOption:
      rollbackErr.parent = updateErr
      return failure(rollbackErr)

    return failure(updateErr)

  return success(reservation)

proc release*(
  self: Reservations,
  reservationId: ReservationId,
  availabilityId: AvailabilityId,
  bytes: uint): Future[?!void] {.async.} =

  logScope:
    topics = "release"
    bytes
    reservationId
    availabilityId

  trace "releasing bytes and updating reservation"

  without key =? key(reservationId, availabilityId), err:
    return failure(err)

  without var reservation =? (await self.get(key, Reservation)), err:
    return failure(err)

  if reservation.size < bytes.u256:
    let error = newException(BytesOutOfBoundsError,
      "trying to release an amount of bytes that is greater than the total " &
      "size of the Reservation")
    return failure(error)

  if releaseErr =? (await self.repo.release(bytes)).errorOption:
    return failure(releaseErr.toErr(ReleaseFailedError))

  reservation.size -= bytes.u256

  # TODO: remove used up reservation after sales process is complete

  # persist partially used Reservation with updated size
  if err =? (await self.update(reservation)).errorOption:

    # rollback release if an update error encountered
    trace "rolling back release"
    if rollbackErr =? (await self.repo.reserve(bytes)).errorOption:
      rollbackErr.parent = err
      return failure(rollbackErr)
    return failure(err)

  return success()

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

      return Availability.fromJson(serialized).option

    return none Availability

  iter.next = next
  return success iter

proc allAvailabilities*(r: Reservations): Future[?!seq[Availability]] {.async.} =
  var ret: seq[Availability] = @[]

  without availabilities =? (await r.availabilities), err:
    return failure(err)

  for a in availabilities:
    if availability =? (await a):
      ret.add availability

  return success(ret)

proc find*(
  self: Reservations,
  size, duration, minPrice, collateral: UInt256
): Future[?Availability] {.async.} =


  without availabilities =? (await self.availabilities), err:
    error "failed to get all availabilities", error = err.msg
    return none Availability

  for a in availabilities:
    if availability =? (await a):

      if size <= availability.size and
         duration <= availability.duration and
         collateral <= availability.maxCollateral and
         minPrice >= availability.minPrice:

        trace "availability matched",
          size, availsize = availability.size,
          duration, availDuration = availability.duration,
          minPrice, availMinPrice = availability.minPrice,
          collateral, availMaxCollateral = availability.maxCollateral

        return some availability

      trace "availiability did not match",
        size, availsize = availability.size,
        duration, availDuration = availability.duration,
        minPrice, availMinPrice = availability.minPrice,
        collateral, availMaxCollateral = availability.maxCollateral
