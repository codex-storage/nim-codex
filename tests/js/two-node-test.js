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
 */

import { StorageNode } from './harness.js';
import { rmSync, mkdirSync } from 'fs';
import { tmpdir } from 'os';
import path from 'path';

// ---------------------------------------------------------------------------
// Config helpers
// ---------------------------------------------------------------------------

const TMP = tmpdir();

function nodeConfig(label, config) {// { listenPort, discPort, bootstrapSpr = null }) {
  if (!config["data-dir"]) {
    config["data-dir"] = path.join(TMP, `libstorage-test-${label}`);
  }

  // Clean up any leftover state from a previous run
  rmSync(config["data-dir"], { recursive: true, force: true });
  mkdirSync(config["data-dir"], { recursive: true });

  if (!config["log-level"]) {
    config["log-level"] = 'ERROR';
  }

  console.debug(`Node '${label}' config:`, config);

  return JSON.stringify(config);
}

// ---------------------------------------------------------------------------
// Minimal test runner
// ---------------------------------------------------------------------------

let passed = 0;
let failed = 0;

async function test(name, fn) {
  process.stdout.write(`  ${name} ... `);
  try {
    await fn();
    console.log('PASS');
    passed++;
  } catch (err) {
    console.log(`FAIL\n    ${err.message}`);
    failed++;
  }
}

function assert(condition, message) {
  if (!condition) throw new Error(message ?? 'assertion failed');
}

function assertEqual(actual, expected, label = '') {
  if (actual !== expected) {
    throw new Error(
      `${label ? label + ': ' : ''}expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`
    );
  }
}

// ---------------------------------------------------------------------------
// Test suite
// ---------------------------------------------------------------------------

async function main() {
  console.log('\nlogos-storage two-node p2p test\n');

  const nodeA = new StorageNode();
  const nodeB = new StorageNode();

  // -------------------------------------------------------------------------
  // Setup: start node A, get its SPR, start node B bootstrapped to node A
  // -------------------------------------------------------------------------

  console.log('Setting up nodes...');

  await nodeA.create(nodeConfig('a', {
    "listen-port": 8792,
    "disc-port": 8794,
    "nat": "extip:127.0.0.1",
    // "log-level": 'TRACE'
  }));
  await nodeA.start();
  console.log(`  node A version: ${nodeA.version()}`);

  const sprA = await nodeA.spr();
  console.log(`  node A SPR:     ${sprA.slice(0, 40)}...`);

  await nodeB.create(nodeConfig('b', {
    "listen-port": 8793,
    "disc-port": 8795,
    "nat": "extip:127.0.0.1",
    // "log-level": 'TRACE',
    "bootstrap-node": [sprA]
  }));
  await nodeB.start();
  console.log(`  node B version: ${nodeB.version()}`);

  // Allow time for the bootstrap connection to establish
  // console.log('\nWaiting for p2p connection...');
  // await new Promise(r => setTimeout(r, 3000));

  // -------------------------------------------------------------------------
  // Single-node tests (mirrors tests/cbindings/storage.c single-node suite)
  // -------------------------------------------------------------------------

  console.log('\nSingle-node tests (node A):');

  await test('version is non-empty', () => {
    assert(nodeA.version().length > 0, 'version should be non-empty');
  });

  await test('peer ID is a non-empty string', async () => {
    const pid = await nodeA.peerId();
    assert(pid && pid.length > 0, 'peer ID should be non-empty');
  });

  await test('SPR contains "spr"', async () => {
    const spr = await nodeA.spr();
    assert(spr.includes('spr'), `SPR should contain "spr", got: ${spr}`);
  });

  await test('debug info has id and addrs', async () => {
    const debugJson = await nodeA.debug();
    const info = JSON.parse(debugJson);
    assert(info.id && info.id.length > 0, 'debug.id should be present');
    assert(Array.isArray(info.addrs), 'debug.addrs should be an array');
  });

  const CONTENT = 'Hello from node A — p2p test content!';
  let cid;

  await test('upload content on node A', async () => {
    cid = await nodeA.uploadContent(CONTENT);
    assert(cid && cid.length > 0, 'CID should be a non-empty string');
    console.log(`\n    CID: ${cid}`);
  });

  await test('manifest has expected fields', async () => {
    const manifestJson = await nodeA.downloadManifest(cid);
    const m = JSON.parse(manifestJson);
    assert(m.treeCid && m.treeCid.length > 0, 'manifest.treeCid should be present');
    assert(typeof m.datasetSize === 'number', 'manifest.datasetSize should be a number');
    assert(m.filename === 'test.txt', `manifest.filename should be "test.txt", got "${m.filename}"`);
  });

  await test('list includes uploaded CID manifest', async () => {
    const listJson = await nodeA.list();
    assert(listJson.includes(cid), `list should include CID ${cid}`);
  });

  await test('space info has totalBlocks', async () => {
    const spaceJson = await nodeA.space();
    const s = JSON.parse(spaceJson);
    assert(typeof s.totalBlocks === 'number', 'space.totalBlocks should be a number');
  });

  await test('content exists locally on node A', async () => {
    const exists = await nodeA.exists(cid);
    assert(exists === true, 'exists should return true for uploaded CID');
  });

  await test('content is downloadable locally on node A', async () => {
    const downloaded = await nodeA.downloadContent(cid, true /* local only */);
    assertEqual(downloaded, CONTENT, 'local download on node A');
  });

  // Upload a second piece of content for delete/fetch tests to leave CONTENT available
  let cid2;
  await test('upload second content for delete test', async () => {
    cid2 = await nodeA.uploadContent('ephemeral content for delete test', 'ephemeral.txt');
    assert(cid2 && cid2.length > 0, 'CID2 should be non-empty');
  });

  await test('delete removes content from local store', async () => {
    await nodeA.delete(cid2);
    const exists = await nodeA.exists(cid2);
    assert(exists === false, 'exists should return false after delete');
  });

  await test('cancel download does not crash', async () => {
    // Init a download then immediately cancel it — verifies the cancel path is wired correctly
    await nodeA.downloadContent(cid, true); // ensure blocks are cached
    await nodeA.downloadCancel(cid);
    // If we get here without exception, the cancel path is working
  });

  // -------------------------------------------------------------------------
  // Two-node tests
  // -------------------------------------------------------------------------

  console.log('\nTwo-node tests:');

  await test('node B can download content from node A over p2p', async () => {
    const downloaded = await nodeB.downloadContent(cid, false /* remote */);
    assertEqual(downloaded, CONTENT, 'remote download on node B');
  });

  await test('storage_fetch: node B fetches into local store, then exists locally', async () => {
    // Upload fresh content on A so B definitely doesn't have it yet
    const fetchContent = 'Content for storage_fetch test';
    const fetchCid = await nodeA.uploadContent(fetchContent, 'fetch-test.txt');

    // Verify B doesn't have it locally yet
    const beforeFetch = await nodeB.exists(fetchCid);
    assert(beforeFetch === false, 'B should not have the CID locally before fetch');

    // Fetch into B's local store
    await nodeB.fetch(fetchCid);

    // Now it should exist locally on B
    const afterFetch = await nodeB.exists(fetchCid);
    assert(afterFetch === true, 'B should have the CID locally after fetch');

    // And be downloadable locally
    const downloaded = await nodeB.downloadContent(fetchCid, true /* local only */);
    assertEqual(downloaded, fetchContent, 'fetched content should match');
  });

  await test('node B peer ID is non-empty', async () => {
    const pid = await nodeB.peerId();
    assert(pid && pid.length > 0, 'node B peer ID should be non-empty');
  });

  await test('node A debug info shows node B in routing table', async () => {
    const debugJson = await nodeA.debug();
    const info = JSON.parse(debugJson);
    // After 3s connection, node B should appear in node A's routing table
    assert(Array.isArray(info.table?.nodes), 'debug.table.nodes should be an array');
    assert(info.table.nodes.length > 0, 'routing table should contain at least one peer (node B)');
  });

  // -------------------------------------------------------------------------
  // Teardown
  // -------------------------------------------------------------------------

  console.log('\nShutting down nodes...');
  await nodeA.shutdown();
  await nodeB.shutdown();

  // -------------------------------------------------------------------------
  // Summary
  // -------------------------------------------------------------------------

  console.log(`\n${passed + failed} tests: ${passed} passed, ${failed} failed\n`);
  if (failed > 0) process.exit(1);
}

main().catch(err => {
  console.error('\nFatal error:', err);
  process.exit(1);
});
