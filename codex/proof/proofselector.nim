import std/bitops
import std/sugar

import pkg/chronicles
import pkg/chronos
import pkg/questionable
import pkg/questionable/results
import pkg/constantine/math/arithmetic
import pkg/poseidon2
import pkg/poseidon2/io
import pkg/libp2p
import pkg/stew/arrayops

import misc
import slotblocks
import types
import datasamplerstarter
import proofpadding
import proofblock
import ../contracts/requests
import ../blocktype as bt
import ../merkletree
import ../manifest
import ../stores/blockstore
import ../slots/converters
import ../utils/poseidon2digest

logScope:
  topics = "codex proof selector"

type
  ProofSelector* = ref object of RootObj
    slotRootHash: Poseidon2Hash
    numberOfCellsPerBlock: uint64
    numberOfCellsInSlot: uint64

proc new*(
    T: type ProofSelector,
    slot: Slot,
    manifest: Manifest,
    slotRootHash: Poseidon2Hash,
    cellSize: NBytes
): ProofSelector =
  let
    numberOfCellsInSlot = slot.request.ask.slotSize.truncate(uint64) div cellSize.uint64
    blockSize = manifest.blockSize.uint64
    numberOfCellsPerBlock = blockSize div cellSize.uint64

  ProofSelector(
    slotRootHash: slotRootHash,
    numberOfCellsPerBlock: numberOfCellsPerBlock,
    numberOfCellsInSlot: numberOfCellsInSlot
  )

proc numberOfCellsInSlot*(self: ProofSelector): uint64 =
  self.numberOfCellsInSlot

func extractLowBits*[n: static int](A: BigInt[n], k: int): uint64 =
  assert(k > 0 and k <= 64)
  var r: uint64 = 0
  for i in 0..<k:
    let b = bit[n](A, i)

    let y = uint64(b)
    if (y != 0):
      r = bitor(r, 1'u64 shl i)
  return r

proc convertToSlotCellIndex(self: ProofSelector, fe: Poseidon2Hash): uint64 =
  let
    n = self.numberOfCellsInSlot.int
    log2 = ceilingLog2(n)
  assert((1 shl log2) == n , "expected `numberOfCellsInSlot` to be a power of two.")

  return extractLowBits(fe.toBig(), log2)

func getSlotBlockIndexForSlotCellIndex*(self: ProofSelector, slotCellIndex: uint64): uint64 =
  return slotCellIndex div self.numberOfCellsPerBlock

func getBlockCellIndexForSlotCellIndex*(self: ProofSelector, slotCellIndex: uint64): uint64 =
  return slotCellIndex mod self.numberOfCellsPerBlock

proc findSlotCellIndex*(self: ProofSelector, challenge: Poseidon2Hash, counter: Poseidon2Hash): uint64 =
  let
    input = @[self.slotRootHash, challenge, counter]
    hash = Sponge.digest(input, rate = 2)
  return self.convertToSlotCellIndex(hash)

func findSlotCellIndices*(self: ProofSelector, challenge: Poseidon2Hash, nSamples: int): seq[uint64] =
  return collect(newSeq, (for i in 1..nSamples: self.findSlotCellIndex(challenge, toF(i))))
