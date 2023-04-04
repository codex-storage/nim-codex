import pkg/ethers/erc20
import codex/contracts
import ../contracts/token

proc mint*(signer: Signer, amount = 1_000_000.u256) {.async.} =
  ## Mints a considerable amount of tokens and approves them for transfer to
  ## the Marketplace contract.
  let deployment = Deployment.init()
  let token = TestToken.new(!deployment.address(TestToken), signer)
  let marketplace = Marketplace.new(!deployment.address(Marketplace), signer)
  await token.mint(await signer.getAddress(), amount)

proc deposit*(signer: Signer) {.async.} =
  ## Deposits sufficient collateral into the Marketplace contract.
  let deployment = Deployment.init()
  let marketplace = Marketplace.new(!deployment.address(Marketplace), signer)
  let config = await marketplace.config()
  let tokenAddress = await marketplace.token()
  let token = Erc20Token.new(tokenAddress, signer)

  await token.approve(marketplace.address, config.collateral.initialAmount)
  await marketplace.deposit(config.collateral.initialAmount)
