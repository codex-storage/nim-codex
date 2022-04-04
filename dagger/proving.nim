import std/sets

export sets

type
  Proving* = ref object
    contracts*: HashSet[ContractId]
  ContractId* = array[32, byte]

func new*(_: type Proving): Proving =
  Proving()

func add*(proving: Proving, id: ContractId) =
  proving.contracts.incl(id)
