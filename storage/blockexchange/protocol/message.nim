# Protocol of data exchange between Logos Storage nodes
# and Protobuf encoder/decoder for these messages.

{.push raises: [].}

import pkg/faststreams
import pkg/protobuf_serialization
import pkg/protobuf_serialization/codec
import pkg/protobuf_serialization/std/enums
import pkg/protobuf_serialization/pkg/results

import ../../merkletree
import ../../blocktype
import ../../utils/protobuf/cid
import ../../utils/protobuf/serializer
import ./constants

type
  WantType* {.pure.} = enum
    WantHave = 0 # Presence query - the only type used with batch transfer protocol

  WantListEntry* {.proto2.} = object
    address* {.fieldNumber: 1, required.}: BlockAddress
    priority* {.fieldNumber: 2, required, pint.}: int32
      # The priority (normalized). default to 1
    cancel* {.fieldNumber: 3, required.}: bool # Whether this revokes an entry
    wantType* {.fieldNumber: 4, required, ext.}: WantType
      # Defaults to WantHave (only type supported)
    sendDontHave* {.fieldNumber: 5, required.}: bool # Note: defaults to false
    rangeCount* {.fieldNumber: 6, required, pint.}: uint64
      # For range queries: number of sequential blocks starting from address.index (0 = single block)
    downloadId* {.fieldNumber: 7, required, pint.}: uint64
      # Unique download ID for request/response correlation

  WantList* {.proto2.} = object
    entries* {.fieldNumber: 1.}: seq[WantListEntry] # A list of wantList entries
    full* {.fieldNumber: 2, required.}: bool
      # Whether this is the full wantList. default to false

  BlockDelivery* = object
    blk*: Block
    address*: BlockAddress
    proof*: ?StorageMerkleProof

  BlockPresenceType* {.pure.} = enum
    DontHave = 0
    HaveRange = 1
    Complete = 2

  IndexRange* {.proto2.} = object
    start* {.fieldNumber: 1, required, pint.}: uint64
    count* {.fieldNumber: 2, required, pint.}: uint64

  BlockPresence* {.proto2.} = object
    address* {.fieldNumber: 1, required.}: BlockAddress
    kind* {.fieldNumber: 2, required, ext.}: BlockPresenceType
    ranges* {.fieldNumber: 3.}: seq[IndexRange]
    downloadId* {.fieldNumber: 4, required, pint.}: uint64
      # echoed for request/response correlation

  Message* {.proto2.} = object
    wantList* {.fieldNumber: 1, required.}: WantList
    blockPresences* {.fieldNumber: 4.}: seq[BlockPresence]

proc readFieldInto*(
    stream: InputStream,
    value: var seq[WantListEntry],
    header: FieldHeader,
    ProtoType: type SomeProto,
): bool {.raises: [SerializationError, IOError].} =
  if value.len >= MaxWantListEntries:
    raise newException(
      SerializationError, "WantList exceeds " & $MaxWantListEntries & " entries"
    )
  var val = default(WantListEntry)
  if stream.readFieldInto(val, header, ProtoType):
    value.add move(val)
    true
  else:
    false

proc readFieldInto*(
    stream: InputStream,
    value: var seq[BlockPresence],
    header: FieldHeader,
    ProtoType: type SomeProto,
): bool {.raises: [SerializationError, IOError].} =
  if value.len >= MaxBlockPresenceEntries:
    raise newException(
      SerializationError,
      "blockPresences exceeds " & $MaxBlockPresenceEntries & " entries",
    )
  var val = default(BlockPresence)
  if stream.readFieldInto(val, header, ProtoType):
    value.add move(val)
    true
  else:
    false

Protobuf.serializerForResult([Message])
