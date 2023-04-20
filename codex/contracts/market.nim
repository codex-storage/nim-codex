import std/strutils
import pkg/chronicles
import pkg/ethers
import pkg/ethers/testing
import pkg/upraises
import pkg/questionable
import pkg/chronicles
import ../market
import ./marketplace

export market

logScope:
    topics = "onchain market"

type
  OnChainMarket* = ref object of Market
    contract: Marketplace
    signer: Signer
  MarketSubscription = market.Subscription
  EventSubscription = ethers.Subscription
  OnChainMarketSubscription = ref object of MarketSubscription
    eventSubscription: EventSubscription

func new*(_: type OnChainMarket, contract: Marketplace): OnChainMarket =
  without signer =? contract.signer:
    raiseAssert("Marketplace contract should have a signer")
  OnChainMarket(
    contract: contract,
    signer: signer,
  )

proc approveFunds(market: OnChainMarket, amount: UInt256) {.async.} =
  notice "approving tokens", amount
  let tokenAddress = await market.contract.token()
  let token = Erc20Token.new(tokenAddress, market.signer)

  await token.approve(market.contract.address(), amount)

method getSigner*(market: OnChainMarket): Future[Address] {.async.} =
  return await market.signer.getAddress()

method isMainnet*(market: OnChainMarket): Future[bool] {.async.} =
  return (await market.signer.provider.getChainId()) == 1.u256

method periodicity*(market: OnChainMarket): Future[Periodicity] {.async.} =
  let config = await market.contract.config()
  let period = config.proofs.period
  return Periodicity(seconds: period)

method proofTimeout*(market: OnChainMarket): Future[UInt256] {.async.} =
  let config = await market.contract.config()
  return config.proofs.timeout

method myRequests*(market: OnChainMarket): Future[seq[RequestId]] {.async.} =
  return await market.contract.myRequests

method mySlots*(market: OnChainMarket): Future[seq[SlotId]] {.async.} =
  return await market.contract.mySlots()

method requestStorage(market: OnChainMarket, request: StorageRequest){.async.} =
  await market.approveFunds(request.price())
  await market.contract.requestStorage(request)

method getRequest(market: OnChainMarket,
                  id: RequestId): Future[?StorageRequest] {.async.} =
  try:
    return some await market.contract.getRequest(id)
  except ProviderError as e:
    if e.revertReason.contains("Unknown request"):
      return none StorageRequest
    raise e

method requestState*(market: OnChainMarket,
                 requestId: RequestId): Future[?RequestState] {.async.} =
  try:
    return some await market.contract.requestState(requestId)
  except ProviderError as e:
    if e.revertReason.contains("Unknown request"):
      return none RequestState
    raise e

method slotState*(market: OnChainMarket,
                  slotId: SlotId): Future[SlotState] {.async.} =
  return await market.contract.slotState(slotId)

method getRequestEnd*(market: OnChainMarket,
                      id: RequestId): Future[SecondsSince1970] {.async.} =
  return await market.contract.requestEnd(id)

method getHost(market: OnChainMarket,
               requestId: RequestId,
               slotIndex: UInt256): Future[?Address] {.async.} =
  let slotId = slotId(requestId, slotIndex)
  let address = await market.contract.getHost(slotId)
  if address != Address.default:
    return some address
  else:
    return none Address

method getActiveSlot*(
  market: OnChainMarket,
  slotId: SlotId): Future[?Slot] {.async.} =

  try:
    return some await market.contract.getActiveSlot(slotId)
  except ProviderError as e:
    if e.revertReason.contains("Slot is free"):
      return none Slot
    raise e

method fillSlot(market: OnChainMarket,
                requestId: RequestId,
                slotIndex: UInt256,
                proof: seq[byte],
                collateral: UInt256) {.async.} =
  await market.approveFunds(collateral)
  await market.contract.fillSlot(requestId, slotIndex, proof)

method freeSlot*(market: OnChainMarket, slotId: SlotId) {.async.} =
  await market.contract.freeSlot(slotId)

method withdrawFunds(market: OnChainMarket,
                     requestId: RequestId) {.async.} =
  await market.contract.withdrawFunds(requestId)

method isProofRequired*(market: OnChainMarket,
                        id: SlotId): Future[bool] {.async.} =
  try:
    return await market.contract.isProofRequired(id)
  except ProviderError as e:
    if e.revertReason.contains("Slot is free"):
      return false
    raise e

method willProofBeRequired*(market: OnChainMarket,
                            id: SlotId): Future[bool] {.async.} =
  try:
    return await market.contract.willProofBeRequired(id)
  except ProviderError as e:
    if e.revertReason.contains("Slot is free"):
      return false
    raise e

method submitProof*(market: OnChainMarket,
                    id: SlotId,
                    proof: seq[byte]) {.async.} =
  await market.contract.submitProof(id, proof)

method markProofAsMissing*(market: OnChainMarket,
                           id: SlotId,
                           period: Period) {.async.} =
  await market.contract.markProofAsMissing(id, period)

method canProofBeMarkedAsMissing*(market: OnChainMarket,
                                  id: SlotId,
                                  period: Period): Future[bool] {.async.} =
  let provider = market.contract.provider
  let contractWithoutSigner = market.contract.connect(provider)
  let overrides = CallOverrides(blockTag: some BlockTag.pending)
  try:
    await contractWithoutSigner.markProofAsMissing(id, period, overrides)
    return true
  except EthersError as e:
    trace "Proof can not be marked as missing", msg = e.msg
    return false

method subscribeRequests(market: OnChainMarket,
                         callback: OnRequest):
                        Future[MarketSubscription] {.async.} =
  proc onEvent(event: StorageRequested) {.upraises:[].} =
    callback(event.requestId, event.ask)
  let subscription = await market.contract.subscribe(StorageRequested, onEvent)
  return OnChainMarketSubscription(eventSubscription: subscription)

method subscribeSlotFilled*(market: OnChainMarket,
                            callback: OnSlotFilled):
                           Future[MarketSubscription] {.async.} =
  proc onEvent(event: SlotFilled) {.upraises:[].} =
    callback(event.requestId, event.slotIndex)
  let subscription = await market.contract.subscribe(SlotFilled, onEvent)
  return OnChainMarketSubscription(eventSubscription: subscription)

method subscribeSlotFilled*(market: OnChainMarket,
                            requestId: RequestId,
                            slotIndex: UInt256,
                            callback: OnSlotFilled):
                           Future[MarketSubscription] {.async.} =
  proc onSlotFilled(eventRequestId: RequestId, eventSlotIndex: UInt256) =
    if eventRequestId == requestId and eventSlotIndex == slotIndex:
      callback(requestId, slotIndex)
  return await market.subscribeSlotFilled(onSlotFilled)

method subscribeSlotFreed*(market: OnChainMarket,
                           callback: OnSlotFreed):
                          Future[MarketSubscription] {.async.} =
  proc onEvent(event: SlotFreed) {.upraises:[].} =
    callback(event.slotId)
  let subscription = await market.contract.subscribe(SlotFreed, onEvent)
  return OnChainMarketSubscription(eventSubscription: subscription)

method subscribeFulfillment(market: OnChainMarket,
                            requestId: RequestId,
                            callback: OnFulfillment):
                           Future[MarketSubscription] {.async.} =
  proc onEvent(event: RequestFulfilled) {.upraises:[].} =
    if event.requestId == requestId:
      callback(event.requestId)
  let subscription = await market.contract.subscribe(RequestFulfilled, onEvent)
  return OnChainMarketSubscription(eventSubscription: subscription)

method subscribeRequestCancelled*(market: OnChainMarket,
                                  requestId: RequestId,
                                  callback: OnRequestCancelled):
                                Future[MarketSubscription] {.async.} =
  proc onEvent(event: RequestCancelled) {.upraises:[].} =
    if event.requestId == requestId:
      callback(event.requestId)
  let subscription = await market.contract.subscribe(RequestCancelled, onEvent)
  return OnChainMarketSubscription(eventSubscription: subscription)

method subscribeRequestFailed*(market: OnChainMarket,
                              requestId: RequestId,
                              callback: OnRequestFailed):
                            Future[MarketSubscription] {.async.} =
  proc onEvent(event: RequestFailed) {.upraises:[]} =
    if event.requestId == requestId:
      callback(event.requestId)
  let subscription = await market.contract.subscribe(RequestFailed, onEvent)
  return OnChainMarketSubscription(eventSubscription: subscription)

method subscribeProofSubmission*(market: OnChainMarket,
                                 callback: OnProofSubmitted):
                                Future[MarketSubscription] {.async.} =
  proc onEvent(event: ProofSubmitted) {.upraises: [].} =
    callback(event.id, event.proof)
  let subscription = await market.contract.subscribe(ProofSubmitted, onEvent)
  return OnChainMarketSubscription(eventSubscription: subscription)

method unsubscribe*(subscription: OnChainMarketSubscription) {.async.} =
  await subscription.eventSubscription.unsubscribe()
