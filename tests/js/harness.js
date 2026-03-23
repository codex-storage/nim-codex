/**
 * harness.js — koffi FFI wrapper for libstorage
 *
 * Wraps the libstorage C API into a promise-based JS interface.
 * Each async libstorage call (which dispatches work to a thread and calls back
 * with the result) is wrapped into a Promise that resolves on RET_OK or rejects
 * on RET_ERR.
 *
 * NOTE: The StorageCallback msg parameter is declared as 'str' (null-terminated
 * C string). This is correct for text content. For binary chunk downloads,
 * a typed-buffer approach using the len parameter would be needed instead.
 */

import koffi from 'koffi';
import path from 'path';
import { fileURLToPath } from 'url';

export const __dirname = path.dirname(fileURLToPath(import.meta.url));

const libName =
  process.platform === 'darwin' ? 'libstorage.dylib' :
  process.platform === 'win32'  ? 'libstorage.dll'   :
                                   'libstorage.so';

const libPath = path.resolve(__dirname, '../../build', libName);
const lib = koffi.load(libPath);

// Return codes matching libstorage.h
export const RET_OK       = 0;
export const RET_ERR      = 1;
export const RET_PROGRESS = 3;

// typedef void (*StorageCallback)(int callerRet, const char *msg, size_t len, void *userData)
const StorageCallback = koffi.proto(
  'StorageCallback', 'void', ['int', 'str', 'size_t', 'void *']
);

// All libstorage function bindings
const _lib = {
  storage_new: lib.func(
    'void *storage_new(str configJson, StorageCallback *callback, void *userData)'
  ),
  storage_version:  lib.func('str storage_version(void *ctx)'),
  storage_revision: lib.func('str storage_revision(void *ctx)'),
  storage_start: lib.func(
    'int storage_start(void *ctx, StorageCallback *callback, void *userData)'
  ),
  storage_stop: lib.func(
    'int storage_stop(void *ctx, StorageCallback *callback, void *userData)'
  ),
  storage_close: lib.func(
    'int storage_close(void *ctx, StorageCallback *callback, void *userData)'
  ),
  storage_destroy: lib.func('int storage_destroy(void *ctx)'),
  storage_repo: lib.func(
    'int storage_repo(void *ctx, StorageCallback *callback, void *userData)'
  ),
  storage_spr: lib.func(
    'int storage_spr(void *ctx, StorageCallback *callback, void *userData)'
  ),
  storage_debug: lib.func(
    'int storage_debug(void *ctx, StorageCallback *callback, void *userData)'
  ),
  storage_peer_id: lib.func(
    'int storage_peer_id(void *ctx, StorageCallback *callback, void *userData)'
  ),
  storage_log_level: lib.func(
    'int storage_log_level(void *ctx, str logLevel, StorageCallback *callback, void *userData)'
  ),
  storage_upload_init: lib.func(
    'int storage_upload_init(void *ctx, str filepath, size_t chunkSize, StorageCallback *callback, void *userData)'
  ),
  storage_upload_chunk: lib.func(
    'int storage_upload_chunk(void *ctx, str sessionId, void *chunk, size_t len, StorageCallback *callback, void *userData)'
  ),
  storage_upload_finalize: lib.func(
    'int storage_upload_finalize(void *ctx, str sessionId, StorageCallback *callback, void *userData)'
  ),
  storage_upload_cancel: lib.func(
    'int storage_upload_cancel(void *ctx, str sessionId, StorageCallback *callback, void *userData)'
  ),
  storage_upload_file: lib.func(
    'int storage_upload_file(void *ctx, str sessionId, StorageCallback *callback, void *userData)'
  ),
  storage_download_init: lib.func(
    'int storage_download_init(void *ctx, str cid, size_t chunkSize, bool local, StorageCallback *callback, void *userData)'
  ),
  storage_download_stream: lib.func(
    'int storage_download_stream(void *ctx, str cid, size_t chunkSize, bool local, str filepath, StorageCallback *callback, void *userData)'
  ),
  storage_download_chunk: lib.func(
    'int storage_download_chunk(void *ctx, str cid, StorageCallback *callback, void *userData)'
  ),
  storage_download_cancel: lib.func(
    'int storage_download_cancel(void *ctx, str cid, StorageCallback *callback, void *userData)'
  ),
  storage_download_manifest: lib.func(
    'int storage_download_manifest(void *ctx, str cid, StorageCallback *callback, void *userData)'
  ),
  storage_list: lib.func(
    'int storage_list(void *ctx, StorageCallback *callback, void *userData)'
  ),
  storage_space: lib.func(
    'int storage_space(void *ctx, StorageCallback *callback, void *userData)'
  ),
  storage_delete: lib.func(
    'int storage_delete(void *ctx, str cid, StorageCallback *callback, void *userData)'
  ),
  storage_fetch: lib.func(
    'int storage_fetch(void *ctx, str cid, StorageCallback *callback, void *userData)'
  ),
  storage_exists: lib.func(
    'int storage_exists(void *ctx, str cid, StorageCallback *callback, void *userData)'
  ),
};

/**
 * Wraps a single async libstorage call into a Promise.
 *
 * libstorage dispatches work to an internal Nim thread, then calls back
 * from that thread when done. koffi queues thread callbacks onto the Node.js
 * event loop, but the event loop may drain before the callback arrives unless
 * there is an active handle keeping it alive. A setInterval serves this role
 * and is cleared once the callback fires.
 *
 * @param {Function} thunk - (cb) => libFn(ctx, ...args, cb, null)
 *   The thunk receives the koffi callback and must call the libstorage function,
 *   returning its synchronous int result.
 * @param {Object}   opts
 * @param {Function} opts.onProgress - called for each RET_PROGRESS invocation
 * @returns {Promise<string>} resolves with the msg string on RET_OK
 */
function callAsync(thunk, { onProgress } = {}) {
  return new Promise((resolve, reject) => {
    const keepAlive = setInterval(() => {}, 200);

    let cb;
    cb = koffi.register((ret, msg, _len, _userData) => {
      if (ret === RET_PROGRESS) {
        if (onProgress) onProgress(msg);
        return; // callback will fire again; keepAlive remains active
      }
      clearInterval(keepAlive);
      koffi.unregister(cb);
      if (ret === RET_OK) resolve(msg ?? '');
      else reject(new Error(msg ?? `libstorage error (ret=${ret})`));
    }, koffi.pointer(StorageCallback));

    const syncRet = thunk(cb);
    if (typeof syncRet === 'number' && syncRet !== RET_OK) {
      clearInterval(keepAlive);
      koffi.unregister(cb);
      reject(new Error(`libstorage sync dispatch failed (ret=${syncRet})`));
    }
  });
}

export class StorageNode {
  #ctx = null;

  /**
   * Create and initialise a storage node from a JSON config string.
   * Resolves when the node is ready (storage_new callback fires RET_OK).
   */
  async create(configJson) {
    return new Promise((resolve, reject) => {
      let cb = koffi.register((ret, msg, _len, _userData) => {
        koffi.unregister(cb);
        if (ret === RET_OK) resolve();
        else reject(new Error(msg ?? 'storage_new callback failed'));
      }, koffi.pointer(StorageCallback));
      
      this.#ctx = _lib.storage_new(configJson, cb, null);

      if (!this.#ctx) {
        koffi.unregister(cb);
        throw new Error('storage_new returned null — check configJson');
      }
      
    });
  }

  /** Returns the version string synchronously (e.g. "v0.3.2") */
  version() {
    return _lib.storage_version(this.#ctx);
  }

  /** Returns the contracts revision string synchronously */
  revision() {
    return _lib.storage_revision(this.#ctx);
  }

  start() {
    return callAsync(cb => _lib.storage_start(this.#ctx, cb, null));
  }

  stop() {
    return callAsync(cb => _lib.storage_stop(this.#ctx, cb, null));
  }

  close() {
    return callAsync(cb => _lib.storage_close(this.#ctx, cb, null));
  }

  destroy() {
    const ret = _lib.storage_destroy(this.#ctx);
    this.#ctx = null;
    return ret;
  }

  /** Returns the data-dir path string */
  repo() {
    return callAsync(cb => _lib.storage_repo(this.#ctx, cb, null));
  }

  /** Returns the raw SPR URI string (e.g. "spr1qm...") */
  spr() {
    return callAsync(cb => _lib.storage_spr(this.#ctx, cb, null));
  }

  /** Returns the debug info as a JSON string */
  debug() {
    return callAsync(cb => _lib.storage_debug(this.#ctx, cb, null));
  }

  /** Returns the peer ID string */
  peerId() {
    return callAsync(cb => _lib.storage_peer_id(this.#ctx, cb, null));
  }

  /**
   * Set the runtime log level.
   * @param {string} level - e.g. "TRACE", "DEBUG", "INFO", "WARN", "ERROR"
   */
  logLevel(level) {
    return callAsync(cb => _lib.storage_log_level(this.#ctx, level, cb, null));
  }

  /**
   * Upload arbitrary text content as a single chunk.
   * Returns the CID string of the uploaded content.
   */
  async uploadContent(content, name = 'test.txt', chunkSize = 64 * 1024) {
    const sessionId = await callAsync(
      cb => _lib.storage_upload_init(this.#ctx, name, chunkSize, cb, null)
    );

    const buf = Buffer.from(content, 'utf8');
    await callAsync(
      cb => _lib.storage_upload_chunk(this.#ctx, sessionId, buf, buf.byteLength, cb, null)
    );

    const cid = await callAsync(
      cb => _lib.storage_upload_finalize(this.#ctx, sessionId, cb, null)
    );
    return cid;
  }

  /**
   * Cancel an in-progress upload session.
   * @param {string} sessionId
   */
  uploadCancel(sessionId) {
    return callAsync(cb => _lib.storage_upload_cancel(this.#ctx, sessionId, cb, null));
  }

  /**
   * Download content by CID. Collects all RET_PROGRESS chunk messages and
   * joins them as the full content string.
   *
   * @param {string}  cid
   * @param {boolean} local  - true = local store only, false = fetch from network
   * @param {number}  chunkSize
   * @returns {Promise<string>} the downloaded content as a UTF-8 string
   */
  async downloadContent(cid, local = false, chunkSize = 64 * 1024) {
    await callAsync(
      cb => _lib.storage_download_init(this.#ctx, cid, chunkSize, local, cb, null)
    );

    const chunks = [];
    await callAsync(
      cb => _lib.storage_download_stream(this.#ctx, cid, chunkSize, local, null, cb, null),
      { onProgress: (msg) => { if (msg) chunks.push(msg); } }
    );

    return chunks.join('');
  }

  /**
   * Cancel an in-progress download for a CID.
   * @param {string} cid
   */
  downloadCancel(cid) {
    return callAsync(cb => _lib.storage_download_cancel(this.#ctx, cid, cb, null));
  }

  /**
   * Retrieve the manifest JSON for a CID.
   * @param {string} cid
   * @returns {Promise<string>} manifest JSON string
   */
  downloadManifest(cid) {
    return callAsync(cb => _lib.storage_download_manifest(this.#ctx, cid, cb, null));
  }

  /**
   * Retrieve the list of stored manifests as a JSON string.
   * @returns {Promise<string>}
   */
  list() {
    return callAsync(cb => _lib.storage_list(this.#ctx, cb, null));
  }

  /**
   * Retrieve storage space info as a JSON string.
   * @returns {Promise<string>}
   */
  space() {
    return callAsync(cb => _lib.storage_space(this.#ctx, cb, null));
  }

  /**
   * Check whether a CID exists in local store.
   * @param {string} cid
   * @returns {Promise<boolean>}
   */
  async exists(cid) {
    const msg = await callAsync(cb => _lib.storage_exists(this.#ctx, cid, cb, null));
    return msg === 'true';
  }

  /**
   * Delete content by CID from local store.
   * @param {string} cid
   */
  delete(cid) {
    return callAsync(cb => _lib.storage_delete(this.#ctx, cid, cb, null));
  }

  /**
   * Downloads the manifest described by CID, then downloads the dataset content (treeCid in the manifest), storing it locally.
   * Does not return progress updates; resolves when fetch is complete.
   * @param {string} cid
   * @returns {Promise<string>} the fetched manifest (json) content as a UTF-8 string
   */
  fetch(cid) {
    return callAsync(cb => _lib.storage_fetch(this.#ctx, cid, cb, null));
  }

  /** Graceful shutdown: stop → close → destroy */
  async shutdown() {
    await this.stop();
    await this.close();
    this.destroy();
  }
}
