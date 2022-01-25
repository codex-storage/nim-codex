import pkg/chronos
import pkg/stint
import pkg/ethers

type
  TestToken* = ref object of Contract

proc mint*(token: TestToken, holder: Address, amount: UInt256) {.contract.}
proc approve*(token: TestToken, spender: Address, amount: UInt256) {.contract.}
proc balanceOf*(token: TestToken, account: Address): UInt256 {.contract, view.}
