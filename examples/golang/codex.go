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

	static int cGoCodexUploadSubscribe(void* codexCtx, char* sessionId, void* resp) {
		return codex_upload_subscribe(codexCtx, sessionId, (CodexCallback) callback, resp);
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
	Address *string `json:"address"` // Use pointer for nullable
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

type OnProgressFunc func(read, total int, percent float64)

type CodexUploadOptions struct {
	filepath   string
	chunkSize  int
	onProgress OnProgressFunc
}

type bridgeCtx struct {
	wg     *sync.WaitGroup
	h      cgo.Handle
	resp   unsafe.Pointer
	result string
	err    error

	// Callback used for upload and download
	onProgress func(read int)
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

	result := b.result
	err := b.err

	b.free()

	return result, err
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
			if v.onProgress != nil {
				v.onProgress(int(C.int(len)))
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

	if C.cGoCodexVersion(self.ctx, bridge.resp) != C.RET_OK {
		return "", bridge.CallError("cGoCodexVersion")
	}

	return bridge.wait()
}

func (self CodexNode) CodexRevision() (string, error) {
	bridge := newBridgeCtx()

	if C.cGoCodexRevision(self.ctx, bridge.resp) != C.RET_OK {
		return "", bridge.CallError("cGoCodexRevision")
	}

	return bridge.wait()
}

func (self CodexNode) CodexRepo() (string, error) {
	bridge := newBridgeCtx()

	if C.cGoCodexRepo(self.ctx, bridge.resp) != C.RET_OK {
		return "", bridge.CallError("cGoCodexRepo")
	}

	return bridge.wait()
}

func (self CodexNode) CodexDebug() (CodexDebugInfo, error) {
	var info CodexDebugInfo

	bridge := newBridgeCtx()

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

	if C.cGoCodexSpr(self.ctx, bridge.resp) != C.RET_OK {
		return "", bridge.CallError("cGoCodexSpr")
	}

	return bridge.wait()
}

func (self CodexNode) CodexPeerId() (string, error) {
	bridge := newBridgeCtx()

	if C.cGoCodexPeerId(self.ctx, bridge.resp) != C.RET_OK {
		return "", bridge.CallError("cGoCodexPeerId")
	}

	return bridge.wait()
}

func (self CodexNode) CodexLogLevel(logLevel LogLevel) error {
	bridge := newBridgeCtx()

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

	var cFilename = C.CString(options.filepath)
	defer C.free(unsafe.Pointer(cFilename))

	if options.chunkSize == 0 {
		options.chunkSize = defaultBlockSize
	}

	var cChunkSize = C.size_t(options.chunkSize)

	if C.cGoCodexUploadInit(self.ctx, cFilename, cChunkSize, bridge.resp) != C.RET_OK {
		return "", bridge.CallError("cGoCodexUploadInit")
	}

	return bridge.wait()
}

func (self CodexNode) CodexUploadChunk(sessionId string, chunk []byte) error {
	bridge := newBridgeCtx()

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

	var cSessionId = C.CString(sessionId)
	defer C.free(unsafe.Pointer(cSessionId))

	if C.cGoCodexUploadFinalize(self.ctx, cSessionId, bridge.resp) != C.RET_OK {
		return "", bridge.CallError("cGoCodexUploadFinalize")
	}

	return bridge.wait()
}

func (self CodexNode) CodexUploadCancel(sessionId string) error {
	bridge := newBridgeCtx()

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

	if options.onProgress != nil {
		size := getReaderSize(r)
		total := 0

		if size > 0 {
			onProgress := func(read int) {
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

				options.onProgress(read, int(size), percent)
			}

			if err := self.CodexUploadSubscribe(sessionId, onProgress); err != nil {
				if err := self.CodexUploadCancel(sessionId); err != nil {
					log.Println("Error cancelling upload after subscribe failure:", err)
				}

				return "", err
			}
		}
	}

	if options.chunkSize == 0 {
		options.chunkSize = defaultBlockSize
	}

	buf := make([]byte, options.chunkSize)
	for {
		n, err := r.Read(buf)
		if n > 0 {
			if err := self.CodexUploadChunk(sessionId, buf[:n]); err != nil {
				return "", err
			}
		}

		if err == io.EOF {
			break
		}

		if err != nil {
			self.CodexUploadCancel(sessionId)

			return "", err
		}

		if n == 0 {
			break
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

	if options.onProgress != nil {
		stat, err := os.Stat(options.filepath)
		if err != nil {
			return "", err
		}

		size := stat.Size()
		total := 0

		if size > 0 {
			bridge.onProgress = func(read int) {
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

				options.onProgress(read, int(size), percent)
			}
		}
	}

	var cFilePath = C.CString(options.filepath)
	defer C.free(unsafe.Pointer(cFilePath))

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

func (self CodexNode) CodexUploadSubscribe(sessionId string, onProgress func(read int)) error {
	bridge := newBridgeCtx()

	bridge.onProgress = onProgress

	var cSessionId = C.CString(sessionId)
	defer C.free(unsafe.Pointer(cSessionId))

	log.Println("Subscribing to upload progress...")

	if C.cGoCodexUploadSubscribe(self.ctx, cSessionId, bridge.resp) != C.RET_OK {
		return bridge.CallError("cGoCodexUploadSubscribe")
	}

	go func() {
		if _, err := bridge.wait(); err != nil {
			log.Println("Error in CodexUploadSubscribe:", err)
		}
	}()

	return nil
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
	defer bridge.free()

	if C.cGoCodexStop(self.ctx, bridge.resp) != C.RET_OK {
		return bridge.CallError("cGoCodexStop")
	}

	_, err := bridge.wait()
	return err
}

func (self CodexNode) CodexDestroy() error {
	bridge := newBridgeCtx()
	defer bridge.free()

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
	cid, err = node.CodexUploadReader(CodexUploadOptions{filepath: "hello.txt", onProgress: func(read, total int, percent float64) {
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

	options := CodexUploadOptions{filepath: filepath, onProgress: func(read, total int, percent float64) {
		log.Printf("Uploaded %d bytes, total %d bytes (%.2f%%)\n", read, total, percent)
	}}

	cid, err = node.CodexUploadFile(options)

	if err != nil {
		log.Fatal("Error happened:", err.Error())
	}

	log.Println("Codex Upload File finalized, cid: .", cid)

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
