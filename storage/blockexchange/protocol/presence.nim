{.push raises: [].}

import libp2p
import pkg/questionable
import ./message

import ../../blocktype

export questionable
export BlockPresenceType

type
  PresenceMessage* = message.BlockPresence
  Presence* = object
    address*: BlockAddress
    have*: bool
    presenceType*: BlockPresenceType
    ranges*: seq[tuple[start: uint64, count: uint64]]

func init*(_: type Presence, message: PresenceMessage): ?Presence =
  some Presence(
    address: message.address,
    have: message.kind in {BlockPresenceType.HaveRange, BlockPresenceType.Complete},
    presenceType: message.kind,
    ranges: message.ranges,
  )

func init*(_: type PresenceMessage, presence: Presence): PresenceMessage =
  PresenceMessage(
    address: presence.address, kind: presence.presenceType, ranges: presence.ranges
  )
