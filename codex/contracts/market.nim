import std/strformat
import std/strutils
import pkg/ethers
import pkg/upraises
import pkg/questionable
import pkg/lrucache
import ../utils/exceptions
import ../logutils
import ../market
import ./marketplace
import ./proofs
import ./provider

export market

logScope:
  topics = "marketplace onchain market"

type
  OnChainMarket* = ref object of Market
    contract: Marketplace
    signer: Signer
    configuration: MarketplaceConfig
    requestCache: LruCache[string, StorageRequest]
    allowanceLock: AsyncLock

  MarketSubscription = market.Subscription
  EventSubscription = ethers.Subscription
  OnChainMarketSubscription = ref object of MarketSubscription
    eventSubscription: EventSubscription

proc loadConfig(
    market: OnChainMarket
): Future[?!MarketplaceConfig] {.async: (raises: [CancelledError]).} =
  try:
    return success await market.contract.configuration()
  except EthersError:
    let err = getCurrentException()
    return failure newException(
      MarketError,
      "Failed to fetch the config from the Marketplace contract: " & err.msg,
    )

proc load*(
    _: type OnChainMarket,
    contract: Marketplace,
    requestCacheSize: uint16 = DefaultRequestCacheSize,
): Future[?!OnChainMarket] {.async: (raises: [CancelledError]).} =
  without signer =? contract.signer:
    raiseAssert("Marketplace contract should have a signer")

  var requestCache = newLruCache[string, StorageRequest](int(requestCacheSize))

  let market = OnChainMarket(
    contract: contract,
    signer: signer,
    requestCache: requestCache,
  )

  market.configuration = ? await market.loadConfig()

  return success market

proc raiseMarketError(message: string) {.raises: [MarketError].} =
  raise newException(MarketError, message)

func prefixWith(suffix, prefix: string, separator = ": "): string =
  if prefix.len > 0:
    return &"{prefix}{separator}{suffix}"
  else:
    return suffix

template convertEthersError(msg: string = "", body) =
  try:
    body
  except EthersError as error:
    raiseMarketError(error.msgDetail.prefixWith(msg))

template withAllowanceLock*(market: OnChainMarket, body: untyped) =
  if market.allowanceLock.isNil:
    market.allowanceLock = newAsyncLock()
  await market.allowanceLock.acquire()
  try:
    body
  finally:
    try:
      market.allowanceLock.release()
    except AsyncLockError as error:
      raise newException(Defect, error.msg, error)

proc approveFunds(
    market: OnChainMarket, amount: Tokens
) {.async: (raises: [CancelledError, MarketError]).} =
  debug "Approving tokens", amount
  convertEthersError("Failed to approve funds"):
    let tokenAddress = await market.contract.token()
    let token = Erc20Token.new(tokenAddress, market.signer)
    let owner = await market.signer.getAddress()
    let spender = market.contract.address
    market.withAllowanceLock:
      let allowance = await token.allowance(owner, spender)
      discard await token.approve(spender, allowance + amount.u256).confirm(1)

method getSigner*(
    market: OnChainMarket
): Future[Address] {.async: (raises: [CancelledError, MarketError]).} =
  convertEthersError("Failed to get signer address"):
    return await market.signer.getAddress()

method zkeyHash*(market: OnChainMarket): string =
  return market.configuration.proofs.zkeyHash

method periodicity*(market: OnChainMarket): Periodicity =
  let period = market.configuration.proofs.period
  return Periodicity(seconds: period)

method proofTimeout*(market: OnChainMarket): StorageDuration  =
  return market.configuration.proofs.timeout

method repairRewardPercentage*(market: OnChainMarket): uint8 =
  return market.configuration.collateral.repairRewardPercentage

method requestDurationLimit*(market: OnChainMarket): StorageDuration =
  return market.configuration.requestDurationLimit

method proofDowntime*(market: OnChainMarket): uint8 =
  return market.configuration.proofs.downtime

method getPointer*(market: OnChainMarket, slotId: SlotId): Future[uint8] {.async.} =
  convertEthersError("Failed to get slot pointer"):
    let overrides = CallOverrides(blockTag: some BlockTag.pending)
    return await market.contract.getPointer(slotId, overrides)

method myRequests*(market: OnChainMarket): Future[seq[RequestId]] {.async.} =
  convertEthersError("Failed to get my requests"):
    return await market.contract.myRequests

method mySlots*(market: OnChainMarket): Future[seq[SlotId]] {.async.} =
  convertEthersError("Failed to get my slots"):
    let slots = await market.contract.mySlots()
    debug "Fetched my slots", numSlots = len(slots)

    return slots

method requestStorage(
    market: OnChainMarket, request: StorageRequest
) {.async: (raises: [CancelledError, MarketError]).} =
  convertEthersError("Failed to request storage"):
    debug "Requesting storage"
    await market.approveFunds(request.totalPrice())
    discard await market.contract.requestStorage(request).confirm(1)

method getRequest*(
    market: OnChainMarket, id: RequestId
): Future[?StorageRequest] {.async: (raises: [CancelledError]).} =
  try:
    let key = $id

    if key in market.requestCache:
      return some market.requestCache[key]

    let request = await market.contract.getRequest(id)
    market.requestCache[key] = request
    return some request
  except Marketplace_UnknownRequest, KeyError:
    warn "Cannot retrieve the request", error = getCurrentExceptionMsg()
    return none StorageRequest
  except EthersError as e:
    error "Cannot retrieve the request", error = e.msg
    return none StorageRequest

method requestState*(
    market: OnChainMarket, requestId: RequestId
): Future[?RequestState] {.async.} =
  convertEthersError("Failed to get request state"):
    try:
      let overrides = CallOverrides(blockTag: some BlockTag.pending)
      return some await market.contract.requestState(requestId, overrides)
    except Marketplace_UnknownRequest:
      return none RequestState

method slotState*(
    market: OnChainMarket, slotId: SlotId
): Future[SlotState] {.async: (raises: [CancelledError, MarketError]).} =
  convertEthersError("Failed to fetch the slot state from the Marketplace contract"):
    let overrides = CallOverrides(blockTag: some BlockTag.pending)
    return await market.contract.slotState(slotId, overrides)

method getRequestEnd*(
    market: OnChainMarket, id: RequestId
): Future[StorageTimestamp] {.async.} =
  convertEthersError("Failed to get request end"):
    return await market.contract.requestEnd(id)

method requestExpiresAt*(
    market: OnChainMarket, id: RequestId
): Future[StorageTimestamp] {.async.} =
  convertEthersError("Failed to get request expiry"):
    return await market.contract.requestExpiry(id)

method getHost(
    market: OnChainMarket, requestId: RequestId, slotIndex: uint64
): Future[?Address] {.async: (raises: [CancelledError, MarketError]).} =
  convertEthersError("Failed to get slot's host"):
    let slotId = slotId(requestId, slotIndex)
    let address = await market.contract.getHost(slotId)
    if address != Address.default:
      return some address
    else:
      return none Address

method currentCollateral*(
    market: OnChainMarket, slotId: SlotId
): Future[Tokens] {.async: (raises: [MarketError, CancelledError]).} =
  convertEthersError("Failed to get slot's current collateral"):
    return await market.contract.currentCollateral(slotId)

method getActiveSlot*(market: OnChainMarket, slotId: SlotId): Future[?Slot] {.async.} =
  convertEthersError("Failed to get active slot"):
    try:
      return some await market.contract.getActiveSlot(slotId)
    except Marketplace_SlotIsFree:
      return none Slot

method fillSlot(
    market: OnChainMarket,
    requestId: RequestId,
    slotIndex: uint64,
    proof: Groth16Proof,
    collateral: Tokens,
) {.async: (raises: [CancelledError, MarketError]).} =
  convertEthersError("Failed to fill slot"):
    logScope:
      requestId
      slotIndex

    try:
      await market.approveFunds(collateral)

      # Add 10% to gas estimate to deal with different evm code flow when we
      # happen to be the last one to fill a slot in this request
      trace "estimating gas for fillSlot"
      let gas = await market.contract.estimateGas.fillSlot(requestId, slotIndex, proof)
      let overrides = TransactionOverrides(gasLimit: some (gas * 110) div 100)

      trace "calling fillSlot on contract"
      discard await market.contract
      .fillSlot(requestId, slotIndex, proof, overrides)
      .confirm(1)
      trace "fillSlot transaction completed"
    except Marketplace_SlotNotFree as parent:
      raise newException(
        SlotStateMismatchError, "Failed to fill slot because the slot is not free",
        parent,
      )

method freeSlot*(
    market: OnChainMarket, slotId: SlotId
) {.async: (raises: [CancelledError, MarketError]).} =
  convertEthersError("Failed to free slot"):
    try:
      # Add 10% to gas estimate to deal with different evm code flow when we
      # happen to be the one to make the request fail
      let gas = await market.contract.estimateGas.freeSlot(slotId)
      let overrides = TransactionOverrides(gasLimit: some (gas * 110) div 100)

      discard await market.contract.freeSlot(slotId, overrides).confirm(1)
    except Marketplace_SlotIsFree as parent:
      raise newException(
        SlotStateMismatchError, "Failed to free slot, slot is already free", parent
      )

method withdrawFunds(
    market: OnChainMarket, requestId: RequestId
) {.async: (raises: [CancelledError, MarketError]).} =
  convertEthersError("Failed to withdraw funds"):
    discard await market.contract.withdrawFunds(requestId).confirm(1)

method isProofRequired*(market: OnChainMarket, id: SlotId): Future[bool] {.async.} =
  convertEthersError("Failed to get proof requirement"):
    try:
      let overrides = CallOverrides(blockTag: some BlockTag.pending)
      return await market.contract.isProofRequired(id, overrides)
    except Marketplace_SlotIsFree:
      return false

method willProofBeRequired*(market: OnChainMarket, id: SlotId): Future[bool] {.async.} =
  convertEthersError("Failed to get future proof requirement"):
    try:
      let overrides = CallOverrides(blockTag: some BlockTag.pending)
      return await market.contract.willProofBeRequired(id, overrides)
    except Marketplace_SlotIsFree:
      return false

method getChallenge*(
    market: OnChainMarket, id: SlotId
): Future[ProofChallenge] {.async.} =
  convertEthersError("Failed to get proof challenge"):
    let overrides = CallOverrides(blockTag: some BlockTag.pending)
    return await market.contract.getChallenge(id, overrides)

method submitProof*(
    market: OnChainMarket, id: SlotId, proof: Groth16Proof
) {.async: (raises: [CancelledError, MarketError]).} =
  convertEthersError("Failed to submit proof"):
    discard await market.contract.submitProof(id, proof).confirm(1)

method markProofAsMissing*(
    market: OnChainMarket, id: SlotId, period: ProofPeriod
) {.async: (raises: [CancelledError, MarketError]).} =
  convertEthersError("Failed to mark proof as missing"):
    # Add 10% to gas estimate to deal with different evm code flow when we
    # happen to be the one to make the request fail
    let gas = await market.contract.estimateGas.markProofAsMissing(id, period)
    let overrides = TransactionOverrides(gasLimit: some (gas * 110) div 100)

    discard await market.contract.markProofAsMissing(id, period, overrides).confirm(1)

method canProofBeMarkedAsMissing*(
    market: OnChainMarket, id: SlotId, period: ProofPeriod
): Future[bool] {.async.} =
  let provider = market.contract.provider
  let contractWithoutSigner = market.contract.connect(provider)
  let overrides = CallOverrides(blockTag: some BlockTag.pending)
  try:
    discard await contractWithoutSigner.markProofAsMissing(id, period, overrides)
    return true
  except EthersError as e:
    trace "Proof cannot be marked as missing", msg = e.msg
    return false

method reserveSlot*(
    market: OnChainMarket, requestId: RequestId, slotIndex: uint64
) {.async: (raises: [CancelledError, MarketError]).} =
  convertEthersError("Failed to reserve slot"):
    try:
      # Add 10% to gas estimate to deal with different evm code flow when we
      # happen to be the last one that is allowed to reserve the slot
      let gas = await market.contract.estimateGas.reserveSlot(requestId, slotIndex)
      let overrides = TransactionOverrides(gasLimit: some (gas * 110) div 100)

      discard
        await market.contract.reserveSlot(requestId, slotIndex, overrides).confirm(1)
    except SlotReservations_ReservationNotAllowed:
      raise newException(
        SlotReservationNotAllowedError,
        "Failed to reserve slot because reservation is not allowed",
      )

method canReserveSlot*(
    market: OnChainMarket, requestId: RequestId, slotIndex: uint64
): Future[bool] {.async.} =
  convertEthersError("Unable to determine if slot can be reserved"):
    return await market.contract.canReserveSlot(requestId, slotIndex)

method subscribeRequests*(
    market: OnChainMarket, callback: OnRequest
): Future[MarketSubscription] {.async.} =
  proc onEvent(eventResult: ?!StorageRequested) {.upraises: [].} =
    without event =? eventResult, eventErr:
      error "There was an error in Request subscription", msg = eventErr.msg
      return

    callback(event.requestId, event.ask, event.expiry)

  convertEthersError("Failed to subscribe to StorageRequested events"):
    let subscription = await market.contract.subscribe(StorageRequested, onEvent)
    return OnChainMarketSubscription(eventSubscription: subscription)

method subscribeSlotFilled*(
    market: OnChainMarket, callback: OnSlotFilled
): Future[MarketSubscription] {.async.} =
  proc onEvent(eventResult: ?!SlotFilled) {.upraises: [].} =
    without event =? eventResult, eventErr:
      error "There was an error in SlotFilled subscription", msg = eventErr.msg
      return

    callback(event.requestId, event.slotIndex)

  convertEthersError("Failed to subscribe to SlotFilled events"):
    let subscription = await market.contract.subscribe(SlotFilled, onEvent)
    return OnChainMarketSubscription(eventSubscription: subscription)

method subscribeSlotFilled*(
    market: OnChainMarket,
    requestId: RequestId,
    slotIndex: uint64,
    callback: OnSlotFilled,
): Future[MarketSubscription] {.async.} =
  proc onSlotFilled(eventRequestId: RequestId, eventSlotIndex: uint64) =
    if eventRequestId == requestId and eventSlotIndex == slotIndex:
      callback(requestId, slotIndex)

  convertEthersError("Failed to subscribe to SlotFilled events"):
    return await market.subscribeSlotFilled(onSlotFilled)

method subscribeSlotFreed*(
    market: OnChainMarket, callback: OnSlotFreed
): Future[MarketSubscription] {.async.} =
  proc onEvent(eventResult: ?!SlotFreed) {.upraises: [].} =
    without event =? eventResult, eventErr:
      error "There was an error in SlotFreed subscription", msg = eventErr.msg
      return

    callback(event.requestId, event.slotIndex)

  convertEthersError("Failed to subscribe to SlotFreed events"):
    let subscription = await market.contract.subscribe(SlotFreed, onEvent)
    return OnChainMarketSubscription(eventSubscription: subscription)

method subscribeSlotReservationsFull*(
    market: OnChainMarket, callback: OnSlotReservationsFull
): Future[MarketSubscription] {.async.} =
  proc onEvent(eventResult: ?!SlotReservationsFull) {.upraises: [].} =
    without event =? eventResult, eventErr:
      error "There was an error in SlotReservationsFull subscription",
        msg = eventErr.msg
      return

    callback(event.requestId, event.slotIndex)

  convertEthersError("Failed to subscribe to SlotReservationsFull events"):
    let subscription = await market.contract.subscribe(SlotReservationsFull, onEvent)
    return OnChainMarketSubscription(eventSubscription: subscription)

method subscribeFulfillment(
    market: OnChainMarket, callback: OnFulfillment
): Future[MarketSubscription] {.async.} =
  proc onEvent(eventResult: ?!RequestFulfilled) {.upraises: [].} =
    without event =? eventResult, eventErr:
      error "There was an error in RequestFulfillment subscription", msg = eventErr.msg
      return

    callback(event.requestId)

  convertEthersError("Failed to subscribe to RequestFulfilled events"):
    let subscription = await market.contract.subscribe(RequestFulfilled, onEvent)
    return OnChainMarketSubscription(eventSubscription: subscription)

method subscribeFulfillment(
    market: OnChainMarket, requestId: RequestId, callback: OnFulfillment
): Future[MarketSubscription] {.async.} =
  proc onEvent(eventResult: ?!RequestFulfilled) {.upraises: [].} =
    without event =? eventResult, eventErr:
      error "There was an error in RequestFulfillment subscription", msg = eventErr.msg
      return

    if event.requestId == requestId:
      callback(event.requestId)

  convertEthersError("Failed to subscribe to RequestFulfilled events"):
    let subscription = await market.contract.subscribe(RequestFulfilled, onEvent)
    return OnChainMarketSubscription(eventSubscription: subscription)

method subscribeRequestFailed*(
    market: OnChainMarket, callback: OnRequestFailed
): Future[MarketSubscription] {.async.} =
  proc onEvent(eventResult: ?!RequestFailed) {.upraises: [].} =
    without event =? eventResult, eventErr:
      error "There was an error in RequestFailed subscription", msg = eventErr.msg
      return

    callback(event.requestId)

  convertEthersError("Failed to subscribe to RequestFailed events"):
    let subscription = await market.contract.subscribe(RequestFailed, onEvent)
    return OnChainMarketSubscription(eventSubscription: subscription)

method subscribeRequestFailed*(
    market: OnChainMarket, requestId: RequestId, callback: OnRequestFailed
): Future[MarketSubscription] {.async.} =
  proc onEvent(eventResult: ?!RequestFailed) {.upraises: [].} =
    without event =? eventResult, eventErr:
      error "There was an error in RequestFailed subscription", msg = eventErr.msg
      return

    if event.requestId == requestId:
      callback(event.requestId)

  convertEthersError("Failed to subscribe to RequestFailed events"):
    let subscription = await market.contract.subscribe(RequestFailed, onEvent)
    return OnChainMarketSubscription(eventSubscription: subscription)

method subscribeProofSubmission*(
    market: OnChainMarket, callback: OnProofSubmitted
): Future[MarketSubscription] {.async.} =
  proc onEvent(eventResult: ?!ProofSubmitted) {.upraises: [].} =
    without event =? eventResult, eventErr:
      error "There was an error in ProofSubmitted subscription", msg = eventErr.msg
      return

    callback(event.id)

  convertEthersError("Failed to subscribe to ProofSubmitted events"):
    let subscription = await market.contract.subscribe(ProofSubmitted, onEvent)
    return OnChainMarketSubscription(eventSubscription: subscription)

method unsubscribe*(subscription: OnChainMarketSubscription) {.async.} =
  await subscription.eventSubscription.unsubscribe()

method queryPastSlotFilledEvents*(
    market: OnChainMarket, fromBlock: BlockTag
): Future[seq[SlotFilled]] {.async.} =
  convertEthersError("Failed to get past SlotFilled events from block"):
    return await market.contract.queryFilter(SlotFilled, fromBlock, BlockTag.latest)

method queryPastSlotFilledEvents*(
    market: OnChainMarket, blocksAgo: int
): Future[seq[SlotFilled]] {.async.} =
  convertEthersError("Failed to get past SlotFilled events"):
    let fromBlock = await market.contract.provider.pastBlockTag(blocksAgo)

    return await market.queryPastSlotFilledEvents(fromBlock)

method queryPastSlotFilledEvents*(
    market: OnChainMarket, fromTime: SecondsSince1970
): Future[seq[SlotFilled]] {.async.} =
  convertEthersError("Failed to get past SlotFilled events from time"):
    let fromBlock = await market.contract.provider.blockNumberForEpoch(fromTime)
    return await market.queryPastSlotFilledEvents(BlockTag.init(fromBlock))

method queryPastStorageRequestedEvents*(
    market: OnChainMarket, fromBlock: BlockTag
): Future[seq[StorageRequested]] {.async.} =
  convertEthersError("Failed to get past StorageRequested events from block"):
    return
      await market.contract.queryFilter(StorageRequested, fromBlock, BlockTag.latest)

method queryPastStorageRequestedEvents*(
    market: OnChainMarket, blocksAgo: int
): Future[seq[StorageRequested]] {.async.} =
  convertEthersError("Failed to get past StorageRequested events"):
    let fromBlock = await market.contract.provider.pastBlockTag(blocksAgo)

    return await market.queryPastStorageRequestedEvents(fromBlock)
