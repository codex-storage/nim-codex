## Logos Storage
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [], gcsafe.}

import pkg/questionable/results
import pkg/libp2p/crypto/crypto

import ./fileutils
import ../errors
import ../logutils
import ../rng

export crypto

type
  StorageKeyError = object of StorageError
  StorageKeyUnsafeError = object of StorageKeyError

proc setupKey*(path: string): ?!PrivateKey =
  if not path.fileAccessible({AccessFlags.Find}):
    info "Creating a private key and saving it"
    let
      res = ?PrivateKey.random(Rng.instance()[]).mapFailure(StorageKeyError)
      bytes = ?res.getBytes().mapFailure(StorageKeyError)

    ?path.secureWriteFile(bytes).mapFailure(StorageKeyError)
    return PrivateKey.init(bytes).mapFailure(StorageKeyError)

  info "Found a network private key"
  if not ?checkSecureFile(path).mapFailure(StorageKeyError):
    warn "The network private key file is not safe, aborting"
    return failure newException(
      StorageKeyUnsafeError, "The network private key file is not safe"
    )

  let kb = ?path.readAllBytes().mapFailure(StorageKeyError)
  return PrivateKey.init(kb).mapFailure(StorageKeyError)
