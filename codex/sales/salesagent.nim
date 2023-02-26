import pkg/chronos
import pkg/stint
import ./statemachine
import ./states/[cancelled, downloading, errored, failed, finished, filled,
                 filling, proving, unknown]
import ./subscriptions
import ../contracts/requests

type SaleState* {.pure.} = enum
  SaleUnknown,
  SaleDownloading,
  SaleProving,
  SaleFilling,
  SaleFilled,
  SaleCancelled,
  SaleFailed,
  SaleErrored

proc newSalesAgent*(sales: Sales,
                    slotIndex: UInt256,
                    availability: ?Availability,
                    requestId: RequestId,
                    request: ?StorageRequest,
                    requestState: RequestState,
                    slotState: SlotState,
                    restoredFromChain: bool = false): SalesAgent =

  let saleUnknown = SaleUnknown.new()
  let saleDownloading = SaleDownloading.new()
  let saleProving = SaleProving.new()
  let saleFilling = SaleFilling.new()
  let saleFilled = SaleFilled.new()
  let saleCancelled = SaleCancelled.new()
  let saleFailed = SaleFailed.new()
  let saleErrored = SaleErrored.new()

  let agent = SalesAgent.new(@[
    Transition.new(
      AnyState.new(),
      saleErrored,
      proc(m: Machine, s: State): bool =
        SalesAgent(m).errored.value
    ),
    Transition.new(
      saleUnknown,
      saleDownloading,
      proc(m: Machine, s: State): bool =
        let agent = SalesAgent(m)
        not agent.restoredFromChain and
        agent.requestState.value == RequestState.New and
        agent.slotState.value == SlotState.Free
    ),
    Transition.new(
      @[
        saleUnknown,
        saleDownloading,
        saleProving,
        saleFilling,
        saleFilled
      ],
      saleCancelled,
      proc(m: Machine, s: State): bool =
        SalesAgent(m).requestState.value == RequestState.Cancelled
    ),
    Transition.new(
      @[
        saleUnknown,
        saleDownloading,
        saleProving,
        saleFilling,
        saleFilled
      ],
      saleFailed,
      proc(m: Machine, s: State): bool =
        let agent = SalesAgent(m)
        agent.requestState.value == RequestState.Failed or
        agent.slotState.value == SlotState.Failed
    ),
    Transition.new(
      @[
        saleUnknown,
        saleDownloading,
        saleFilling,
        saleProving
      ],
      saleFilled,
      proc(m: Machine, s: State): bool =
        SalesAgent(m).slotState.value == SlotState.Filled
    ),
    Transition.new(
      @[
        saleUnknown,
        saleDownloading,
        saleFilling,
        saleFilled,
        saleProving
      ],
      SaleFinished.new(),
      proc(m: Machine, s: State): bool =
        let agent = SalesAgent(m)
        agent.slotState.value in @[SlotState.Finished, SlotState.Paid] or
        agent.requestState.value == RequestState.Finished
    ),

    Transition.new(
      saleDownloading,
      saleProving,
      proc(m: Machine, s: State): bool =
        SalesAgent(m).downloaded.value
    ),
    Transition.new(
      saleProving,
      saleFilling,
      proc(m: Machine, s: State): bool =
        SalesAgent(m).proof.value.len > 0 # TODO: proof validity check?
    ),
    Transition.new(
      saleFilled,
      SaleFinished.new(),
      proc(m: Machine, s: State): bool =
        SalesAgent(m).slotHostIsMe.value
    ),
  ])
  agent.addState (SaleState.SaleUnknown.int, saleUnknown),
                 (SaleState.SaleDownloading.int, saleDownloading),
                 (SaleState.SaleProving.int, saleProving),
                 (SaleState.SaleFilling.int, saleFilling),
                 (SaleState.SaleFilled.int, saleFilled),
                 (SaleState.SaleCancelled.int, saleCancelled),
                 (SaleState.SaleFailed.int, saleFailed),
                 (SaleState.SaleErrored.int, saleErrored)
  agent.slotState = agent.newTransitionProperty(slotState)
  agent.requestState = agent.newTransitionProperty(requestState)
  agent.proof = agent.newTransitionProperty(newSeq[byte]())
  agent.slotHostIsMe = agent.newTransitionProperty(false)
  agent.downloaded = agent.newTransitionProperty(false)
  agent.sales = sales
  agent.availability = availability
  agent.slotIndex = slotIndex
  agent.requestId = requestId
  agent.request = request
  agent.restoredFromChain = restoredFromChain
  return agent

proc start*(agent: SalesAgent,
            initialState: State = agent.getState(SaleState.SaleUnknown)) {.async.} =
  await agent.subscribe()
  procCall Machine(agent).start(initialState)

proc stop*(agent: SalesAgent) {.async.} =
  await agent.unsubscribe()
