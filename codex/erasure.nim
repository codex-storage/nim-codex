## Logos Storage
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import ./erasure/erasure
import ./erasure/backends/leopard

export erasure

func leoEncoderProvider*(
    size, buffers, parity: int
): EncoderBackend {.raises: [Defect].} =
  ## create new Leo Encoder
  LeoEncoderBackend.new(size, buffers, parity)

func leoDecoderProvider*(
    size, buffers, parity: int
): DecoderBackend {.raises: [Defect].} =
  ## create new Leo Decoder
  LeoDecoderBackend.new(size, buffers, parity)
