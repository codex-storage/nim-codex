#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <unistd.h>
#include "../../library/libstorage.h"

// We need 250 as max retries mainly for the start function in CI.
// Other functions should be not need that many retries.
#define MAX_RETRIES 250

typedef struct
{
    int ret;
    char *msg;
    char *chunk;
    size_t len;
} Resp;

static Resp *alloc_resp(void)
{
    Resp *r = (Resp *)calloc(1, sizeof(Resp));
    r->msg = NULL;
    r->chunk = NULL;
    r->ret = -1;
    return r;
}

static void free_resp(Resp *r)
{
    if (!r)
    {
        return;
    }

    if (r->msg)
    {
        free(r->msg);
    }

    if (r->chunk)
    {
        free(r->chunk);
    }

    free(r);
}

static int get_ret(Resp *r)
{
    if (!r)
    {
        return RET_ERR;
    }

    return r->ret;
}

// wait_resp waits until the async response is ready or max retries is reached.
// The resp is initially set to -1, to any code (RET_OK, RET_ERR, RET_PROGRESS) will
// indicate that the response is ready to be consumed.
static void wait_resp(Resp *r)
{
    int retries = 0;

    while (get_ret(r) == -1 && retries < MAX_RETRIES)
    {
        usleep(1000 * 100); // 100 ms
        retries++;
    }
}

// is_resp_ok checks if the async response indicates success.
// It will wait first for the response to be ready.
// Then it will copy the message or chunk to res if provided.
static int is_resp_ok(Resp *r, char **res)
{
    if (!r)
    {
        return RET_ERR;
    }

    wait_resp(r);

    int ret = (r->ret == RET_OK) ? RET_OK : RET_ERR;

    // If a response pointer is provided, it’s safe to initialize it to NULL.
    if (res)
    {
        *res = NULL;
    }

    // If the response contains a chunk (for a download or an upload with RET_PROGRESS),
    // the response will be in chunk.
    // Otherwise, the response will be in msg.
    if (res && r->chunk)
    {
        *res = strdup(r->chunk);
    }
    else if (res && r->msg)
    {
        *res = strdup(r->msg);
    }

    free_resp(r);

    return ret;
}

// callback is the function that will be called by the storage library
// when an async operation is completed or has progress to report.
// - ret is the return code of the callback
// - msg is the data returned by the callback: it can be a string or a chunk
// - len is the size of that data
// - userData is the bridge between the caller and the lib.
//   The caller passes this userData to the library.
//   When the library invokes the callback, it passes the same userData back. The callback
//   then fills it with the received information (return code, message). Once the callback
//   has completed, the caller can read the populated userData.
static void callback(int ret, const char *msg, size_t len, void *userData)
{
    Resp *r = (Resp *)userData;

    // This means that the caller did not provide a valid userData pointer.
    // In that case, we have nothing to do but return.
    if (!r)
    {
        return;
    }

    // Assign the return code to the response structure.
    r->ret = ret;

    // If the reponse already has a message, just free it first.
    if (r->msg)
    {
        free(r->msg);
        r->msg = NULL;
        r->len = 0;
    }

    // For a RET_PROGRESS with chunk, copy the chunk data directly.
    // This is used for upload/download chunk progress.
    if (ret == RET_PROGRESS && msg && len > 0 && r->chunk)
    {
        memcpy(r->chunk, msg, len);
        r->len = len;
    }

    // For other cases, copy the message data.
    if (msg && len > 0)
    {
        // Allocate memory for the message plus null terminator.
        r->msg = (char *)malloc(len + 1);

        // Just in case malloc fails.
        if (!r->msg)
        {
            r->len = 0;
            return;
        }

        memcpy(r->msg, msg, len);

        // Null terminate is needed here otherwise
        // the msg will contains non valid string like "0� :g"
        r->msg[len] = '\0';

        r->len = len;
    }
    else
    {
        r->msg = NULL;
        r->len = 0;
    }
}

static int read_file(const char *filepath, char **res)
{
    FILE *file;
    char c;
    // Just read first 100 bytes for the test
    char content[100];

    file = fopen(filepath, "r");

    if (file == NULL)
    {
        return RET_ERR;
    }

    fgets(content, 100, file);

    *res = strdup(content);

    fclose(file);

    return RET_OK;
}

int setup(void **storage_ctx)
{
    // Initialize Nim runtime
    extern void libstorageNimMain(void);
    libstorageNimMain();

    Resp *r = alloc_resp();
    const char *cfg = "{\"log-level\":\"WARN\",\"data-dir\":\"./data-dir\"}";
    void *ctx = storage_new(cfg, (StorageCallback)callback, r);

    if (!ctx)
    {
        free_resp(r);
        return RET_ERR;
    }

    wait_resp(r);

    if (r->ret != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    (*storage_ctx) = ctx;

    free_resp(r);

    return RET_OK;
}

int start(void *storage_ctx)
{
    Resp *r = alloc_resp();

    if (storage_start(storage_ctx, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    return is_resp_ok(r, NULL);
}

int cleanup(void *storage_ctx)
{
    Resp *r = alloc_resp();

    // Stop node
    if (storage_stop(storage_ctx, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    if (is_resp_ok(r, NULL) != RET_OK)
    {
        return RET_ERR;
    }

    r = alloc_resp();

    // Close node
    if (storage_close(storage_ctx, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    if (is_resp_ok(r, NULL) != RET_OK)
    {
        return RET_ERR;
    }

    r = alloc_resp();

    // Destroy node
    // No need to wait here as storage_destroy is synchronous
    if (storage_destroy(storage_ctx, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    free_resp(r);

    return RET_OK;
}

int check_version(void *storage_ctx)
{
    char *res = NULL;

    Resp *r = alloc_resp();

    // No need to wait here as storage_version is synchronous
    if (storage_version(storage_ctx, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    free_resp(r);

    return RET_OK;
}

int check_repo(void *storage_ctx)
{
    Resp *r = alloc_resp();
    char *res = NULL;

    if (storage_repo(storage_ctx, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    int ret = is_resp_ok(r, &res);

    if (strcmp(res, "./data-dir") != 0)
    {
        printf("repo mismatch: %s\n", res);
        ret = RET_ERR;
    }

    free(res);

    return ret;
}

int check_debug(void *storage_ctx)
{
    Resp *r = alloc_resp();
    char *res = NULL;

    if (storage_debug(storage_ctx, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    int ret = is_resp_ok(r, &res);

    // Simple check to ensure the response contains spr
    if (strstr(res, "spr") == NULL)
    {
        fprintf(stderr, "debug content mismatch, res:%s\n", res);
        ret = RET_ERR;
    }

    free(res);

    return ret;
}

int check_spr(void *storage_ctx)
{
    Resp *r = alloc_resp();
    char *res = NULL;

    if (storage_spr(storage_ctx, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    int ret = is_resp_ok(r, &res);

    if (strstr(res, "spr") == NULL)
    {
        fprintf(stderr, "spr content mismatch, res:%s\n", res);
        ret = RET_ERR;
    }

    free(res);

    return ret;
}

int check_peer_id(void *storage_ctx)
{
    Resp *r = alloc_resp();
    char *res = NULL;

    if (storage_peer_id(storage_ctx, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    return is_resp_ok(r, &res);
}

int update_log_level(void *storage_ctx, const char *log_level)
{
    char *res = NULL;

    Resp *r = alloc_resp();

    if (storage_log_level(storage_ctx, log_level, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    return is_resp_ok(r, NULL);
}

int check_upload_chunk(void *storage_ctx, const char *filepath)
{
    Resp *r = alloc_resp();
    char *res = NULL;
    char *session_id = NULL;
    const char *payload = "hello world";
    size_t chunk_size = strlen(payload);

    if (storage_upload_init(storage_ctx, filepath, chunk_size, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    if (is_resp_ok(r, &session_id) != RET_OK)
    {
        return RET_ERR;
    }

    uint8_t *chunk = malloc(chunk_size);
    if (!chunk)
    {
        free(session_id);
        return RET_ERR;
    }
    memcpy(chunk, payload, chunk_size);

    r = alloc_resp();

    if (storage_upload_chunk(storage_ctx, session_id, chunk, chunk_size, (StorageCallback)callback, r) != RET_OK)
    {
        free(session_id);
        free_resp(r);
        free(chunk);
        return RET_ERR;
    }

    if (is_resp_ok(r, NULL) != RET_OK)
    {
        free(session_id);
        free(chunk);
        return RET_ERR;
    }

    free(chunk);
    r = alloc_resp();

    if (storage_upload_finalize(storage_ctx, session_id, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        free(session_id);
        return RET_ERR;
    }

    free(session_id);

    int ret = is_resp_ok(r, &res);

    if (res == NULL || strlen(res) == 0)
    {
        fprintf(stderr, "CID is missing\n");
        ret = RET_ERR;
    }

    free(res);

    return ret;
}

int upload_cancel(void *storage_ctx)
{
    Resp *r = alloc_resp();
    char *session_id = NULL;
    size_t chunk_size = 64 * 1024;

    if (storage_upload_init(storage_ctx, "hello.txt", chunk_size, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    if (is_resp_ok(r, &session_id) != RET_OK)
    {
        return RET_ERR;
    }

    r = alloc_resp();

    if (storage_upload_cancel(storage_ctx, session_id, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        free(session_id);
        return RET_ERR;
    }

    free(session_id);

    return is_resp_ok(r, NULL);
}

int check_upload_file(void *storage_ctx, const char *filepath, char **res)
{
    Resp *r = alloc_resp();
    char *session_id = NULL;
    size_t chunk_size = 64 * 1024;

    if (storage_upload_init(storage_ctx, filepath, chunk_size, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    if (is_resp_ok(r, &session_id) != RET_OK)
    {
        return RET_ERR;
    }

    r = alloc_resp();

    if (storage_upload_file(storage_ctx, session_id, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        free(session_id);
        return RET_ERR;
    }

    free(session_id);

    int ret = is_resp_ok(r, res);

    if (res == NULL || strlen(*res) == 0)
    {
        fprintf(stderr, "CID is missing\n");
        return RET_ERR;
    }

    return ret;
}

int check_download_stream(void *storage_ctx, const char *cid, const char *filepath)
{
    Resp *r = alloc_resp();
    char *res = NULL;
    size_t chunk_size = 64 * 1024;
    bool local = true;

    if (storage_download_init(storage_ctx, cid, chunk_size, local, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    if (is_resp_ok(r, NULL) != RET_OK)
    {
        return RET_ERR;
    }

    r = alloc_resp();
    r->chunk = malloc(chunk_size + 1);

    if (storage_download_stream(storage_ctx, cid, chunk_size, local, filepath, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    int ret = is_resp_ok(r, &res);

    if (strncmp(res, "Hello World!", strlen("Hello World!")) != 0)
    {
        fprintf(stderr, "downloaded content mismatch, res:%s\n", res);
        ret = RET_ERR;
    }

    if (read_file("downloaded_hello.txt", &res) != RET_OK)
    {
        fprintf(stderr, "read downloaded file failed\n");
        ret = RET_ERR;
    }

    if (strncmp(res, "Hello World!", strlen("Hello World!")) != 0)
    {
        fprintf(stderr, "downloaded content mismatch, res:%s\n", res);
        ret = RET_ERR;
    }

    free(res);

    return ret;
}

int check_download_chunk(void *storage_ctx, const char *cid)
{
    Resp *r = alloc_resp();
    char *res = NULL;
    size_t chunk_size = 64 * 1024;
    bool local = true;

    if (storage_download_init(storage_ctx, cid, chunk_size, local, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    if (is_resp_ok(r, NULL) != RET_OK)
    {
        return RET_ERR;
    }

    r = alloc_resp();
    r->chunk = malloc(chunk_size + 1);

    if (storage_download_chunk(storage_ctx, cid, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    int ret = is_resp_ok(r, &res);

    if (strncmp(res, "Hello World!", strlen("Hello World!")) != 0)
    {
        fprintf(stderr, "downloaded chunk content mismatch, res:%s\n", res);
        ret = RET_ERR;
    }

    free(res);

    return ret;
}

int check_download_cancel(void *storage_ctx, const char *cid)
{
    Resp *r = alloc_resp();

    if (storage_download_cancel(storage_ctx, cid, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    return is_resp_ok(r, NULL);
}

int check_download_manifest(void *storage_ctx, const char *cid)
{
    Resp *r = alloc_resp();
    char *res = NULL;

    if (storage_download_manifest(storage_ctx, cid, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    int ret = is_resp_ok(r, &res);

    const char *expected_manifest = "{\"treeCid\":\"zDzSvJTf8JYwvysKPmG7BtzpbiAHfuwFMRphxm4hdvnMJ4XPJjKX\",\"datasetSize\":12,\"blockSize\":65536,\"filename\":\"hello_world.txt\",\"mimetype\":\"text/plain\",\"protected\":false}";

    if (strncmp(res, expected_manifest, strlen(expected_manifest)) != 0)
    {
        fprintf(stderr, "downloaded manifest content mismatch, res:%s\n", res);
        ret = RET_ERR;
    }

    free(res);

    return ret;
}

int check_list(void *storage_ctx)
{
    Resp *r = alloc_resp();
    char *res = NULL;

    if (storage_list(storage_ctx, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    int ret = is_resp_ok(r, &res);

    const char *expected_manifest = "{\"treeCid\":\"zDzSvJTf8JYwvysKPmG7BtzpbiAHfuwFMRphxm4hdvnMJ4XPJjKX\",\"datasetSize\":12,\"blockSize\":65536,\"filename\":\"hello_world.txt\",\"mimetype\":\"text/plain\",\"protected\":false}";

    if (strstr(res, expected_manifest) == NULL)
    {
        fprintf(stderr, "downloaded manifest content mismatch, res:%s\n", res);
        ret = RET_ERR;
    }

    free(res);

    return ret;
}

int check_space(void *storage_ctx)
{
    Resp *r = alloc_resp();
    char *res = NULL;

    if (storage_space(storage_ctx, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    int ret = is_resp_ok(r, &res);

    // Simple check to ensure the response contains totalBlocks
    if (strstr(res, "totalBlocks") == NULL)
    {
        fprintf(stderr, "list content mismatch, res:%s\n", res);
        ret = RET_ERR;
    }

    free(res);

    return ret;
}

int check_exists(void *storage_ctx, const char *cid, bool expected)
{
    Resp *r = alloc_resp();
    char *res = NULL;

    if (storage_exists(storage_ctx, cid, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    int ret = is_resp_ok(r, &res);

    if (expected)
    {
        if (strcmp(res, "true") != 0)
        {
            fprintf(stderr, "exists content mismatch, res:%s\n", res);
            ret = RET_ERR;
        }
    }
    else
    {
        if (strcmp(res, "false") != 0)
        {
            fprintf(stderr, "exists content mismatch, res:%s\n", res);
            ret = RET_ERR;
        }
    }

    free(res);

    return ret;
}

int check_delete(void *storage_ctx, const char *cid)
{
    Resp *r = alloc_resp();

    if (storage_delete(storage_ctx, cid, (StorageCallback)callback, r) != RET_OK)
    {
        free_resp(r);
        return RET_ERR;
    }

    return is_resp_ok(r, NULL);
}

// TODO: implement check_fetch
// It is a bit complicated because it requires two nodes
// connected together to fetch from peers.
// A good idea would be to use connect function using addresses.
// This test will be quite important when the block engine is re-implemented.
int check_fetch(void *storage_ctx, const char *cid)
{
    return RET_OK;
}

int main(void)
{
    void *storage_ctx = NULL;
    char *res = NULL;
    char *cid = NULL;

    if (setup(&storage_ctx) != RET_OK)
    {
        fprintf(stderr, "setup failed\n");
        return RET_ERR;
    }

    if (check_version(storage_ctx) != RET_OK)
    {
        fprintf(stderr, "check version failed\n");
        return RET_ERR;
    }

    if (start(storage_ctx) != RET_OK)
    {
        fprintf(stderr, "start failed\n");
        return RET_ERR;
    }

    if (check_repo(storage_ctx) != RET_OK)
    {
        fprintf(stderr, "check repo failed\n");
        return RET_ERR;
    }

    if (check_debug(storage_ctx) != RET_OK)
    {
        fprintf(stderr, "check debug failed\n");
        return RET_ERR;
    }

    if (check_spr(storage_ctx) != RET_OK)
    {
        fprintf(stderr, "check spr failed\n");
        return RET_ERR;
    }

    if (check_peer_id(storage_ctx) != RET_OK)
    {
        fprintf(stderr, "check peer_id failed\n");
        return RET_ERR;
    }

    if (check_upload_chunk(storage_ctx, "hello_world.txt") != RET_OK)
    {
        fprintf(stderr, "upload chunk failed\n");
        return RET_ERR;
    }

    if (upload_cancel(storage_ctx) != RET_OK)
    {
        fprintf(stderr, "upload cancel failed\n");
        return RET_ERR;
    }

    char *path = realpath("hello_world.txt", NULL);

    if (!path)
    {
        fprintf(stderr, "realpath failed\n");
        return RET_ERR;
    }

    if (check_upload_file(storage_ctx, path, &cid) != RET_OK)
    {
        fprintf(stderr, "upload file failed\n");
        free(path);
        return RET_ERR;
    }

    free(path);

    if (check_download_stream(storage_ctx, cid, "downloaded_hello.txt") != RET_OK)
    {
        fprintf(stderr, "download stream failed\n");
        free(cid);
        return RET_ERR;
    }

    if (check_download_chunk(storage_ctx, cid) != RET_OK)
    {
        fprintf(stderr, "download chunk failed\n");
        free(cid);
        return RET_ERR;
    }

    if (check_download_cancel(storage_ctx, cid) != RET_OK)
    {
        fprintf(stderr, "download cancel failed\n");
        free(cid);
        return RET_ERR;
    }

    if (check_download_manifest(storage_ctx, cid) != RET_OK)
    {
        fprintf(stderr, "download manifest failed\n");
        free(cid);
        return RET_ERR;
    }

    if (check_list(storage_ctx) != RET_OK)
    {
        fprintf(stderr, "list failed\n");
        free(cid);
        return RET_ERR;
    }

    if (check_space(storage_ctx) != RET_OK)
    {
        fprintf(stderr, "space failed\n");
        free(cid);
        return RET_ERR;
    }

    if (check_exists(storage_ctx, cid, true) != RET_OK)
    {
        fprintf(stderr, "exists failed\n");
        free(cid);
        return RET_ERR;
    }

    if (check_delete(storage_ctx, cid) != RET_OK)
    {
        fprintf(stderr, "delete failed\n");
        free(cid);
        return RET_ERR;
    }

    if (check_exists(storage_ctx, cid, false) != RET_OK)
    {
        fprintf(stderr, "exists failed\n");
        free(cid);
        return RET_ERR;
    }

    free(cid);

    if (update_log_level(storage_ctx, "INFO") != RET_OK)
    {
        fprintf(stderr, "update log level failed\n");
        return RET_ERR;
    }

    if (cleanup(storage_ctx) != RET_OK)
    {
        fprintf(stderr, "cleanup failed\n");
        return RET_ERR;
    }

    return RET_OK;
}