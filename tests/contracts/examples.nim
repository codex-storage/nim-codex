import pkg/ethers
import ../examples

export examples

proc example*(_: type Address): Address =
  Address(array[20, byte].example)
