import std/random
import std/times
import pkg/questionable
import pkg/codex/contracts/requests
import pkg/codex/sales/states/cancelled
import pkg/codex/sales/states/downloading
import pkg/codex/sales/states/failed
import pkg/codex/sales/states/filled
import pkg/codex/sales/states/initialproving
import pkg/codex/sales/states/errored
import pkg/codex/sales/salesagent
import pkg/codex/sales/salescontext
import pkg/codex/stores/repostore
import pkg/datastore
import ../../examples
import ../../helpers
import ../../helpers/mockmarket
import ../../../asynctest

suite "sales state 'downloading'":
  let request = StorageRequest.example
  let slotIndex = request.ask.slots div 2
  let slotId = slotId(request.id, slotIndex)
  var market: MockMarket
  var context: SalesContext
  var agent: SalesAgent
  var state: SaleDownloading
  var repo: RepoStore
  var repoDs: Datastore
  var metaDs: Datastore
  var reservations: Reservations
  let repoTmp = TempLevelDb.new()
  let metaTmp = TempLevelDb.new()

  proc createAvailability(enabled = true, until = 0.SecondsSince1970): Availability =
    let collateralPerByte = uint8.example.u256
    let example = Availability.example(collateralPerByte)
    let totalSize = rand(100000 .. 200000).uint64
    let totalCollateral = totalSize.u256 * collateralPerByte
    let availability = waitFor reservations.createAvailability(
      totalSize, example.duration, example.minPricePerBytePerSecond, totalCollateral,
      enabled, until,
    )
    return availability.get

  proc createReservation(availability: Availability): Reservation =
    let size = rand(1 ..< availability.freeSize.int)
    let validUntil = getTime().toUnix() + 30.SecondsSince1970
    let reservation = waitFor reservations.createReservation(
      availability.id, size.uint64, RequestId.example, uint64.example, 1.u256,
      validUntil,
    )
    return reservation.get

  setup:
    market = MockMarket.new()
    context = SalesContext(market: market)
    agent = newSalesAgent(context, request.id, slotIndex, request.some)

    let onStore: OnStore = proc(
        request: StorageRequest, slot: uint64, blocksCb: BlocksCb, isRepairing: bool
    ): Future[?!void] {.gcsafe, async: (raises: [CancelledError]).} =
      return success()

    repoDs = repoTmp.newDb()
    metaDs = metaTmp.newDb()
    repo = RepoStore.new(repoDs, metaDs)
    reservations = Reservations.new(repo)

    let availability = createAvailability()
    let reservation = createReservation(availability)

    context.onStore = some onStore
    agent.data.reservation = some reservation
    state = SaleDownloading.new()

  teardown:
    await repoTmp.destroyDb()
    await metaTmp.destroyDb()

  test "switches to cancelled state when request expires":
    let next = state.onCancelled(request)
    check !next of SaleCancelled

  test "switches to failed state when request fails":
    let next = state.onFailed(request)
    check !next of SaleFailed

  test "switches to filled state when slot is filled":
    let next = state.onSlotFilled(request.id, slotIndex)
    check !next of SaleFilled

  test "switches to filled state after download when slot is filled":
    market.slotState[slotId] = SlotState.Filled
    let next = await state.run(agent)
    check !next of SaleFilled

  test "switches to initial proving state after download when slot is not filled":
    market.slotState[slotId] = SlotState.Free
    let next = await state.run(agent)
    check !next of SaleInitialProving

  test "calls onStore during download":
    var onStoreCalled = false
    let onStore: OnStore = proc(
        request: StorageRequest, slot: uint64, blocksCb: BlocksCb, isRepairing: bool
    ): Future[?!void] {.gcsafe, async: (raises: [CancelledError]).} =
      onStoreCalled = true
      return success()

    context.onStore = some onStore
    discard await state.run(agent)
    check onStoreCalled

  test "switches to error state if onStore fails":
    var onStoreCalled = false
    let onStore: OnStore = proc(
        request: StorageRequest, slot: uint64, blocksCb: BlocksCb, isRepairing: bool
    ): Future[?!void] {.gcsafe, async: (raises: [CancelledError]).} =
      return failure "some error"

    context.onStore = some onStore
    let next = await state.run(agent)
    check !next of SaleErrored
    check SaleErrored(!next).error.msg == "some error"
