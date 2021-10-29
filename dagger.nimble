version = "0.1.0"
author = "Dagger Team"
description = "p2p data durability engine"
license = "MIT"

requires "libp2p#unstable",
         "nimcrypto >= 0.4.1",
         "bearssl >= 0.1.4",
         "chronicles >= 0.7.2",
         "chronos >= 2.5.2",
         "metrics",
         "secp256k1",
         "stew#head",
         "protobufserialization >= 0.2.0 & < 0.3.0",
         "https://github.com/status-im/nim-nitro >= 0.4.0 & < 0.5.0",
         "questionable >= 0.9.1 & < 0.10.0",
         "upraises >= 0.1.0 & < 0.2.0",
         "asynctest >= 0.3.0 & < 0.4.0"
