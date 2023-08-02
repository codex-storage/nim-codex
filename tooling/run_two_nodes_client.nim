import std/os
import std/macros
import std/json
import std/httpclient
import ./codexclient

import unittest

import pretty

let
  client1 = CodexClient.new("http://localhost:8080/api/codex/v1")
  client2 = CodexClient.new("http://localhost:8081/api/codex/v1")

print client1.info()
check client1.info() != client2.info()

let cid1 = client1.upload("some file contents")
print cid1
# let cid2 = client1.upload("some other contents")

# print cid2
# check cid1 != cid2

client1.close()
client2.close()


