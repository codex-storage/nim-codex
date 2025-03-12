import pkg/codex/contracts/requests
import pkg/codex/sales/slotqueue

type MockSlotQueueItem* = object
  requestId*: RequestId
  slotIndex*: uint16
  slotSize*: uint64
  duration*: uint64
  pricePerBytePerSecond*: UInt256
  collateral*: UInt256
  expiry*: uint64
  seen*: bool

proc toSlotQueueItem*(item: MockSlotQueueItem): SlotQueueItem =
  SlotQueueItem.init(
    requestId = item.requestId,
    slotIndex = item.slotIndex,
    ask = StorageAsk(
      slotSize: item.slotSize,
      duration: item.duration.stuint(40),
      pricePerBytePerSecond: item.pricePerBytePerSecond.stuint(96),
    ),
    expiry = item.expiry,
    seen = item.seen,
    collateral = item.collateral,
  )
