import codex/contracts
import codex/contracts/testtoken

proc mint*(signer: Signer, amount = 1_000_000.u256) {.async.} =
  ## Mints a considerable amount of tokens and approves them for transfer to
  ## the Marketplace contract.
  let deployment = Deployment.init()
  let token = TestToken.new(!deployment.address(TestToken), signer)
  let marketplace = Marketplace.new(!deployment.address(Marketplace), signer)
  await token.mint(await signer.getAddress(), amount)
  await token.approve(marketplace.address, amount)

proc deposit*(signer: Signer) {.async.} =
  ## Deposits sufficient collateral into the Marketplace contract.
  let deployment = Deployment.init()
  let marketplace = Marketplace.new(!deployment.address(Marketplace), signer)
  let config = await marketplace.config()
  await marketplace.deposit(config.collateral.initialAmount)
