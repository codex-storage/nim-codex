## Nim-Codex
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import pkg/libp2p/cid
import pkg/libp2p/protobuf/minprotobuf

import ./directorymanifest

proc write(pb: var ProtoBuffer, field: int, value: Cid) =
  var ipb = initProtoBuffer()
  ipb.write(1, value.data.buffer)
  ipb.finish()
  pb.write(field, ipb)

proc encode*(manifest: DirectoryManifest): seq[byte] =
  # ```protobuf
  #   Message DirectoryManifest {
  #     Message Cid {
  #       bytes data = 1;
  #     }
  #
  #     string name = 1;
  #     repeated Cid cids = 2;
  # ```

  var ipb = initProtoBuffer()
  ipb.write(1, manifest.name)
  for cid in manifest.cids:
    ipb.write(2, cid)
  ipb.finish()
  ipb.buffer
