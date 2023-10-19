## Nim-Codex
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import ./erasure/erasure
import ./erasure/backends/leopard
import ./erasure/backends/leopard2d

export erasure

func leoEncoderProvider*(size, buffers, parity: int): EncoderBackend {.raises: [Defect].} =
  ## size: blockSize in bytes
  ## buffers: RS K
  ## parity: RS M=N-K
  LeoEncoderBackend.new(size, buffers, parity)

func leoDecoderProvider*(size, buffers, parity: int): DecoderBackend {.raises: [Defect].} =
    LeoDecoderBackend.new(size, buffers, parity)

func leoEncoderProvider2D*(blocksize, buffers, parity : int): EncoderBackend {.raises: [Defect].} =
  LeoEncoderBackend2D.new(blocksize, buffers, parity)

func leoEncoderProvider2D*(blocksize, k1, m1, k2, m2 : int): EncoderBackend {.raises: [Defect].} =
  LeoEncoderBackend2D.new(blocksize, k1, m1, k2, m2)

func leoDecoderProvider2D*(blocksize, buffers, parity : int): DecoderBackend {.raises: [Defect].} =
  LeoDecoderBackend2D.new(blocksize, buffers, parity)

func leoDecoderProvider2D*(blocksize, k1, m1, k2, m2 : int): DecoderBackend {.raises: [Defect].} =
    LeoDecoderBackend2D.new(blocksize, k1, m1, k2, m2)
