# Nim-RocksDB

[![Build Status (Travis)](https://img.shields.io/travis/status-im/nim-rocksdb/master.svg?label=Linux%20/%20macOS "Linux/macOS build status (Travis)")](https://travis-ci.org/status-im/nim-rocksdb)
[![Windows build status (Appveyor)](https://img.shields.io/appveyor/ci/nimbus/nim-rocksdb/master.svg?label=Windows "Windows build status (Appveyor)")](https://ci.appveyor.com/project/nimbus/nim-rocksdb)
[![License: Apache](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
![Stability: experimental](https://img.shields.io/badge/stability-experimental-orange.svg)

A Nim wrapper for [Facebook's RocksDB](https://github.com/facebook/rocksdb), a persistent key-value store for Flash and RAM Storage.

## Current status

Nim-RocksDB provides a wrapper for the low-level functions in the librocksdb c library.

## Requirements

A RocksDB installation that provides `librocksdb.so`. This means that on Debian, and possibly on other Linux distros, you need "librocksdb-dev", not just a versioned "librocksdbX.Y" package that only provides `librocksdb.so.X.Y.Z`.

## Usage

See [simple_example](examples/simple_example.nim)

### Static linking

To statically link librocksdb, you would do something like:

```nim
nim c -d:rocksdb_static_linking --threads:on your_program.nim
```

See the config.nims file which contains the static linking configuration which is switched on with the `rocksdb_static_linking` flag. Note that static linking is currently not supported on windows.

### Contribution

Any contribution intentionally submitted for inclusion in the work by you shall be dual licensed as above, without any
additional terms or conditions.

## License

### Wrapper License

This repository is licensed and distributed under either of

* MIT license: [LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT

or

* Apache License, Version 2.0, ([LICENSE-APACHEv2](LICENSE-APACHEv2) or http://www.apache.org/licenses/LICENSE-2.0)

at your option. This file may not be copied, modified, or distributed except according to those terms.

### Dependency License

RocksDB is developed and maintained by Facebook Database Engineering Team.
It is built on earlier work on LevelDB by Sanjay Ghemawat (sanjay@google.com)
and Jeff Dean (jeff@google.com)

RocksDB is dual-licensed under both the [GPLv2](https://github.com/facebook/rocksdb/blob/master/COPYING) and Apache License, Version 2.0, ([LICENSE-APACHEv2](LICENSE-APACHEv2) or http://www.apache.org/licenses/LICENSE-2.0).  You may select, at your option, one of the above-listed licenses.
