package main

/*
	#cgo LDFLAGS: -L../../build/ -lcodex
	#cgo LDFLAGS: -L../../ -Wl,-rpath,../../

	#include "../../library/libcodex.h"
	#include <stdio.h>
	#include <stdlib.h>

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
	} Resp;

	static void* allocResp() {
		return calloc(1, sizeof(Resp));
	}

	static void freeResp(void* resp) {
		if (resp != NULL) {
			free(resp);
		}
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

	static int getRet(void* resp) {
		if (resp == NULL) {
			return 0;
		}
		Resp* m = (Resp*) resp;
		return m->ret;
	}

	// resp must be set != NULL in case interest on retrieving data from the callback
	static void callback(int ret, char* msg, size_t len, void* resp) {
		if (resp != NULL) {
			Resp* m = (Resp*) resp;
			m->ret = ret;
			m->msg = msg;
			m->len = len;
		}
	}

	#define CODEX_CALL(call)                                                        \
	do {                                                                           \
		int ret = call;                                                              \
		if (ret != 0) {                                                              \
			printf("Failed the call to: %s. Returned code: %d\n", #call, ret);         \
			exit(1);                                                                   \
		}                                                                            \
	} while (0)

	static void* cGoCodexNew(const char* configJson, void* resp) {
		void* ret = codex_new(configJson, (CodexCallback) callback, resp);
		return ret;
	}

	static void cGoCodexVersion(void* codexCtx, void* resp) {
		CODEX_CALL(codex_version(codexCtx, (CodexCallback) callback, resp));
	}

	static void cGoCodexStart(void* codexCtx, void* resp) {
		CODEX_CALL(codex_start(codexCtx, (CodexCallback) callback, resp));
	}

	static void cGoCodexStop(void* codexCtx, void* resp) {
		CODEX_CALL(codex_stop(codexCtx, (CodexCallback) callback, resp));
	}

	static void cGoCodexDestroy(void* codexCtx, void* resp) {
		CODEX_CALL(codex_destroy(codexCtx, (CodexCallback) callback, resp));
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
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"os/signal"
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
	LogLevel                       LogLevel  `json:"log-level,omitempty"`
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

type CodexNode struct {
	ctx unsafe.Pointer
}

func CodexNew(config CodexConfig) (*CodexNode, error) {
	jsonConfig, err := json.Marshal(config)
	if err != nil {
		return nil, err
	}

	var cJsonConfig = C.CString(string(jsonConfig))
	var resp = C.allocResp()

	defer C.free(unsafe.Pointer(cJsonConfig))
	defer C.freeResp(resp)

	ctx := C.cGoCodexNew(cJsonConfig, resp)
	if C.getRet(resp) == C.RET_OK {
		return &CodexNode{ctx: ctx}, nil
	}

	errMsg := "error CodexNew: " + C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))
	return nil, errors.New(errMsg)
}

func (self *CodexNode) CodexVersion() (string, error) {
	var resp = C.allocResp()
	defer C.freeResp(resp)
	C.cGoCodexVersion(self.ctx, resp)

	if C.getRet(resp) == C.RET_OK {
		return C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp))), nil
	}

	errMsg := "error CodexStart: " + C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))
	return "", errors.New(errMsg)
}

func (self *CodexNode) CodexStart() error {
	var resp = C.allocResp()
	defer C.freeResp(resp)
	C.cGoCodexStart(self.ctx, resp)

	if C.getRet(resp) == C.RET_OK {
		return nil
	}

	errMsg := "error CodexStart: " + C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))
	return errors.New(errMsg)
}

func (self *CodexNode) CodexStop() error {
	var resp = C.allocResp()
	defer C.freeResp(resp)
	C.cGoCodexStop(self.ctx, resp)

	if C.getRet(resp) == C.RET_OK {
		return nil
	}
	errMsg := "error CodexStop: " + C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))
	return errors.New(errMsg)
}

func (self *CodexNode) CodexDestroy() error {
	var resp = C.allocResp()
	defer C.freeResp(resp)
	C.cGoCodexDestroy(self.ctx, resp)

	if C.getRet(resp) == C.RET_OK {
		return nil
	}
	errMsg := "error CodexDestroy: " + C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))
	return errors.New(errMsg)
}

//export globalEventCallback
func globalEventCallback(callerRet C.int, msg *C.char, len C.size_t, userData unsafe.Pointer) {
	// This is shared among all Golang instances

	self := CodexNode{ctx: userData}
	self.MyEventCallback(callerRet, msg, len)
}

func (self *CodexNode) MyEventCallback(callerRet C.int, msg *C.char, len C.size_t) {
	fmt.Println("Event received:", C.GoStringN(msg, C.int(len)))
}

func (self *CodexNode) CodexSetEventCallback() {
	// Notice that the events for self node are handled by the 'MyEventCallback' method
	C.cGoCodexSetEventCallback(self.ctx)
}

func main() {
	config := CodexConfig{
		LogLevel: Info,
	}

	log.Println("Creating Codex...")

	node, err := CodexNew(config)
	if err != nil {
		fmt.Println("Error happened:", err.Error())
		return
	}

	node.CodexSetEventCallback()

	version, err := node.CodexVersion()
	if err != nil {
		fmt.Println("Error happened:", err.Error())
		return
	}

	log.Println("Codex version:", version)

	log.Println("Starting Codex...")

	err = node.CodexStart()
	if err != nil {
		fmt.Println("Error happened:", err.Error())
		return
	}

	log.Println("Codex started...")

	// Wait for a SIGINT or SIGTERM signal
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, syscall.SIGINT, syscall.SIGTERM)
	<-ch

	log.Println("Stopping the node...")

	err = node.CodexStop()
	if err != nil {
		fmt.Println("Error happened:", err.Error())
		return
	}

	log.Println("Destroying the node...")

	err = node.CodexDestroy()
	if err != nil {
		fmt.Println("Error happened:", err.Error())
		return
	}
}
