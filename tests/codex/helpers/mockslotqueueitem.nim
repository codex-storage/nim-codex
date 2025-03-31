import pkg/codex/contracts/requests
import pkg/codex/sales/slotqueue

type MockSlotQueueItem* = object
  requestId*: RequestId
  slotIndex*: uint16
  slotSize*: uint64
  duration*: StorageDuration
  pricePerBytePerSecond*: TokensPerSecond
  collateral*: Tokens
  expiry*: StorageTimestamp
  seen*: bool

proc toSlotQueueItem*(item: MockSlotQueueItem): SlotQueueItem =
  SlotQueueItem.init(
    requestId = item.requestId,
    slotIndex = item.slotIndex,
    ask = StorageAsk(
      slotSize: item.slotSize,
      duration: item.duration,
      pricePerBytePerSecond: item.pricePerBytePerSecond,
    ),
    expiry = item.expiry,
    seen = item.seen,
    collateral = item.collateral,
  )
