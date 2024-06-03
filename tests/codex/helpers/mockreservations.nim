import pkg/chronos
import pkg/codex/sales
import pkg/codex/stores
import pkg/questionable/results

type
  MockReservations* = ref object of Reservations
    createReservationThrowBytesOutOfBoundsError: bool

func new*(
    _: type MockReservations,
    repo: RepoStore
): MockReservations =
  ## Create a mock clock instance
  MockReservations(repo: repo)

proc setCreateReservationThrowBytesOutOfBoundsError*(self: MockReservations, flag: bool) =
  self.createReservationThrowBytesOutOfBoundsError = flag

method createReservation*(
  self: MockReservations,
  availabilityId: AvailabilityId,
  slotSize: UInt256,
  requestId: RequestId,
  slotIndex: UInt256): Future[?!Reservation] {.async.} =
    if self.createReservationThrowBytesOutOfBoundsError:
      let error = newException(
        BytesOutOfBoundsError,
        "trying to reserve an amount of bytes that is greater than the total size of the Availability")
      return failure(error)

    return await procCall createReservation(Reservations(self), availabilityId, slotSize, requestId, slotIndex)

