# Download Flow
Sequence of interactions that result in dat blocks being transferred across the network.

## Local Store
When data is available in the local blockstore,

```mermaid
sequenceDiagram
actor Alice
participant API
Alice->>API: Download(CID)
API->>+Node/StoreStream: Retrieve(CID)
loop Get manifest block, then data blocks
    Node/StoreStream->>NetworkStore: GetBlock(CID)
    NetworkStore->>LocalStore: GetBlock(CID)
    LocalStore->>NetworkStore: Block
    NetworkStore->>Node/StoreStream: Block
end
Node/StoreStream->>Node/StoreStream: Handle erasure coding
Node/StoreStream->>-API: Data stream
API->>Alice: Stream download of block
```

## Network Store
When data is not found ih the local blockstore, the block-exchange engine is used to discover the location of the block within the network. Connection will be established to the node(s) that have the block, and exchange can take place.

```mermaid
sequenceDiagram
box
actor Alice
participant API
participant Node/StoreStream
participant NetworkStore
participant Discovery
participant Engine
end
box
participant OtherNode
end
Alice->>API: Download(CID)
API->>+Node/StoreStream: Retrieve(CID)
Node/StoreStream->>-API: Data stream
API->>Alice: Download stream begins
loop Get manifest block, then data blocks
    Node/StoreStream->>NetworkStore: GetBlock(CID)
    NetworkStore->>Engine: RequestBlock(CID)
    opt CID not known
    Engine->>Discovery: Discovery Block
    Discovery->>Discovery: Locates peers who provide block
    Discovery->>Engine: Peers
    Engine->>Engine: Update peers admin
    end
    Engine->>Engine: Select optimal peer
    Engine->>OtherNode: Send WantHave list
    OtherNode->>Engine: Send BlockPresence
    Engine->>Engine: Update peers admin
    Engine->>Engine: Decide to buy block
    Engine->>OtherNode: Send WantBlock list
    OtherNode->>Engine: Send Block
    Engine->>NetworkStore: Block
    NetworkStore->>NetworkStore: Add to Local store
    NetworkStore->>Node/StoreStream: Resolve Block
    Node/StoreStream->>Node/StoreStream: Handle erasure coding
    Node/StoreStream->>API: Push data to stream
end
API->>Alice: Download stream finishes
```

