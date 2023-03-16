import pkg/ethers
import ../../errors
import ../deployment
import ../clock

type
  ContractInteractions* = ref object of RootObj
    clock: OnChainClock
  ContractInteractionsError* = object of CodexError
  ReadDeploymentFileFailureError* = object of ContractInteractionsError

proc new*(T: type ContractInteractions,
          clock: OnChainClock): T =
  T(clock: clock)

proc prepare*(
  providerUrl: string = "ws://localhost:8545",
  account: Address,
  deploymentFile: string = string.default):
  ?!tuple[signer: JsonRpcSigner, deploy: Deployment] =

  let provider = JsonRpcProvider.new(providerUrl)
  let signer = provider.getSigner(account)

  var deploy: Deployment
  try:
    if deploymentFile == string.default:
      deploy = deployment()
    else:
      deploy = deployment(deploymentFile)
  except IOError as e:
    let err = newException(ReadDeploymentFileFailureError,
      "Unable to read deployment json")
    err.parent = e
    return failure(err)

  return success((signer, deploy))

method start*(self: ContractInteractions) {.async, base.} =
  await self.clock.start()

method stop*(self: ContractInteractions) {.async, base.} =
  await self.clock.stop()
