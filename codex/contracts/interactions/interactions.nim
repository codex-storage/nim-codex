import pkg/ethers
import pkg/chronicles
import pkg/questionable
import pkg/questionable/results
import ../../errors
import ../deployment
import ../clock

type
  ContractInteractions* = ref object of RootObj
    clock: OnChainClock
  ContractInteractionsError* = object of CodexError
  ReadDeploymentFileFailureError* = object of ContractInteractionsError

method new*[T: ContractInteractions](_: type T, clock: OnChainClock): T {.base.} =
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

method start*(interactions: ContractInteractions) {.async, base.} =
  await interactions.clock.start()

method stop*(interactions: ContractInteractions) {.async, base.} =
  await interactions.clock.stop()
