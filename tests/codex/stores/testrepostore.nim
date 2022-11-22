import std/os
import std/options

import pkg/questionable
import pkg/questionable/results

import pkg/chronos
import pkg/asynctest
import pkg/libp2p
import pkg/stew/byteutils
import pkg/datastore

import pkg/codex/stores/cachestore
import pkg/codex/chunker
import pkg/codex/stores
import pkg/codex/blocktype as bt

import ../helpers
import ./commonstoretests

# TODO: Test with fs backend
commonBlockStoreTests(
  "RepoStore", proc: BlockStore =
    BlockStore(
      RepoStore.new(
        SQLiteDatastore.new(Memory).tryGet(),
        SQLiteDatastore.new(Memory).tryGet())))
