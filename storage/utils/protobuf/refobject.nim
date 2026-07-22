## Logos Storage
## Copyright (c) 2026 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import pkg/protobuf_serialization

proc readValue*[T: ref object](
    reader: ProtobufReader, value: var T
) {.raises: [SerializationError, IOError].} =
  if value.isNil:
    new(value)
  readValue(reader, value[])

proc writeValue*[T: ref object](
    writer: ProtobufWriter, value: T
) {.raises: [IOError].} =
  if not value.isNil:
    writeValue(writer, value[])
