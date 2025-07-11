import pkg/chronos
import pkg/codex/sales
import pkg/codex/stores
import pkg/questionable/results
import pkg/codex/clock

type MockReservations* = ref object of Reservations
  createReservationThrowBytesOutOfBoundsError: bool
  createReservationThrowError: ?(ref CatchableError)

proc new*(T: type MockReservations, repo: RepoStore): MockReservations =
  ## Create a mock clock instance
  MockReservations(availabilityLock: newAsyncLock(), repo: repo)

proc setCreateReservationThrowBytesOutOfBoundsError*(
    self: MockReservations, flag: bool
) =
  self.createReservationThrowBytesOutOfBoundsError = flag

proc setCreateReservationThrowError*(
    self: MockReservations, error: ?(ref CatchableError)
) =
  self.createReservationThrowError = error

method createReservation*(
    self: MockReservations,
    availabilityId: AvailabilityId,
    slotSize: uint64,
    requestId: RequestId,
    slotIndex: uint64,
    collateralPerByte: UInt256,
    validUntil: SecondsSince1970,
): Future[?!Reservation] {.async: (raises: [CancelledError]).} =
  if self.createReservationThrowBytesOutOfBoundsError:
    let error = newException(
      BytesOutOfBoundsError,
      "trying to reserve an amount of bytes that is greater than the total size of the Availability",
    )
    return failure(error)
  elif error =? self.createReservationThrowError:
    return failure(error)

  return await procCall createReservation(
    Reservations(self),
    availabilityId,
    slotSize,
    requestId,
    slotIndex,
    collateralPerByte,
    validUntil,
  )
