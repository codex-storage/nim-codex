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
  Availability* = ref object
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
    requestId* {.serialize.}: RequestId
    slotIndex* {.serialize.}: UInt256
  Reservations* = ref object
    repo: RepoStore
    onAvailabilityAdded: ?OnAvailabilityAdded
    onMarkUnused: ?OnAvailabilityAdded
  GetNext* = proc(): Future[?seq[byte]] {.upraises: [], gcsafe, closure.}
  OnAvailabilityAdded* = proc(availability: Availability): Future[void] {.upraises: [], gcsafe.}
  StorableIter* = ref object
    finished*: bool
    next*: GetNext
  ReservationsError* = object of CodexError
  ReserveFailedError* = object of ReservationsError
  ReleaseFailedError* = object of ReservationsError
  DeleteFailedError* = object of ReservationsError
  GetFailedError* = object of ReservationsError
  NotExistsError* = object of ReservationsError
  SerializationError* = object of ReservationsError
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
  requestId: RequestId,
  slotIndex: UInt256
): Reservation =

  var id: array[32, byte]
  doAssert randomBytes(id) == 32
  Reservation(id: ReservationId(id), availabilityId: availabilityId, size: size, requestId: requestId, slotIndex: slotIndex)

func toArray(id: SomeStorableId): array[32, byte] =
  array[32, byte](id)

proc `==`*(x, y: AvailabilityId): bool {.borrow.}
proc `==`*(x, y: ReservationId): bool {.borrow.}
proc `==`*(x, y: Reservation): bool =
  x.id == y.id and
  x.availabilityId == y.availabilityId and
  x.size == y.size and
  x.requestId == y.requestId and
  x.slotIndex == y.slotIndex
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
    let err = newException(NotExistsError, "object with key " & $key & " does not exist")
    return failure(err)

  without serialized =? await self.repo.metaDs.get(key), error:
    return failure(error.toErr(GetFailedError))

  return success serialized

proc get*(
  self: Reservations,
  key: Key,
  T: type SomeStorableObject): Future[?!T] {.async.} =

  without serialized =? await self.getImpl(key), error:
    return failure(error)

  without obj =? T.fromJson(serialized), error:
    return failure(error.toErr(SerializationError))

  return success obj

proc update(
  self: Reservations,
  obj: SomeStorableObject): Future[?!void] {.async.} =

  trace "updating " & $(obj.type), id = obj.id, size = obj.size

  without key =? obj.key, error:
    return failure(error)

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

  logScope:
    reservationId
    availabilityId

  trace "deleting reservation"
  without key =? key(reservationId, availabilityId), error:
    return failure(error)

  without reservation =? (await self.get(key, Reservation)), error:
    if error of NotExistsError:
      return success()
    else:
      return failure(error)

  if reservation.size > 0.u256:
    trace "returning remaining reservation bytes to availability",
      size = reservation.size

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

  trace "creating availability", size, duration, minPrice, maxCollateral

  let availability = Availability.init(
    size, duration, minPrice, maxCollateral
  )
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
  requestId: RequestId,
  slotIndex: UInt256
): Future[?!Reservation] {.async.} =

  trace "creating reservation", availabilityId, slotSize, requestId, slotIndex

  let reservation = Reservation.init(availabilityId, slotSize, requestId, slotIndex)

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

  # update availability with reduced size
  if updateErr =? (await self.update(availability)).errorOption:

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

  without key =? key(reservationId, availabilityId), error:
    return failure(error)

  without var reservation =? (await self.get(key, Reservation)), error:
    return failure(error)

  if reservation.size < bytes.u256:
    let error = newException(BytesOutOfBoundsError,
      "trying to release an amount of bytes that is greater than the total " &
      "size of the Reservation")
    return failure(error)

  if releaseErr =? (await self.repo.release(bytes)).errorOption:
    return failure(releaseErr.toErr(ReleaseFailedError))

  reservation.size -= bytes.u256

  # persist partially used Reservation with updated size
  if err =? (await self.update(reservation)).errorOption:

    # rollback release if an update error encountered
    trace "rolling back release"
    if rollbackErr =? (await self.repo.reserve(bytes)).errorOption:
      rollbackErr.parent = err
      return failure(rollbackErr)
    return failure(err)

  return success()

iterator items(self: StorableIter): Future[?seq[byte]] =
  while not self.finished:
    yield self.next()

proc storables(
  self: Reservations,
  T: type SomeStorableObject
): Future[?!StorableIter] {.async.} =

  var iter = StorableIter()
  let query = Query.init(ReservationsKey)
  when T is Availability:
    # should indicate key length of 4, but let the .key logic determine it
    without defaultKey =? AvailabilityId.default.key, error:
      return failure(error)
  else:
    # should indicate key length of 5, but let the .key logic determine it
    without defaultKey =? key(ReservationId.default, AvailabilityId.default), error:
      return failure(error)

  without results =? await self.repo.metaDs.query(query), error:
    return failure(error)

  proc next(): Future[?seq[byte]] {.async.} =
    await idleAsync()
    iter.finished = results.finished
    if not results.finished and
       res =? (await results.next()) and
       res.data.len > 0 and
       key =? res.key and
       key.namespaces.len == defaultKey.namespaces.len:

      return some res.data

    return none seq[byte]

  iter.next = next
  return success iter

proc all*(
  self: Reservations,
  T: type SomeStorableObject
): Future[?!seq[T]] {.async.} =

  var ret: seq[T] = @[]

  without storables =? (await self.storables(T)), error:
    return failure(error)

  # NOTICE: there is a swallowed deserialization error
  for storable in storables.items:
    if bytes =? (await storable) and
      obj =? T.fromJson(bytes):
        ret.add obj

  return success(ret)

proc findAvailability*(
  self: Reservations,
  size, duration, minPrice, collateral: UInt256
): Future[?Availability] {.async.} =

  without storables =? (await self.storables(Availability)), error:
    error "failed to get all storables", error = error.msg
    return none Availability

  for item in storables.items:
    if bytes =? (await item) and
       availability =? Availability.fromJson(bytes):

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
