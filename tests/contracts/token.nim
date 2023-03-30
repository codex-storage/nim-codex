import pkg/chronos
import pkg/stint
import pkg/ethers
import pkg/ethers/erc20

type
  TestToken* = ref object of Erc20Token

proc mint*(token: TestToken, holder: Address, amount: UInt256) {.contract.}
