import pkg/chronos
import pkg/asynctest
import pkg/poseidon2
import pkg/poseidon2/io
import pkg/constantine/math/io/io_fields
import pkg/questionable/results
import pkg/codex/merkletree

import pkg/codex/slots/converters

let
  hash: Poseidon2Hash = toF(12345)

suite "Converters":
  test "CellBlock cid":
    let
      cid = toCellCid(hash).tryGet()
      value = fromCellCid(cid).tryGet()

    check:
      hash.toDecimal() == value.toDecimal()

  test "Slot cid":
    let
      cid = toSlotCid(hash).tryGet()
      value = fromSlotCid(cid).tryGet()

    check:
      hash.toDecimal() == value.toDecimal()

  test "Proving cid":
    let
      cid = toProvingCid(hash).tryGet()
      value = fromProvingCid(cid).tryGet()

    check:
      hash.toDecimal() == value.toDecimal()


# func toEncodableProof*(proof: Poseidon2Proof): ?!CodexProof =
#   let
#     encodableProof = CodexProof(
#       mcodec: multiCodec("identity"), # copy bytes as is
#       index: proof.index,
#       nleaves: proof.nleaves,
#       path: proof.path.mapIt( @(it.toBytes) ))

#   success encodableProof

# func toVerifiableProof*(proof: CodexProof): ?!Poseidon2Proof =

#   let
#     verifiableProof = Poseidon2Proof(
#       index: proof.index,
#       nleaves: proof.nleaves,
#       path: proof.path.mapIt(
#         ? Poseidon2Hash.fromBytes(it.toArray32).toResult
#       ))

#   success verifiableProof
