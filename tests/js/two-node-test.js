/**
 * two-node-test.js — Layer 1.5: full pipeline two-node upload/download test
 *
 * Spins up two in-process libstorage nodes, connects them via bootstrap SPR,
 * uploads content on node A, and verifies it can be downloaded from node B
 * over the p2p network.
 *
 * This is the test that fills the TODO in tests/cbindings/storage.c:
 *   "// TODO: implement check_fetch — requires two nodes connected together"
 *
 * Usage:
 *   cd tests/js && npm install && npm test
 *
 * Environment:
 *   PORT_BASE  Base port for node listen/disc ports (default: 8792).
 *              Set explicitly when running in containers so ports are
 *              predictable and can be pre-declared in port mappings.
 */

import { describe, it, before, after, beforeEach, afterEach } from 'mocha';
import assert from 'node:assert/strict';
import net from 'node:net';
import dgram from 'node:dgram';
import { rmSync, mkdirSync } from 'fs';
import { tmpdir } from 'os';
import path from 'path';
import { StorageNode, DEBUG_ENABLED, debugLog } from './harness.js';

// ---------------------------------------------------------------------------
// Config helpers
// ---------------------------------------------------------------------------

const TMP = tmpdir();
const PORT_BASE = parseInt(process.env.PORT_BASE ?? '8700', 10);

function nodeConfig(label, config) {

  if (!config["data-dir"]) {
    config["data-dir"] = path.join(TMP, `libstorage-test-${label}`);
  }

  // Clean up any leftover state from a previous run
  rmSync(config["data-dir"], { recursive: true, force: true });
  mkdirSync(config["data-dir"], { recursive: true });

  if (!config["log-level"]) {
    config["log-level"] = DEBUG_ENABLED ? 'TRACE' : 'ERROR';
  }

  debugLog(`Node '${label}' config:`, config);

  return JSON.stringify(config);
}

/**
 * Finds the first port at or above `port` that is free on both TCP and UDP.
 * TCP is checked for the listen port; UDP is checked because discv5 discovery
 * binds a UDP socket on the same port numbers, and a TCP-only check will miss
 * stale processes that are still holding a UDP port.
 */
function findFreePort(port) {
  return new Promise((resolve) => {
    const tcp = net.createServer();
    tcp.listen(port, '127.0.0.1', () => {
      tcp.close(() => {
        // TCP is free — also verify UDP is free (discv5 binds 0.0.0.0:port)
        const udp = dgram.createSocket('udp4');
        udp.bind(port, () => {
          udp.close(() => resolve(port));
        });
        udp.on('error', () => resolve(findFreePort(port + 1)));
      });
    });
    tcp.on('error', () => resolve(findFreePort(port + 1)));
  });
}

// ---------------------------------------------------------------------------
// Single-node tests — node A started ONCE for the whole describe block
// ---------------------------------------------------------------------------

describe('single-node tests', () => {
  let nodeA;

  before(async () => {
    const [listenPort, discPort] = await Promise.all([
      findFreePort(PORT_BASE),
      findFreePort(PORT_BASE + 1),
    ]);
    nodeA = new StorageNode();
    await nodeA.create(nodeConfig('a', {
      "listen-port": listenPort,
      "disc-port":   discPort,
      "nat":         "extip:127.0.0.1",
    }));
    await nodeA.start();
  });

  after(async () => {
    await nodeA.shutdown();
  });

  it('version is non-empty', () => {
    assert.ok(nodeA.version().length > 0);
  });

  it('peer ID is a non-empty string', async () => {
    const pid = await nodeA.peerId();
    assert.ok(pid && pid.length > 0);
  });

  it('SPR contains "spr"', async () => {
    const spr = await nodeA.spr();
    assert.ok(spr.includes('spr'), `SPR should contain "spr", got: ${spr}`);
  });

  it('debug info has id and addrs', async () => {
    const info = JSON.parse(await nodeA.debug());
    assert.ok(info.id && info.id.length > 0);
    assert.ok(Array.isArray(info.addrs));
  });

  it('upload returns a non-empty CID', async () => {
    const cid = await nodeA.uploadContent('upload test content');
    assert.ok(cid && cid.length > 0);
  });

  it('manifest has expected fields', async () => {
    const cid = await nodeA.uploadContent('manifest test content');
    const m = JSON.parse(await nodeA.downloadManifest(cid));
    assert.ok(m.treeCid && m.treeCid.length > 0);
    assert.equal(typeof m.datasetSize, 'number');
    assert.equal(m.filename, 'test.txt');
  });

  it('list includes uploaded CID', async () => {
    const cid = await nodeA.uploadContent('list test content');
    const listJson = await nodeA.list();
    assert.ok(listJson.includes(cid));
  });

  it('space info has totalBlocks', async () => {
    const s = JSON.parse(await nodeA.space());
    assert.equal(typeof s.totalBlocks, 'number');
  });

  it('exists returns true for uploaded CID', async () => {
    const cid = await nodeA.uploadContent('exists test content');
    assert.equal(await nodeA.exists(cid), true);
  });

  it('local download returns uploaded content', async () => {
    const content = 'local download test content';
    const cid = await nodeA.uploadContent(content);
    assert.equal(await nodeA.downloadContent(cid, true), content);
  });

  it('delete removes content from local store', async () => {
    const cid = await nodeA.uploadContent('ephemeral content for delete test', 'ephemeral.txt');
    await nodeA.delete(cid);
    assert.equal(await nodeA.exists(cid), false);
  });

  it('cancel download does not crash', async () => {
    const cid = await nodeA.uploadContent('cancel test content');
    await nodeA.downloadContent(cid, true); // ensure blocks are cached
    await nodeA.downloadCancel(cid);
    // reaching here without exception means the cancel path is working
  });
});

// ---------------------------------------------------------------------------
// Two-node tests — fresh node pair started/stopped for EACH test
// ---------------------------------------------------------------------------

describe('two-node tests', () => {
  let nodeA, nodeB;
  // add 10 to PORT_BASE to avoid collisions with single-node tests, which use PORT_BASE and PORT_BASE + 1
  let ports = {
    listenA: PORT_BASE + 10,
    discA: PORT_BASE + 11,
    listenB: PORT_BASE + 12,
    discB: PORT_BASE + 13
  };

  beforeEach(async () => {
    const [listenA, discA, listenB, discB] = await Promise.all([
      findFreePort(ports.listenA + 1),
      findFreePort(ports.discA + 1),
      findFreePort(ports.listenB + 1),
      findFreePort(ports.discB + 1),
    ]);
    // update base for next test run to avoid collisions
    ports.listenA = listenA;
    ports.discA = discA;
    ports.listenB = listenB;
    ports.discB = discB;

    nodeA = new StorageNode();
    await nodeA.create(nodeConfig('a', {
      "listen-port": ports.listenA,
      "disc-port":   ports.discA,
      "nat":         "extip:127.0.0.1",
    }));
    await nodeA.start();

    const sprA = await nodeA.spr();

    nodeB = new StorageNode();
    await nodeB.create(nodeConfig('b', {
      "listen-port":    ports.listenB,
      "disc-port":      ports.discB,
      "nat":            "extip:127.0.0.1",
      "bootstrap-node": [sprA],
    }));
    await nodeB.start();
  });

  afterEach(async () => {
    // allSettled ensures node B is shut down even if node A's shutdown throws
    await Promise.allSettled([nodeA.shutdown(), nodeB.shutdown()]);
  });

  it('node B can download content from node A', async () => {
    const content = 'Hello from node A — p2p test content!';
    const cid = await nodeA.uploadContent(content);
    assert.equal(await nodeB.downloadContent(cid, false), content);
  });

  it('node B can fetch a file from node A, which exists locally', async () => {
    const content = 'Content for storage_fetch test';
    const cid = await nodeA.uploadContent(content, 'fetch-test.txt');

    assert.equal(await nodeB.exists(cid), false);
    await nodeB.fetch(cid);
    assert.equal(await nodeB.exists(cid), true);
    assert.equal(await nodeB.downloadContent(cid, true), content);
  });

  it('node B can download all chunks of a file from node A, which exists locally', async () => {
    // 50 KB with a 16 KB chunk size → 4 chunks; exercises the upload loop
    // and multi-progress download on the receiving side.
    const chunkSize = 16 * 1024;
    const content = 'A'.repeat(50 * 1024);
    const cid = await nodeA.uploadContent(content, 'fetch-test.txt', chunkSize);

    assert.equal(await nodeB.exists(cid), false);
    let downloaded = await nodeB.downloadAllChunks(cid, false, chunkSize);
    assert.equal(await nodeB.exists(cid), true);
    assert.equal(downloaded, content);
  });

  it('fetched content is equivalent to streamed content', async () => {
    const content = 'Content for storage_fetch test';
    const cid = await nodeA.uploadContent(content, 'fetch-test.txt');

    await nodeB.fetch(cid);
    const fetched = await nodeB.downloadContent(cid, true); // gets previously fetched content from local store
    const streamed = await nodeB.downloadContent(cid, false); // streams content from network
    assert.equal(fetched, streamed);
  });

  it('streamed content is equivalent to chunked content', async () => {
    const content = 'Content for storage_fetch test';
    const cid = await nodeA.uploadContent(content, 'fetch-test.txt');

    const streamed = await nodeB.downloadContent(cid); // streams content from network
    const chunked = await nodeB.downloadAllChunks(cid); // streams content by chunks from network
    assert.equal(streamed, chunked);
  });

  it('downloaded manifest is equivalent to fetched manifest', async () => {
    const content = 'Content for storage_fetch test';
    const cid = await nodeA.uploadContent(content, 'fetch-test.txt');

    const fetched = await nodeB.fetch(cid);
    const downloaded = await nodeB.downloadManifest(cid)
    assert.equal(fetched, downloaded);
  });

  it('node A has node B in its routing table', async () => {
    const content = 'Hello from node A — p2p test content!';
    const cid = await nodeA.uploadContent(content);
    assert.equal(await nodeB.downloadContent(cid), content);

    const info = JSON.parse(await nodeA.debug());
    assert.ok(info.table?.nodes.length == 1);
    assert.equal(info.table?.nodes[0].peerId, await nodeB.peerId());
  });

  it('large multi-chunk file transfers intact across nodes', async () => {
    // 200 KB with a 16 KB chunk size → 13 chunks; exercises the upload loop
    // and multi-progress download on the receiving side.
    const chunkSize = 16 * 1024;
    const content = 'A'.repeat(200 * 1024);
    const cid = await nodeA.uploadContent(content, 'large.txt', chunkSize);

    // Verify locally on A first
    const local = await nodeA.downloadContent(cid, true, chunkSize);
    assert.equal(local.length, content.length, 'local: length mismatch');
    assert.equal(local, content, 'local: content mismatch');

    // Then verify across the p2p network
    const remote = await nodeB.downloadContent(cid, false, chunkSize);
    assert.equal(remote.length, content.length, 'remote: length mismatch');
    assert.equal(remote, content, 'remote: content mismatch');
  });

  it('node B can download a chunk from node A', async () => {
    // upload 2 chunks worth of data
    const chunkSize = 16 * 1024;
    const content1 = '1'.repeat(31 * 1024);
    const cid1 = await nodeA.uploadContent(content1, 'test.txt', chunkSize);

    // Init a download for cid1, then immediately cancel it.
    await nodeB.downloadInit(cid1, false, chunkSize);
    let chunk = await nodeB.downloadChunk(cid1, chunkSize);
    assert.deepStrictEqual(chunk,
      {
        chunk: content1.slice(0, chunkSize),
        bytes: chunkSize,
        more: true
      }, 'first chunk should match');
    
    chunk = await nodeB.downloadChunk(cid1, chunkSize);
    assert.deepStrictEqual(chunk,
      {
        chunk: content1.slice(chunkSize),
        bytes: (31 - 16) * 1024,
        more: false
      }, 'second chunk should match');
  });

  it('node B remains functional after cancelling a download by chunks', async () => {
    // Upload two independent pieces of content on A.
    const chunkSize = 16 * 1024;
    const content1 = '1'.repeat(50 * 1024);
    const content2 = '2'.repeat(50 * 1024);
    const cid1 = await nodeA.uploadContent(content1);
    const cid2 = await nodeA.uploadContent(content2);

    // Download a chunk of cid1, then immediately cancel it.
    await nodeB.downloadInit(cid1, false, chunkSize);
    let chunk = await nodeB.downloadChunk(cid1, chunkSize);
    assert.equal(chunk.chunk, content1.slice(0, chunkSize), 'first chunk should match');
    await nodeB.downloadCancel(cid1);

    // After cancelling, the library transfers blocks into B's local store as
    // a side-effect of the init, so cid1 should exist locally on B.
    assert.equal(await nodeB.exists(cid1), true, 'cancelled CID should be in local store after init');

    // More importantly, node B must still be functional: it can download a
    // completely fresh CID from the network without any issues.
    const downloaded = await nodeB.downloadContent(cid2, false);
    assert.equal(downloaded, content2, 'should be able to download other content after cancelling a download by chunks');
  });

  it('node B remains functional after cancelling a download stream', async () => {
    // Upload two independent pieces of content on A.
    const chunkSize = 16 * 1024;
    const content1 = '1'.repeat(50 * 1024);
    const content2 = '2'.repeat(50 * 1024);
    const cid1 = await nodeA.uploadContent(content1);
    const cid2 = await nodeA.uploadContent(content2);

    // Download a chunk of cid1, then immediately cancel it upon receipt of first chunk.
    await nodeB.downloadInit(cid1, false, chunkSize);
    await nodeB.streamContent(cid1, false, chunkSize, async (chunk, bytes, _userData) => {
      assert.equal(chunk.chunk, content1.slice(0, chunkSize), 'first chunk should match');
      await nodeB.downloadCancel(cid1);
    });

    // After cancelling, the library transfers blocks into B's local store as
    // a side-effect of the init, so cid1 should exist locally on B.
    assert.equal(await nodeB.exists(cid1), true, 'cancelled CID should be in local store after init');

    // More importantly, node B must still be functional: it can download a
    // completely fresh CID from the network without any issues.
    const downloaded = await nodeB.downloadContent(cid2, false);
    assert.equal(downloaded, content2, 'should be able to download other content after cancelling a download stream');
  });
});

// ---------------------------------------------------------------------------
// Explicit-connect tests — nodes start with no knowledge of each other;
// connection is established by calling storage_connect with peer ID + addrs.
// ---------------------------------------------------------------------------

describe('explicit connect tests', () => {
  let nodeA, nodeB;

  beforeEach(async () => {
    const [listenA, discA, listenB, discB] = await Promise.all([
      findFreePort(PORT_BASE + 20),
      findFreePort(PORT_BASE + 21),
      findFreePort(PORT_BASE + 22),
      findFreePort(PORT_BASE + 23),
    ]);

    // Start A with no bootstrap; B also starts with no knowledge of A
    nodeA = new StorageNode();
    await nodeA.create(nodeConfig('a-exp', {
      'listen-port': listenA,
      'disc-port':   discA,
      'nat':         'extip:127.0.0.1',
    }));
    await nodeA.start();

    nodeB = new StorageNode();
    await nodeB.create(nodeConfig('b-exp', {
      'listen-port': listenB,
      'disc-port':   discB,
      'nat':         'extip:127.0.0.1',
    }));
    await nodeB.start();
  });

  afterEach(async () => {
    await Promise.allSettled([nodeA.shutdown(), nodeB.shutdown()]);
  });

  it('node B connects to node A via peer ID and multiaddresses', async () => {
    // Get A's peer identity and listen addresses from its debug info
    const debugA = JSON.parse(await nodeA.debug());
    const peerIdA = debugA.id;
    // Filter to loopback addresses only so the connect is local
    const addrsA = (debugA.addrs ?? []).filter(a => a.includes('127.0.0.1'));
    assert.ok(addrsA.length > 0, 'node A must have at least one loopback address');

    // B explicitly connects to A by peer ID + addresses (no DHT, no bootstrap)
    await nodeB.connect(peerIdA, addrsA);

    // Verify the connection works end-to-end
    const content = 'Connected via explicit peer ID + addresses';
    const cid = await nodeA.uploadContent(content);
    const downloaded = await nodeB.downloadContent(cid, false);
    assert.equal(downloaded, content);
  });
});
