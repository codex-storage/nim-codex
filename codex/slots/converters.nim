import pkg/libp2p
import pkg/questionable/results
import pkg/stew/arrayops
import pkg/poseidon2
import pkg/poseidon2/io

import ../merkletree
import ../codextypes
import ../errors

func toCid(hash: Poseidon2Hash, mcodec: MultiCodec, cidCodec: MultiCodec): ?!Cid =
  let
    mhash = ? MultiHash.init(mcodec, hash.toBytes).mapFailure
    treeCid = ? Cid.init(CIDv1, cidCodec, mhash).mapFailure
  success treeCid

proc toPoseidon2Hash*(cid: Cid, mcodec: MultiCodec, cidCodec: MultiCodec): ?!Poseidon2Hash =
  if cid.cidver != CIDv1:
    return failure("Unexpected CID version")

  if cid.mcodec != cidCodec:
    return failure("Cid is not of expected codec. Was: " & $cid.mcodec & " but expected: " & $cidCodec)

  let
    bytes: array[32, byte] = array[32, byte].initCopyFrom(cid.data.buffer)
    hash = Poseidon2Hash.fromBytes(bytes)
  if not hash.isSome():
    return failure("Unable to convert Cid to Poseidon2Hash")
  return success(hash.get())

func toCellCid*(hash: Poseidon2Hash): ?!Cid =
  toCid(hash, Pos2Bn128MrklCodec, CodexSlotCell)

func fromCellCid*(cid: Cid): ?!Poseidon2Hash =
  toPoseidon2Hash(cid, Pos2Bn128MrklCodec, CodexSlotCell)

func toSlotCid*(hash: Poseidon2Hash): ?!Cid =
  toCid(hash, multiCodec("identity"), SlotRootCodec)

func fromSlotCid*(cid: Cid): ?!Poseidon2Hash =
  toPoseidon2Hash(cid, multiCodec("identity"), SlotRootCodec)

func toProvingCid*(hash: Poseidon2Hash): ?!Cid =
  toCid(hash, multiCodec("identity"), SlotProvingRootCodec)

func fromProvingCid*(cid: Cid): ?!Poseidon2Hash =
  toPoseidon2Hash(cid, multiCodec("identity"), SlotProvingRootCodec)
