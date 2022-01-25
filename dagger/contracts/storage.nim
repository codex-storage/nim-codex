import pkg/ethers
import pkg/json_rpc/rpcclient
import pkg/stint
import pkg/chronos
import ./marketplace

export stint
export contract

type
  Storage* = ref object of Contract
  Id = array[32, byte]

proc stakeAmount*(storage: Storage): UInt256 {.contract, view.}
proc increaseStake*(storage: Storage, amount: UInt256) {.contract.}
proc withdrawStake*(storage: Storage) {.contract.}
proc stake*(storage: Storage, account: Address): UInt256 {.contract, view.}
proc duration*(storage: Storage, id: Id): UInt256 {.contract, view.}
proc size*(storage: Storage, id: Id): UInt256 {.contract, view.}
proc contentHash*(storage: Storage, id: Id): array[32, byte] {.contract, view.}
proc proofPeriod*(storage: Storage, id: Id): UInt256 {.contract, view.}
proc proofTimeout*(storage: Storage, id: Id): UInt256 {.contract, view.}
proc price*(storage: Storage, id: Id): UInt256 {.contract, view.}
proc host*(storage: Storage, id: Id): Address {.contract, view.}
proc startContract*(storage: Storage, id: Id) {.contract.}
proc proofEnd*(storage: Storage, id: Id): UInt256 {.contract, view.}
proc isProofRequired*(storage: Storage,
                      id: Id,
                      blocknumber: UInt256): bool {.contract, view.}
proc submitProof*(storage: Storage,
                  id: Id,
                  blocknumber: UInt256,
                  proof: bool) {.contract.}
proc markProofAsMissing*(storage: Storage,
                          id: Id,
                          blocknumber: UInt256) {.contract.}
proc finishContract*(storage: Storage, id: Id) {.contract.}

proc newContract(storage: Storage,
                 duration: UInt256,
                 size: UInt256,
                 contentHash: array[32, byte],
                 proofPeriod: UInt256,
                 proofTimeout: UInt256,
                 nonce: array[32, byte],
                 price: UInt256,
                 host: Address,
                 bidExpiry: UInt256,
                 requestSignature: seq[byte],
                 bidSignature: seq[byte]) {.contract.}

proc newContract*(storage: Storage,
                  request: StorageRequest,
                  bid: StorageBid,
                  host: Address,
                  requestSignature: seq[byte],
                  bidSignature: seq[byte]) {.async.} =
  await storage.newContract(
    request.duration,
    request.size,
    request.contentHash,
    request.proofPeriod,
    request.proofTimeout,
    request.nonce,
    bid.price,
    host,
    bid.bidExpiry,
    requestSignature,
    bidSignature
  )
