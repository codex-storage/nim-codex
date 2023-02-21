Codex Contracts in Nim
=======================

Nim API for the [Codex smart contracts][1].

Usage
-----

For a global overview of the steps involved in starting and fulfilling a
storage contract, see [Codex Contracts][1].

Smart contract
--------------

Connecting to the smart contract on an Ethereum node:

```nim
import codex/contracts
import ethers

let address = # fill in address where the contract was deployed
let provider = JsonRpcProvider.new("ws://localhost:8545")
let marketplace = Marketplace.new(address, provider)
```

Setup client and host so that they can sign transactions; here we use the first
two accounts on the Ethereum node:

```nim
let accounts = await provider.listAccounts()
let client = provider.getSigner(accounts[0])
let host = provider.getSigner(accounts[1])
```

Collateral
----------

Hosts need to put up collateral before participating in storage contracts.

A host can learn about the amount of collateral that is required:
```nim
let config = await marketplace.config()
let collateral = config.collateral.initialAmount
```

The host then needs to prepare a payment to the smart contract by calling the
`approve` method on the [ERC20 token][2]. Note that interaction with ERC20
contracts is not part of this library.

After preparing the payment, the host can deposit collateral:
```nim
await storage
  .connect(host)
  .deposit(collateral)
```

When a host is not participating in storage offers or contracts, it can withdraw
its collateral:

```
await storage
  .connect(host)
  .withdraw()
```

Storage requests
----------------

Creating a request for storage:

```nim
let request : StorageRequest = (
  client:           # address of the client requesting storage
  duration:         # duration of the contract in seconds
  size:             # size in bytes
  contentHash:      # SHA256 hash of the content that's going to be stored
  proofProbability: # require a storage proof roughly once every N periods
  maxPrice:         # maximum price the client is willing to pay
  expiry:           # expiration time of the request (in unix time)
  nonce:            # random nonce to differentiate between similar requests
)
```

When a client wants to submit this request to the network, it needs to pay the
maximum price to the smart contract in advance. The difference between the
maximum price and the offered price will be reimbursed later. To prepare, the
client needs to call the `approve` method on the [ERC20 token][2]. Note that
interaction with ERC20 contracts is not part of this library.

Once the payment has been prepared, the client can submit the request to the
network:

```nim
await storage
  .connect(client)
  .requestStorage(request)
```

Storage offers
--------------

Creating a storage offer:

```nim
let offer: StorageOffer = (
  host:       # address of the host that is offering storage
  requestId:  request.id,
  price:      # offered price (in number of tokens)
  expiry:     # expiration time of the offer (in unix time)
)
```

Hosts submits an offer:

```nim
await storage
  .connect(host)
  .offerStorage(offer)
```

Client selects an offer:

```nim
await storage
  .connect(client)
  .selectOffer(offer.id)
```

Starting and finishing a storage contract
-----------------------------------------

The host whose offer got selected can start the storage contract once it
received the data that needs to be stored:

```nim
await storage
  .connect(host)
  .startContract(offer.id)
```

Once the storage contract is finished, the host can release payment:

```nim
await storage
  .connect(host)
  .finishContract(id)
```

Storage proofs
--------------

Time is divided into periods, and each period a storage proof may be required
from the host. The odds of requiring a storage proof are negotiated through the
storage request. For more details about the timing of storage proofs, please
refer to the [design document][3].

At the start of each period of time, the host can check whether a storage proof
is required:

```nim
let isProofRequired = await storage.isProofRequired(offer.id)
```

If a proof is required, the host can submit it before the end of the period:

```nim
await storage
  .connect(host)
  .submitProof(id, proof)
```

If a proof is not submitted, then a validator can mark a proof as missing:

```nim
await storage
  .connect(validator)
  .markProofAsMissing(id, period)
```

[1]: https://github.com/status-im/codex-contracts-eth/
[2]: https://ethereum.org/en/developers/docs/standards/tokens/erc-20/
[3]: https://github.com/status-im/codex-research/blob/main/design/storage-proof-timing.md
