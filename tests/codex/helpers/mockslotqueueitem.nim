import pkg/codex/contracts/requests
import pkg/codex/sales/slotqueue

type MockSlotQueueItem* = object
  requestId*: RequestId
  slotIndex*: uint16
  slotSize*: UInt256
  duration*: UInt256
  reward*: UInt256
  collateral*: UInt256
  expiry*: UInt256
  seen*: bool

proc toSlotQueueItem*(item: MockSlotQueueItem): SlotQueueItem =
  var qitem = SlotQueueItem.init(
    requestId = item.requestId,
    slotIndex = item.slotIndex,
    ask = StorageAsk(
            slotSize: item.slotSize,
            duration: item.duration,
            reward: item.reward,
            collateral: item.collateral
          ),
    expiry = item.expiry
  )
  qitem.seen = item.seen
  return qitem

# proc requestId*(item: MockSlotQueueItem): RequestId = item.requestId
# proc `requestId=`*(item: var MockSlotQueueItem, requestId: RequestId) =
#   item.requestId = requestId

# proc slotIndex*(item: MockSlotQueueItem): uint16 = item.slotIndex
# proc `slotIndex=`*(item: var MockSlotQueueItem, slotIndex: uint16) =
#   item.slotIndex = slotIndex

# proc slotSize*(item: MockSlotQueueItem): UInt256 = item.slotSize
# proc `slotSize=`*(item: MockSlotQueueItem, slotSize: UInt256) =
#   item.slotSize = slotSize

# proc duration*(item: MockSlotQueueItem): UInt256 = item.duration
# proc `duration=`*(item: MockSlotQueueItem, duration: UInt256) =
#   item.duration = duration

# proc reward*(item: MockSlotQueueItem): UInt256 = item.reward
# proc `reward=`*(item: MockSlotQueueItem, reward: UInt256) =
#   item.reward = reward

# proc collateral*(item: MockSlotQueueItem): UInt256 = item.collateral
# proc `collateral=`*(item: MockSlotQueueItem, collateral: UInt256) =
#   item.collateral = collateral

# proc expiry*(item: MockSlotQueueItem): UInt256 = item.expiry
# proc `expiry=`*(item: MockSlotQueueItem, expiry: UInt256) =
#   item.collateral = expiry