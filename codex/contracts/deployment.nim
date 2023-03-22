import std/json
import std/os
import pkg/ethers
import pkg/questionable

type Deployment* = object
  json: JsonNode

const defaultFile = "vendor" / "codex-contracts-eth" / "deployment-localhost.json"

## Reads deployment information from a json file. It expects a file that has
## been exported with Hardhat deploy.
## See also:
## https://github.com/wighawag/hardhat-deploy/tree/master#6-hardhat-export
proc deployment*(file = defaultFile): Deployment =
  Deployment(json: parseFile(file))

proc address*(deployment: Deployment, Contract: typedesc): ?Address =
  if deployment.json == nil:
    return none Address

  try:
    let address = deployment.json["contracts"][$Contract]["address"].getStr()
    Address.init(address)
  except KeyError:
    none Address
