import dagger/contracts
import dagger/contracts/testtoken

proc mint*(signer: Signer, amount = 1_000_000.u256) {.async.} =
  ## Mints a considerable amount of tokens and approves them for transfer to
  ## the Storage contract.
  let token = TestToken.new(!deployment().address(TestToken), signer)
  let storage = Storage.new(!deployment().address(Storage), signer)
  await token.mint(await signer.getAddress(), amount)
  await token.approve(storage.address, amount)

proc deposit*(signer: Signer) {.async.} =
  ## Deposits sufficient collateral into the Storage contract.
  let storage = Storage.new(!deployment().address(Storage), signer)
  await storage.deposit(await storage.collateralAmount())
