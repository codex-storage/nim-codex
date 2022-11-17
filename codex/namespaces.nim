## Nim-Codex
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/os

const
  # Namespaces
  CodexMetaNamespace* = "meta"                                # meta info stored here
  CodexRepoNamespace* =  "repo"                               # repository namespace, blocks and manifests are subkeys
  CodexBlocksNamespace* = CodexRepoNamespace / "blocks"       # blocks namespace
  CodexManifestNamespace* = CodexRepoNamespace / "manifests"  # manifest namespace
  CodexBlocksPersistNamespace* =                              # Cid's of persisted blocks goes here
    CodexMetaNamespace / "blocks" / "persist"
  CodexBlocksTtlNamespace* =                                  # Cid TTL
    CodexMetaNamespace / "blocks" / "ttl"
  CodexDhtNamespace* = "dht"                                  # Dht namespace
  CodexDhtProvidersNamespace* =                               # Dht providers namespace
    CodexDhtNamespace / "providers"
