package main

/*
	#cgo LDFLAGS: -L../../build/ -lcodex
	#cgo LDFLAGS: -L../../ -Wl,-rpath,../../

	#include "../../library/libcodex.h"
	#include <stdio.h>
	#include <stdlib.h>
	#include <stdint.h>

	void libcodexNimMain(void);
	static void codex_host_init_once(void){
		static int done;
		if (!__atomic_exchange_n(&done, 1, __ATOMIC_SEQ_CST)) libcodexNimMain();
	}

	extern void globalEventCallback(int ret, char* msg, size_t len, void* userData);

	typedef struct {
		int ret;
		char* msg;
		size_t len;
		uintptr_t h;
	} Resp;

	static void* allocResp(uintptr_t h) {
		Resp* r = (Resp*)calloc(1, sizeof(Resp));
		r->h = h;
		return r;
	}

	static void freeResp(void* resp) {
		if (resp != NULL) {
			free(resp);
		}
	}

	static int getRet(void* resp) {
		if (resp == NULL) {
			return 0;
		}
		Resp* m = (Resp*) resp;
		return m->ret;
	}

	static char* getMyCharPtr(void* resp) {
		if (resp == NULL) {
			return NULL;
		}
		Resp* m = (Resp*) resp;
		return m->msg;
	}

	static size_t getMyCharLen(void* resp) {
		if (resp == NULL) {
			return 0;
		}
		Resp* m = (Resp*) resp;
		return m->len;
	}

	// resp must be set != NULL in case interest on retrieving data from the callback
	void callback(int ret, char* msg, size_t len, void* resp);

	static void* cGoCodexNew(const char* configJson, void* resp) {
		void* ret = codex_new(configJson, (CodexCallback) callback, resp);
		return ret;
	}

	static int cGoCodexVersion(void* codexCtx, void* resp) {
		return codex_version(codexCtx, (CodexCallback) callback, resp);
	}

	static int cGoCodexRevision(void* codexCtx, void* resp) {
		return codex_revision(codexCtx, (CodexCallback) callback, resp);
	}

	static int cGoCodexRepo(void* codexCtx, void* resp) {
		return codex_repo(codexCtx, (CodexCallback) callback, resp);
	}

	static int cGoCodexDebug(void* codexCtx, void* resp) {
		return codex_debug(codexCtx, (CodexCallback) callback, resp);
	}

	static int cGoCodexSpr(void* codexCtx, void* resp) {
		return codex_spr(codexCtx, (CodexCallback) callback, resp);
	}

	static int cGoCodexPeerId(void* codexCtx, void* resp) {
		return codex_peer_id(codexCtx, (CodexCallback) callback, resp);
	}

	static int cGoCodexLogLevel(void* codexCtx, char* logLevel, void* resp) {
		return codex_log_level(codexCtx, logLevel, (CodexCallback) callback, resp);
	}

	static int cGoCodexConnect(void* codexCtx, char* peerId, const char** peerAddresses, uintptr_t peerAddressesSize,  void* resp) {
		return codex_connect(codexCtx, peerId, peerAddresses, peerAddressesSize, (CodexCallback) callback, resp);
	}

	static int cGoCodexPeerDebug(void* codexCtx, char* peerId, void* resp) {
		return codex_peer_debug(codexCtx, peerId, (CodexCallback) callback, resp);
	}

	static int cGoCodexUploadInit(void* codexCtx, char* filepath, size_t chunkSize, void* resp) {
		return codex_upload_init(codexCtx, filepath, chunkSize, (CodexCallback) callback, resp);
	}

	static int cGoCodexUploadChunk(void* codexCtx, char* sessionId, const uint8_t* chunk, size_t len, void* resp) {
		return codex_upload_chunk(codexCtx, sessionId, chunk, len, (CodexCallback) callback, resp);
	}

	static int cGoCodexUploadFinalize(void* codexCtx, char* sessionId, void* resp) {
		return codex_upload_finalize(codexCtx, sessionId, (CodexCallback) callback, resp);
	}

	static int cGoCodexUploadCancel(void* codexCtx, char* sessionId, void* resp) {
		return codex_upload_cancel(codexCtx, sessionId, (CodexCallback) callback, resp);
	}

	static int cGoCodexUploadFile(void* codexCtx, char* sessionId, void* resp) {
		return codex_upload_file(codexCtx, sessionId, (CodexCallback) callback, resp);
	}

	static int cGoCodexDownloadInit(void* codexCtx, char* cid, size_t chunkSize, bool local, void* resp) {
		return codex_download_init(codexCtx, cid, chunkSize, local, (CodexCallback) callback, resp);
	}

	static int cGoCodexDownloadChunk(void* codexCtx, char* cid, void* resp) {
		return codex_download_chunk(codexCtx, cid, (CodexCallback) callback, resp);
	}

	static int cGoCodexDownloadStream(void* codexCtx, char* cid, size_t chunkSize, bool local, const char* filepath, void* resp) {
		return codex_download_stream(codexCtx, cid, chunkSize, local, filepath, (CodexCallback) callback, resp);
	}

	static int cGoCodexDownloadCancel(void* codexCtx, char* cid, void* resp) {
		return codex_download_cancel(codexCtx, cid, (CodexCallback) callback, resp);
	}

	static int cGoCodexDownloadManifest(void* codexCtx, char* cid, void* resp) {
		return codex_download_manifest(codexCtx, cid, (CodexCallback) callback, resp);
	}

	static int cGoCodexStorageList(void* codexCtx, void* resp) {
		return codex_storage_list(codexCtx, (CodexCallback) callback, resp);
	}

	static int cGoCodexStorageFetch(void* codexCtx, char* cid, void* resp) {
		return codex_storage_fetch(codexCtx, cid, (CodexCallback) callback, resp);
	}

	static int cGoCodexStorageSpace(void* codexCtx, void* resp) {
		return codex_storage_space(codexCtx, (CodexCallback) callback, resp);
	}

	static int cGoCodexStorageDelete(void* codexCtx, char* cid, void* resp) {
		return codex_storage_delete(codexCtx, cid, (CodexCallback) callback, resp);
	}

	static int cGoCodexStart(void* codexCtx, void* resp) {
		return codex_start(codexCtx, (CodexCallback) callback, resp);
	}

	static int cGoCodexStop(void* codexCtx, void* resp) {
		return codex_stop(codexCtx, (CodexCallback) callback, resp);
	}

	static int cGoCodexDestroy(void* codexCtx, void* resp) {
		return codex_destroy(codexCtx, (CodexCallback) callback, resp);
	}

	static void cGoCodexSetEventCallback(void* codexCtx) {
		// The 'globalEventCallback' Go function is shared amongst all possible Codex instances.

		// Given that the 'globalEventCallback' is shared, we pass again the
		// codexCtx instance but in this case is needed to pick up the correct method
		// that will handle the event.

		// In other words, for every call the libcodex makes to globalEventCallback,
		// the 'userData' parameter will bring the context of the node that registered
		// that globalEventCallback.

		// This technique is needed because cgo only allows to export Go functions and not methods.

		codex_set_event_callback(codexCtx, (CodexCallback) globalEventCallback, codexCtx);
	}

*/
import "C"
import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"os/signal"
	"path"
	"runtime/cgo"
	"sync"
	"syscall"
	"unsafe"
)

type LogLevel string

const (
	Trace  LogLevel = "TRACE"
	Debug  LogLevel = "DEBUG"
	Info   LogLevel = "INFO"
	Notice LogLevel = "NOTICE"
	Warn   LogLevel = "WARN"
	Error  LogLevel = "ERROR"
	Fatal  LogLevel = "FATAL"
)

type LogFormat string

const (
	LogFormatAuto     LogFormat = "auto"
	LogFormatColors   LogFormat = "colors"
	LogFormatNoColors LogFormat = "nocolors"
	LogFormatJSON     LogFormat = "json"
)

type RepoKind string

const (
	FS      RepoKind = "fs"
	SQLite  RepoKind = "sqlite"
	LevelDb RepoKind = "leveldb"
)

type CodexConfig struct {
	LogFormat                      LogFormat `json:"log-format,omitempty"`
	MetricsEnabled                 bool      `json:"metrics,omitempty"`
	MetricsAddress                 string    `json:"metrics-address,omitempty"`
	DataDir                        string    `json:"data-dir,omitempty"`
	ListenAddrs                    []string  `json:"listen-addrs,omitempty"`
	Nat                            string    `json:"nat,omitempty"`
	DiscoveryPort                  int       `json:"disc-port,omitempty"`
	NetPrivKeyFile                 string    `json:"net-privkey,omitempty"`
	BootstrapNodes                 []byte    `json:"bootstrap-node,omitempty"`
	MaxPeers                       int       `json:"max-peers,omitempty"`
	NumThreads                     int       `json:"num-threads,omitempty"`
	AgentString                    string    `json:"agent-string,omitempty"`
	RepoKind                       RepoKind  `json:"repo-kind,omitempty"`
	StorageQuota                   int       `json:"storage-quota,omitempty"`
	BlockTtl                       int       `json:"block-ttl,omitempty"`
	BlockMaintenanceInterval       int       `json:"block-mi,omitempty"`
	BlockMaintenanceNumberOfBlocks int       `json:"block-mn,omitempty"`
	CacheSize                      int       `json:"cache-size,omitempty"`
	LogFile                        string    `json:"log-file,omitempty"`
}

type RestPeerRecord struct {
	PeerId    string   `json:"peerId"`
	SeqNo     int      `json:"seqNo"`
	Addresses []string `json:"addresses,omitempty"`
}

type RestNode struct {
	NodeId  string  `json:"nodeId"`
	PeerId  string  `json:"peerId"`
	Record  string  `json:"record"`
	Address *string `json:"address"`
	Seen    bool    `json:"seen"`
}

type RestRoutingTable struct {
	LocalNode RestNode   `json:"localNode"`
	Nodes     []RestNode `json:"nodes"`
}

type CodexDebugInfo struct {
	ID                string           `json:"id"`
	Addrs             []string         `json:"addrs"`
	Spr               string           `json:"spr"`
	AnnounceAddresses []string         `json:"announceAddresses"`
	Table             RestRoutingTable `json:"table"`
}

type CodexNode struct {
	ctx unsafe.Pointer
}

const defaultBlockSize = 1024 * 64

type OnUploadProgressFunc func(read, total int, percent float64, err error)

type ChunckSize int

type CodexUploadOptions struct {
	filepath   string
	chunkSize  ChunckSize
	onProgress OnUploadProgressFunc
}

func (c ChunckSize) valOrDefault() int {
	if c == 0 {
		return defaultBlockSize
	}

	return int(c)
}

func (c ChunckSize) toSizeT() C.size_t {
	return C.size_t(c.valOrDefault())
}

type CodexDownloadStreamOptions = struct {
	filepath        string
	chunkSize       ChunckSize
	onProgress      OnUploadProgressFunc
	writer          io.Writer
	local           bool
	datasetSize     int
	datasetSizeAuto bool
}

type CodexDownloadInitOptions = struct {
	local     bool
	chunkSize ChunckSize
}

type bridgeCtx struct {
	wg     *sync.WaitGroup
	h      cgo.Handle
	resp   unsafe.Pointer
	result string
	err    error

	// Callback used for receiving progress updates during upload/download.
	//
	// For the upload, the bytes parameter indicates the number of bytes uploaded.
	// If the chunk size is superior or equal to the blocksize (passed in init function),
	// the callback will be called when a block is put in the store.
	// Otherwise, it will be called when a chunk is pushed into the stream.
	//
	// For the download, the bytes is the size of the chunk received, and the chunk
	// is the actual chunk of data received.
	onProgress func(bytes int, chunk []byte)
}

type CodexManifest struct {
	Cid         string
	TreeCid     string `json:"treeCid"`
	DatasetSize int    `json:"datasetSize"`
	BlockSize   int    `json:"blockSize"`
	Filename    string `json:"filename"`
	Mimetype    string `json:"mimetype"`
	Protected   bool   `json:"protected"`
}

type CodexManifestWithCid struct {
	Cid      string        `json:"cid"`
	Manifest CodexManifest `json:"manifest"`
}

type CodexSpace struct {
	TotalBlocks        int   `json:"totalBlocks"`
	QuotaMaxBytes      int64 `json:"quotaMaxBytes"`
	QuotaUsedBytes     int64 `json:"quotaUsedBytes"`
	QuotaReservedBytes int64 `json:"quotaReservedBytes"`
}

func newBridgeCtx() *bridgeCtx {
	bridge := &bridgeCtx{}
	bridge.wg = &sync.WaitGroup{}
	bridge.wg.Add(1)
	bridge.h = cgo.NewHandle(bridge)
	bridge.resp = C.allocResp(C.uintptr_t(uintptr(bridge.h)))

	return bridge
}

func (b *bridgeCtx) free() {
	if b.h > 0 {
		b.h.Delete()
		b.h = 0
	}

	if b.resp != nil {
		C.freeResp(b.resp)
		b.resp = nil
	}
}

func (b *bridgeCtx) CallError(name string) error {
	return fmt.Errorf("Failed the call to %s. Returned code: %d.", name, C.getRet(b.resp))
}

func (b *bridgeCtx) wait() (string, error) {
	b.wg.Wait()

	return b.result, b.err
}

func getReaderSize(r io.Reader) int64 {
	switch v := r.(type) {
	case *os.File:
		stat, err := v.Stat()
		if err != nil {
			return 0
		}
		return stat.Size()
	case *bytes.Buffer:
		return int64(v.Len())
	default:
		return 0
	}
}

//export callback
func callback(ret C.int, msg *C.char, len C.size_t, resp unsafe.Pointer) {
	if resp == nil {
		return
	}

	m := (*C.Resp)(resp)
	m.ret = ret
	m.msg = msg
	m.len = len

	if m.h == 0 {
		return
	}

	h := cgo.Handle(m.h)

	if h == 0 {
		return
	}

	if v, ok := h.Value().(*bridgeCtx); ok {
		switch ret {
		case C.RET_PROGRESS:
			if v.onProgress == nil {
				return
			}

			if msg != nil {
				chunk := C.GoBytes(unsafe.Pointer(msg), C.int(len))
				v.onProgress(int(C.int(len)), chunk)
			} else {
				v.onProgress(int(C.int(len)), nil)
			}
		case C.RET_OK:
			retMsg := C.GoStringN(msg, C.int(len))
			v.result = retMsg
			v.err = nil

			if v.wg != nil {
				v.wg.Done()
			}
		case C.RET_ERR:
			retMsg := C.GoStringN(msg, C.int(len))
			v.err = errors.New(retMsg)

			if v.wg != nil {
				v.wg.Done()
			}
		}
	}
}

func CodexNew(config CodexConfig) (*CodexNode, error) {
	bridge := newBridgeCtx()
	defer bridge.free()

	jsonConfig, err := json.Marshal(config)

	if err != nil {
		return nil, err
	}

	cJsonConfig := C.CString(string(jsonConfig))
	defer C.free(unsafe.Pointer(cJsonConfig))

	ctx := C.cGoCodexNew(cJsonConfig, bridge.resp)

	if _, err := bridge.wait(); err != nil {
		return nil, bridge.err
	}

	return &CodexNode{ctx: ctx}, bridge.err
}

func (self CodexNode) CodexVersion() (string, error) {
	bridge := newBridgeCtx()
	defer bridge.free()

	if C.cGoCodexVersion(self.ctx, bridge.resp) != C.RET_OK {
		return "", bridge.CallError("cGoCodexVersion")
	}

	return bridge.wait()
}

func (self CodexNode) CodexRevision() (string, error) {
	bridge := newBridgeCtx()
	defer bridge.free()

	if C.cGoCodexRevision(self.ctx, bridge.resp) != C.RET_OK {
		return "", bridge.CallError("cGoCodexRevision")
	}

	return bridge.wait()
}

func (self CodexNode) CodexRepo() (string, error) {
	bridge := newBridgeCtx()
	defer bridge.free()

	if C.cGoCodexRepo(self.ctx, bridge.resp) != C.RET_OK {
		return "", bridge.CallError("cGoCodexRepo")
	}

	return bridge.wait()
}

func (self CodexNode) CodexDebug() (CodexDebugInfo, error) {
	var info CodexDebugInfo

	bridge := newBridgeCtx()
	defer bridge.free()

	if C.cGoCodexDebug(self.ctx, bridge.resp) != C.RET_OK {
		return info, bridge.CallError("cGoCodexDebug")
	}

	value, err := bridge.wait()
	if err != nil {
		return info, err
	}

	err = json.Unmarshal([]byte(value), &info)

	return info, err
}

func (self CodexNode) CodexSpr() (string, error) {
	bridge := newBridgeCtx()
	defer bridge.free()

	if C.cGoCodexSpr(self.ctx, bridge.resp) != C.RET_OK {
		return "", bridge.CallError("cGoCodexSpr")
	}

	return bridge.wait()
}

func (self CodexNode) CodexPeerId() (string, error) {
	bridge := newBridgeCtx()
	defer bridge.free()

	if C.cGoCodexPeerId(self.ctx, bridge.resp) != C.RET_OK {
		return "", bridge.CallError("cGoCodexPeerId")
	}

	return bridge.wait()
}

func (self CodexNode) CodexLogLevel(logLevel LogLevel) error {
	bridge := newBridgeCtx()
	defer bridge.free()

	var cLogLevel = C.CString(fmt.Sprintf("%s", logLevel))
	defer C.free(unsafe.Pointer(cLogLevel))

	if C.cGoCodexLogLevel(self.ctx, cLogLevel, bridge.resp) != C.RET_OK {
		return bridge.CallError("cGoCodexLogLevel")
	}

	_, err := bridge.wait()

	return err
}

func (self CodexNode) CodexConnect(peerId string, peerAddresses []string) error {
	bridge := newBridgeCtx()
	defer bridge.free()

	var cPeerId = C.CString(peerId)
	defer C.free(unsafe.Pointer(cPeerId))

	if len(peerAddresses) > 0 {
		var cAddresses = make([]*C.char, len(peerAddresses))
		for i, addr := range peerAddresses {
			cAddresses[i] = C.CString(addr)
			defer C.free(unsafe.Pointer(cAddresses[i]))
		}

		if C.cGoCodexConnect(self.ctx, cPeerId, &cAddresses[0], C.uintptr_t(len(peerAddresses)), bridge.resp) != C.RET_OK {
			return bridge.CallError("cGoCodexConnect")
		}
	} else {
		if C.cGoCodexConnect(self.ctx, cPeerId, nil, 0, bridge.resp) != C.RET_OK {
			return bridge.CallError("cGoCodexConnect")
		}
	}

	_, err := bridge.wait()
	return err
}

func (self CodexNode) CodexPeerDebug(peerId string) (RestPeerRecord, error) {
	var record RestPeerRecord

	bridge := newBridgeCtx()
	defer bridge.free()

	var cPeerId = C.CString(peerId)
	defer C.free(unsafe.Pointer(cPeerId))

	if C.cGoCodexPeerDebug(self.ctx, cPeerId, bridge.resp) != C.RET_OK {
		return record, bridge.CallError("cGoCodexPeerDebug")
	}

	value, err := bridge.wait()
	if err != nil {
		return record, err
	}

	err = json.Unmarshal([]byte(value), &record)

	return record, err
}

func (self CodexNode) CodexUploadInit(options *CodexUploadOptions) (string, error) {
	bridge := newBridgeCtx()
	defer bridge.free()

	var cFilename = C.CString(options.filepath)
	defer C.free(unsafe.Pointer(cFilename))

	if C.cGoCodexUploadInit(self.ctx, cFilename, options.chunkSize.toSizeT(), bridge.resp) != C.RET_OK {
		return "", bridge.CallError("cGoCodexUploadInit")
	}

	return bridge.wait()
}

func (self CodexNode) CodexUploadChunk(sessionId string, chunk []byte) error {
	bridge := newBridgeCtx()
	defer bridge.free()

	var cSessionId = C.CString(sessionId)
	defer C.free(unsafe.Pointer(cSessionId))

	var cChunkPtr *C.uint8_t
	if len(chunk) > 0 {
		cChunkPtr = (*C.uint8_t)(unsafe.Pointer(&chunk[0]))
	}

	if C.cGoCodexUploadChunk(self.ctx, cSessionId, cChunkPtr, C.size_t(len(chunk)), bridge.resp) != C.RET_OK {
		return bridge.CallError("cGoCodexUploadChunk")
	}

	_, err := bridge.wait()

	return err
}

func (self CodexNode) CodexUploadFinalize(sessionId string) (string, error) {
	bridge := newBridgeCtx()
	defer bridge.free()

	var cSessionId = C.CString(sessionId)
	defer C.free(unsafe.Pointer(cSessionId))

	if C.cGoCodexUploadFinalize(self.ctx, cSessionId, bridge.resp) != C.RET_OK {
		return "", bridge.CallError("cGoCodexUploadFinalize")
	}

	return bridge.wait()
}

func (self CodexNode) CodexUploadCancel(sessionId string) error {
	bridge := newBridgeCtx()
	defer bridge.free()

	var cSessionId = C.CString(sessionId)
	defer C.free(unsafe.Pointer(cSessionId))

	if C.cGoCodexUploadCancel(self.ctx, cSessionId, bridge.resp) != C.RET_OK {
		return bridge.CallError("cGoCodexUploadCancel")
	}

	_, err := bridge.wait()

	return err
}

func (self CodexNode) CodexUploadReader(options CodexUploadOptions, r io.Reader) (string, error) {
	sessionId, err := self.CodexUploadInit(&options)

	if err != nil {
		return "", err
	}

	buf := make([]byte, options.chunkSize.valOrDefault())
	total := 0
	var size int64

	if options.onProgress != nil {
		size = getReaderSize(r)
	}

	for {
		n, err := r.Read(buf)

		if err == io.EOF {
			break
		}

		if err != nil {
			if cancelErr := self.CodexUploadCancel(sessionId); cancelErr != nil {
				return "", fmt.Errorf("failed to upload chunk %v and failed to cancel upload session %v", err, cancelErr)
			}

			return "", err
		}

		if n == 0 {
			break
		}

		if err := self.CodexUploadChunk(sessionId, buf[:n]); err != nil {
			if cancelErr := self.CodexUploadCancel(sessionId); cancelErr != nil {
				return "", fmt.Errorf("failed to upload chunk %v and failed to cancel upload session %v", err, cancelErr)
			}

			return "", err
		}

		total += n
		if options.onProgress != nil && size > 0 {
			percent := float64(total) / float64(size) * 100.0
			// The last block could be a bit over the size due to padding
			// on the chunk size.
			if percent > 100.0 {
				percent = 100.0
			}
			options.onProgress(n, total, percent, nil)
		}
	}

	return self.CodexUploadFinalize(sessionId)
}

func (self CodexNode) CodexUploadReaderAsync(options CodexUploadOptions, r io.Reader, onDone func(cid string, err error)) {
	go func() {
		cid, err := self.CodexUploadReader(options, r)
		onDone(cid, err)
	}()
}

func (self CodexNode) CodexUploadFile(options CodexUploadOptions) (string, error) {
	bridge := newBridgeCtx()
	defer bridge.free()

	if options.onProgress != nil {
		stat, err := os.Stat(options.filepath)

		if err != nil {
			return "", err
		}

		size := stat.Size()
		total := 0

		if size > 0 {
			bridge.onProgress = func(read int, _ []byte) {
				if read == 0 {
					return
				}

				total += read

				percent := float64(total) / float64(size) * 100.0
				// The last block could be a bit over the size due to padding
				// on the chunk size.
				if percent > 100.0 {
					percent = 100.0
				}

				options.onProgress(read, int(size), percent, nil)
			}
		}
	}

	sessionId, err := self.CodexUploadInit(&options)
	if err != nil {
		return "", err
	}

	var cSessionId = C.CString(sessionId)
	defer C.free(unsafe.Pointer(cSessionId))

	if C.cGoCodexUploadFile(self.ctx, cSessionId, bridge.resp) != C.RET_OK {
		return "", bridge.CallError("cGoCodexUploadFile")
	}

	return bridge.wait()
}

func (self CodexNode) CodexUploadFileAsync(options CodexUploadOptions, onDone func(cid string, err error)) {
	go func() {
		cid, err := self.CodexUploadFile(options)
		onDone(cid, err)
	}()
}

func (self CodexNode) CodexDownloadManifest(cid string) (CodexManifest, error) {
	bridge := newBridgeCtx()
	defer bridge.free()

	var cCid = C.CString(cid)
	defer C.free(unsafe.Pointer(cCid))

	if C.cGoCodexDownloadManifest(self.ctx, cCid, bridge.resp) != C.RET_OK {
		return CodexManifest{}, bridge.CallError("cGoCodexDownloadManifest")
	}

	val, err := bridge.wait()
	if err != nil {
		return CodexManifest{}, err
	}

	manifest := CodexManifest{Cid: cid}
	err = json.Unmarshal([]byte(val), &manifest)
	if err != nil {
		return CodexManifest{}, err
	}

	return manifest, nil
}

func (self CodexNode) CodexDownloadStream(cid string, options CodexDownloadStreamOptions) error {
	bridge := newBridgeCtx()
	defer bridge.free()

	if options.datasetSizeAuto {
		manifest, err := self.CodexDownloadManifest(cid)

		if err != nil {
			return err
		}

		options.datasetSize = manifest.DatasetSize
	}

	total := 0
	bridge.onProgress = func(read int, chunk []byte) {
		if read == 0 {
			return
		}

		if options.writer != nil {
			w := options.writer
			if _, err := w.Write(chunk); err != nil {
				if options.onProgress != nil {
					options.onProgress(0, 0, 0.0, err)
				}
			}
		}

		total += read

		if options.onProgress != nil {
			var percent = 0.0
			if options.datasetSize > 0 {
				percent = float64(total) / float64(options.datasetSize) * 100.0
			}

			options.onProgress(read, total, percent, nil)
		}
	}

	var cCid = C.CString(cid)
	defer C.free(unsafe.Pointer(cCid))

	var cFilepath = C.CString(options.filepath)
	defer C.free(unsafe.Pointer(cFilepath))

	var cLocal = C.bool(options.local)

	if C.cGoCodexDownloadStream(self.ctx, cCid, options.chunkSize.toSizeT(), cLocal, cFilepath, bridge.resp) != C.RET_OK {
		return bridge.CallError("cGoCodexDownloadLocal")
	}

	_, err := bridge.wait()

	return err
}

func (self CodexNode) CodexDownloadInit(cid string, options CodexDownloadInitOptions) error {
	bridge := newBridgeCtx()
	defer bridge.free()

	var cCid = C.CString(cid)
	defer C.free(unsafe.Pointer(cCid))

	var cLocal = C.bool(options.local)

	if C.cGoCodexDownloadInit(self.ctx, cCid, options.chunkSize.toSizeT(), cLocal, bridge.resp) != C.RET_OK {
		return bridge.CallError("cGoCodexDownloadInit")
	}

	_, err := bridge.wait()

	return err
}

func (self CodexNode) CodexDownloadChunk(cid string) ([]byte, error) {
	bridge := newBridgeCtx()
	defer bridge.free()

	var bytes []byte

	bridge.onProgress = func(read int, chunk []byte) {
		bytes = chunk
	}

	var cCid = C.CString(cid)
	defer C.free(unsafe.Pointer(cCid))

	if C.cGoCodexDownloadChunk(self.ctx, cCid, bridge.resp) != C.RET_OK {
		return nil, bridge.CallError("cGoCodexDownloadChunk")
	}

	if _, err := bridge.wait(); err != nil {
		return nil, err
	}

	return bytes, nil
}

func (self CodexNode) CodexDownloadCancel(cid string) error {
	bridge := newBridgeCtx()
	defer bridge.free()

	var cCid = C.CString(cid)
	defer C.free(unsafe.Pointer(cCid))

	if C.cGoCodexDownloadCancel(self.ctx, cCid, bridge.resp) != C.RET_OK {
		return bridge.CallError("cGoCodexDownloadCancel")
	}

	_, err := bridge.wait()

	return err
}

func (self CodexNode) CodexStorageList() ([]CodexManifest, error) {
	bridge := newBridgeCtx()
	defer bridge.free()

	if C.cGoCodexStorageList(self.ctx, bridge.resp) != C.RET_OK {
		return nil, bridge.CallError("cGoCodexStorageList")
	}
	value, err := bridge.wait()
	if err != nil {
		return nil, err
	}

	var items []CodexManifestWithCid
	err = json.Unmarshal([]byte(value), &items)
	if err != nil {
		return nil, err
	}

	var list []CodexManifest
	for _, item := range items {
		item.Manifest.Cid = item.Cid
		list = append(list, item.Manifest)
	}

	return list, err
}

func (self CodexNode) CodexStorageFetch(cid string) (CodexManifest, error) {
	bridge := newBridgeCtx()
	defer bridge.free()

	var cCid = C.CString(cid)
	defer C.free(unsafe.Pointer(cCid))

	if C.cGoCodexStorageFetch(self.ctx, cCid, bridge.resp) != C.RET_OK {
		return CodexManifest{}, bridge.CallError("cGoCodexStorageFetch")
	}

	value, err := bridge.wait()
	if err != nil {
		return CodexManifest{}, err
	}

	var manifest CodexManifest
	err = json.Unmarshal([]byte(value), &manifest)
	if err != nil {
		return CodexManifest{}, err
	}

	manifest.Cid = cid

	return manifest, nil
}

func (self CodexNode) CodexStorageSpace() (CodexSpace, error) {
	var space CodexSpace

	bridge := newBridgeCtx()
	defer bridge.free()

	if C.cGoCodexStorageSpace(self.ctx, bridge.resp) != C.RET_OK {
		return space, bridge.CallError("cGoCodexStorageSpace")
	}

	value, err := bridge.wait()
	if err != nil {
		return space, err
	}

	err = json.Unmarshal([]byte(value), &space)

	return space, err
}

func (self CodexNode) CodexStorageDelete(cid string) error {
	bridge := newBridgeCtx()
	defer bridge.free()

	var cCid = C.CString(cid)
	defer C.free(unsafe.Pointer(cCid))

	if C.cGoCodexStorageDelete(self.ctx, cCid, bridge.resp) != C.RET_OK {
		return bridge.CallError("cGoCodexStorageDelete")
	}

	_, err := bridge.wait()
	return err
}

func (self CodexNode) CodexStart() error {
	bridge := newBridgeCtx()
	defer bridge.free()

	if C.cGoCodexStart(self.ctx, bridge.resp) != C.RET_OK {
		return bridge.CallError("cGoCodexStart")
	}

	_, err := bridge.wait()

	return err
}

func (self CodexNode) CodexStartAsync(onDone func(error)) {
	go func() {
		err := self.CodexStart()
		onDone(err)
	}()
}

func (self CodexNode) CodexStop() error {
	bridge := newBridgeCtx()

	if C.cGoCodexStop(self.ctx, bridge.resp) != C.RET_OK {
		return bridge.CallError("cGoCodexStop")
	}

	_, err := bridge.wait()
	return err
}

func (self CodexNode) CodexDestroy() error {
	bridge := newBridgeCtx()

	if C.cGoCodexDestroy(self.ctx, bridge.resp) != C.RET_OK {
		return bridge.CallError("cGoCodexDestroy")
	}

	_, err := bridge.wait()
	return err
}

//export globalEventCallback
func globalEventCallback(callerRet C.int, msg *C.char, len C.size_t, userData unsafe.Pointer) {
	// This is shared among all Golang instances

	self := CodexNode{ctx: userData}
	self.MyEventCallback(callerRet, msg, len)
}

func (self CodexNode) MyEventCallback(callerRet C.int, msg *C.char, len C.size_t) {
	log.Println("Event received:", C.GoStringN(msg, C.int(len)))
}

func (self CodexNode) CodexSetEventCallback() {
	// Notice that the events for self node are handled by the 'MyEventCallback' method
	C.cGoCodexSetEventCallback(self.ctx)
}

func main() {
	config := CodexConfig{}

	node, err := CodexNew(config)
	if err != nil {
		log.Fatal("Error happened:", err.Error())
	}

	log.Println("Codex created.")

	node.CodexSetEventCallback()

	version, err := node.CodexVersion()
	if err != nil {
		log.Fatal("Error happened:", err.Error())
	}

	log.Println("Codex version:", version)

	revision, err := node.CodexRevision()
	if err != nil {
		log.Fatal("Error happened:", err.Error())
	}

	log.Println("Codex revision:", revision)

	repo, err := node.CodexRepo()
	if err != nil {
		log.Fatal("Error happened:", err.Error())
	}

	log.Println("Codex repo:", repo)

	log.Println("Starting Codex...")

	err = node.CodexStart()

	if err != nil {
		log.Fatal("Error happened:", err.Error())
	}

	log.Println("Codex started...")

	// for i := 0; i < 150; i++ {

	debug, err := node.CodexDebug()
	if err != nil {
		log.Fatal("Error happened:", err.Error())
	}

	pretty, err := json.MarshalIndent(debug, "", "  ")
	if err != nil {
		log.Fatal("Error happened:", err.Error())
	}

	log.Println(string(pretty))

	spr, err := node.CodexSpr()
	if err != nil {
		log.Fatal("Error happened:", err.Error())
	}

	log.Println("Codex SPR:", spr)

	peerId, err := node.CodexPeerId()
	if err != nil {
		log.Fatal("Error happened:", err.Error())
	}

	log.Println("Codex Peer Id:", peerId)

	err = node.CodexLogLevel(Trace)
	if err != nil {
		log.Fatal("Error happened:", err.Error())
	}

	log.Println("Codex Log Level set to TRACE")

	sessionId, err := node.CodexUploadInit(&CodexUploadOptions{filepath: "hello.txt"})
	if err != nil {
		log.Fatal("Error happened:", err.Error())
	}
	log.Println("Codex Upload Init sessionId:", sessionId)

	err = node.CodexUploadChunk(sessionId, []byte("Hello "))
	if err != nil {
		log.Fatal("Error happened:", err.Error())
	}

	err = node.CodexUploadChunk(sessionId, []byte("World!"))
	if err != nil {
		log.Fatal("Error happened:", err.Error())
	}

	cid, err := node.CodexUploadFinalize(sessionId)
	if err != nil {
		log.Fatal("Error happened:", err.Error())
	}

	log.Println("Codex Upload Finalized, cid:", cid)

	buf := bytes.NewBuffer([]byte("Hello World!"))
	cid, err = node.CodexUploadReader(CodexUploadOptions{filepath: "hello.txt", onProgress: func(read, total int, percent float64, err error) {
		if err != nil {
			log.Fatalf("Error happened during upload: %v\n", err)
		}

		log.Printf("Uploaded %d bytes, total %d bytes (%.2f%%)\n", read, total, percent)
	}}, buf)
	if err != nil {
		log.Fatal("Error happened:", err.Error())
	}

	log.Println("Codex Upload Finalized from reader, cid:", cid)

	current, err := os.Getwd()
	if err != nil {
		log.Fatal("Error happened:", err.Error())
	}
	// Choose a big file to see the progress logs
	filepath := path.Join(current, "examples", "golang", "hello.txt")
	//filepath := path.Join(current, "examples", "golang", "discord-0.0.109.deb")

	options := CodexUploadOptions{filepath: filepath, onProgress: func(read, total int, percent float64, err error) {
		if err != nil {
			log.Fatalf("Error happened during upload: %v\n", err)
		}

		log.Printf("Uploaded %d bytes, total %d bytes (%.2f%%)\n", read, total, percent)
	}}

	cid, err = node.CodexUploadFile(options)

	if err != nil {
		log.Fatal("Error happened:", err.Error())
	}

	log.Println("Codex Upload File finalized, cid: .", cid)

	f, err := os.Create("hello.loaded.txt")
	if err != nil {
		log.Fatal(err)
	}
	defer f.Close()

	if err := node.CodexDownloadStream(cid,
		CodexDownloadStreamOptions{writer: f, filepath: "hello.reloaded.txt",
			onProgress: func(read, total int, percent float64, err error) {
				log.Println("Downloaded", read, "bytes. Total:", total, "bytes (", percent, "%)")
			},
		}); err != nil {
		log.Fatal("Error happened:", err.Error())
	}

	log.Println("Codex Download finished.")

	// log.Println("Codex Download Init starting... attempt", i+1)

	if err := node.CodexDownloadInit(cid, CodexDownloadInitOptions{local: true}); err != nil {
		log.Fatal("Error happened:", err.Error())
	}

	log.Println("Codex Download Init finished.")

	// log.Println("Codex Download Chunk starting... attempt", i+1)

	chunk, err := node.CodexDownloadChunk(cid)
	if err != nil {
		log.Fatal("Error happened:", err.Error())
	}

	log.Println("Codex Download Chunk finished. Size:", len(chunk))

	manifest, err := node.CodexDownloadManifest(cid)
	if err != nil {
		log.Fatal("Error happened:", err.Error())
	}

	log.Println("Manifest content:", manifest)

	manifests, err := node.CodexStorageList()
	if err != nil {
		log.Fatal("Error happened:", err.Error())
	}

	log.Println("Storage List content:", manifests)

	manifest, err = node.CodexStorageFetch(cid)
	if err != nil {
		log.Fatal("Error happened:", err.Error())
	}

	log.Println("Storage Fetch content:", manifest)

	space, err := node.CodexStorageSpace()
	if err != nil {
		log.Fatal("Error happened:", err.Error())
	}

	log.Println("Storage Space content:", space)

	if err := node.CodexStorageDelete(cid); err != nil {
		log.Fatal("Error happened:", err.Error())
	}

	log.Println("Storage Delete finished.")
	// }

	// err = node.CodexConnect(peerId, []string{})
	// if err != nil {
	// 	log.Fatal("Error happened:", err.Error())
	// }

	// log.Println("Codex connecting to self...")

	// val, err := node.CodexPeerDebug(peerId)
	// if err != nil {
	// 	log.Fatal("Error happened:", err.Error())
	// }

	// log.Println("Codex debugging self...", val)

	// Wait for a SIGINT or SIGTERM signal
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, syscall.SIGINT, syscall.SIGTERM)
	<-ch

	log.Println("Stopping the node...")

	err = node.CodexStop()

	if err != nil {
		log.Fatal("Error happened:", err.Error())
	}

	log.Println("Codex stopped...")

	log.Println("Destroying the node...")

	err = node.CodexDestroy()
	if err != nil {
		log.Fatal("Error happened:", err.Error())
	}
}
