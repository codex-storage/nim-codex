import pkg/chronos
import pkg/questionable
import pkg/datastore
import pkg/stew/byteutils
import pkg/codex/contracts/requests
import pkg/codex/sales/states/preparing
import pkg/codex/sales/states/downloading
import pkg/codex/sales/states/cancelled
import pkg/codex/sales/states/failed
import pkg/codex/sales/states/filled
import pkg/codex/sales/states/ignored
import pkg/codex/sales/states/errored
import pkg/codex/sales/salesagent
import pkg/codex/sales/salescontext
import pkg/codex/sales/reservations
import pkg/codex/stores/repostore
import ../../../asynctest
import ../../helpers
import ../../examples
import ../../helpers/mockmarket
import ../../helpers/mockclock

asyncchecksuite "sales state 'preparing'":
  let request = StorageRequest.example
  let slotIndex = (request.ask.slots div 2).u256
  let market = MockMarket.new()
  let clock = MockClock.new()
  var agent: SalesAgent
  var state: SalePreparing
  var repo: RepoStore
  var availability: Availability
  var context: SalesContext

  setup:    
    availability = Availability(
      totalSize: request.ask.slotSize + 100.u256,
      freeSize: request.ask.slotSize + 100.u256,
      duration: request.ask.duration + 60.u256,
      minPrice: request.ask.pricePerSlot - 10.u256,
      maxCollateral: request.ask.collateral + 400.u256
    )
    let repoDs = SQLiteDatastore.new(Memory).tryGet()
    let metaDs = SQLiteDatastore.new(Memory).tryGet()
    repo = RepoStore.new(repoDs, metaDs)
    await repo.start()

    state = SalePreparing.new()
    context = SalesContext(
      market: market,
      clock: clock
    )
    context.reservations = Reservations.new(repo)
    agent = newSalesAgent(context,
                          request.id,
                          slotIndex,
                          request.some)

  teardown:
    await repo.stop()

  test "switches to cancelled state when request expires":
    let next = state.onCancelled(request)
    check !next of SaleCancelled

  test "switches to failed state when request fails":
    let next = state.onFailed(request)
    check !next of SaleFailed

  test "switches to filled state when slot is filled":
    let next = state.onSlotFilled(request.id, slotIndex)
    check !next of SaleFilled

  proc createAvailability() =
    let a = waitFor context.reservations.createAvailability(
      availability.totalSize,
      availability.duration,
      availability.minPrice,
      availability.maxCollateral
    )
    availability = a.get

  test "run switches to ignored when no availability":
    let next = await state.run(agent)
    check !next of SaleIgnored
  
  test "run switches to downloading when reserved":
    createAvailability()
    let next = await state.run(agent)
    check !next of SaleDownloading

  test "run switches to errored when reserve failed":
    createAvailability()
    state.doThing = proc(): Future[void] {.async, gcsafe.} =
      # Mess up availability, causes createReservation to fail:
      (await repo.metaDs.put(availability.id.key.tryGet(), "A!".toBytes())).tryGet()

    let next = await state.run(agent)
    check !next of SaleErrored

  test "run switches to ignored when reserve fails with BytesOutOfBounds":
    createAvailability()
    state.doThing = proc(): Future[void] {.async, gcsafe.} =
      # Oops we don't have any free bytes after all.
      availability.freeSize = 0.u256
      (await repo.metaDs.put(availability.id.key.tryGet(), availability.toJson.toBytes)).tryGet()

    let next = await state.run(agent)
    check !next of SaleIgnored