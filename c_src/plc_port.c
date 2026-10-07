#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
#include <fcntl.h>
#include <io.h>
#else
#include <dlfcn.h>
#endif

typedef void *s7_client;
typedef s7_client (*create_fn)(void);
typedef int (*connect_fn)(s7_client, const char *, int, int);
typedef int (*read_fn)(s7_client, int, int, int, void *);
typedef int (*write_fn)(s7_client, int, int, int, void *);
typedef int (*disconnect_fn)(s7_client);
typedef void (*destroy_fn)(s7_client *);

struct snap7_api {
    create_fn create;
    connect_fn connect;
    read_fn read;
    write_fn write;
    disconnect_fn disconnect;
    destroy_fn destroy;
};

struct mock_write {
    uint32_t db;
    uint32_t offset;
    uint32_t size;
    unsigned char *data;
    struct mock_write *next;
};

static int mock_store(struct mock_write ***tail, uint32_t db, uint32_t offset,
                      uint32_t size, const unsigned char *data) {
    struct mock_write *entry = malloc(sizeof(*entry));
    if (entry == NULL) return 0;
    entry->data = malloc(size);
    if (entry->data == NULL) {
        free(entry);
        return 0;
    }
    memcpy(entry->data, data, size);
    entry->db = db;
    entry->offset = offset;
    entry->size = size;
    entry->next = NULL;
    **tail = entry;
    *tail = &entry->next;
    return 1;
}

static void mock_read(struct mock_write *writes, uint32_t db, uint32_t offset,
                      uint32_t size, unsigned char *data) {
    for (uint32_t index = 0; index < size; index++)
        data[index] = (unsigned char)(db + offset + index);
    for (struct mock_write *entry = writes; entry != NULL; entry = entry->next) {
        if (entry->db != db) continue;
        uint64_t start = offset > entry->offset ? offset : entry->offset;
        uint64_t end = (uint64_t)offset + size < (uint64_t)entry->offset + entry->size
                           ? (uint64_t)offset + size : (uint64_t)entry->offset + entry->size;
        if (start < end)
            memcpy(data + (start - offset), entry->data + (start - entry->offset), end - start);
    }
}

static void mock_free(struct mock_write *writes) {
    while (writes != NULL) {
        struct mock_write *next = writes->next;
        free(writes->data);
        free(writes);
        writes = next;
    }
}

/* 按网络字节序读取四字节无符号整数。 */
static uint32_t get32(const unsigned char *data) {
    return ((uint32_t)data[0] << 24) | ((uint32_t)data[1] << 16) |
           ((uint32_t)data[2] << 8) | data[3];
}

/* 按网络字节序写入四字节整数。 */
static void put32(unsigned char *data, uint32_t value) {
    data[0] = (unsigned char)(value >> 24);
    data[1] = (unsigned char)(value >> 16);
    data[2] = (unsigned char)(value >> 8);
    data[3] = (unsigned char)value;
}

/* 从标准输入读取完整帧；遇到 EOF 或读取失败时返回 0。 */
static int read_exact(unsigned char *data, size_t size) {
    size_t received = 0;
    while (received < size) {
        size_t count = fread(data + received, 1, size - received, stdin);
        if (count == 0) return 0;
        received += count;
    }
    return 1;
}

/* 将指定长度的字节写到标准输出。 */
static int write_exact(const unsigned char *data, size_t size) {
    return fwrite(data, 1, size, stdout) == size;
}

/* 回复 Elixir：四字节帧长、请求 id、状态和数据。 */
static int send_reply(uint32_t id, int status, const unsigned char *data, uint32_t size) {
    unsigned char header[9];
    put32(header, size + 5);
    put32(header + 4, id);
    header[8] = (unsigned char)status;
    return write_exact(header, sizeof(header)) && write_exact(data, size) && fflush(stdout) == 0;
}

/* 运行时加载 Snap7 符号，避免编译时依赖其头文件。 */
static int load_snap7(struct snap7_api *api) {
#ifdef _WIN32
    HMODULE library = LoadLibraryA("snap7.dll");
    if (library == NULL) return 0;
#define SYMBOL(name) GetProcAddress(library, name)
#else
    const char *path = getenv("PLC_SNAP7_LIBRARY");
    void *library = dlopen(path == NULL ? "libsnap7.so" : path, RTLD_NOW);
    if (library == NULL) return 0;
#define SYMBOL(name) dlsym(library, name)
#endif
    api->create = (create_fn)SYMBOL("Cli_Create");
    api->connect = (connect_fn)SYMBOL("Cli_ConnectTo");
    api->read = (read_fn)SYMBOL("Cli_DBRead");
    api->write = (write_fn)SYMBOL("Cli_DBWrite");
    api->disconnect = (disconnect_fn)SYMBOL("Cli_Disconnect");
    api->destroy = (destroy_fn)SYMBOL("Cli_Destroy");
    return api->create && api->connect && api->read && api->write && api->disconnect && api->destroy;
}

/* 循环处理 Port 请求，复用连接读取 DB，并返回数据或错误码。 */
int main(int argc, char **argv) {
    if (argc != 4) return 2;
#ifdef _WIN32
    _setmode(_fileno(stdin), _O_BINARY);
    _setmode(_fileno(stdout), _O_BINARY);
#endif
    const char *host = argv[1];
    int rack = atoi(argv[2]);
    int slot = atoi(argv[3]);
    int mock = strcmp(host, "--mock") == 0;
    struct snap7_api api = {0};
    s7_client client = NULL;
    int connected = 0;
    int available = mock || load_snap7(&api);
    struct mock_write *writes = NULL;
    struct mock_write **write_tail = &writes;
    int mock_connected = 1;
    int mock_timeout_next = 0;

    for (;;) {
        unsigned char header[4];
        if (!read_exact(header, sizeof(header))) break;
        uint32_t frame_size = get32(header);
        if (frame_size < 15 || frame_size > 65551) break;
        unsigned char *request = malloc(frame_size);
        if (request == NULL || !read_exact(request, frame_size)) break;
        uint32_t id = get32(request);
        uint32_t db = ((uint32_t)request[5] << 8) | request[6];
        uint32_t offset = get32(request + 7);
        uint32_t size = get32(request + 11);
        if ((request[4] != 1 && request[4] != 2 && !(mock && request[4] == 3)) ||
            size == 0 || size > 65536 || offset > INT32_MAX ||
            (request[4] == 2 && frame_size != 15 + size) ||
            (request[4] != 2 && frame_size != 15)) break;

        unsigned char *data = malloc(size);
        if (data == NULL) break;
        int error = 0;
        if (!available) {
            error = -1000;
        } else if (mock && request[4] == 3) {
            if (db == 1) mock_connected = 0;
            else if (db == 2) mock_connected = 1;
            else if (db == 3) mock_timeout_next = 1;
            else error = -1003;
        } else if (mock && mock_timeout_next) {
            mock_timeout_next = 0;
            free(data);
            free(request);
            continue;
        } else if (mock && !mock_connected) {
            error = -1002;
        } else if (mock && request[4] == 1) {
            mock_read(writes, db, offset, size, data);
        } else if (mock) {
            if (!mock_store(&write_tail, db, offset, size, request + 15)) error = -1004;
        } else {
            if (client == NULL) client = api.create();
            if (client == NULL) error = -1001;
            if (error == 0 && !connected) {
                error = api.connect(client, host, rack, slot);
                connected = error == 0;
            }
            if (error == 0) {
                error = request[4] == 1 ? api.read(client, (int)db, (int)offset, (int)size, data)
                                        : api.write(client, (int)db, (int)offset, (int)size, request + 15);
            }
            if (error != 0 && connected) {
                api.disconnect(client);
                connected = 0;
            }
        }

        int sent;
        if (error == 0) {
            sent = send_reply(id, 0, request[4] == 1 ? data : (unsigned char *)"", request[4] == 1 ? size : 0);
        } else {
            unsigned char code[4];
            put32(code, (uint32_t)error);
            sent = send_reply(id, 1, code, sizeof(code));
        }
        free(data);
        free(request);
        if (!sent) break;
    }

    if (client != NULL) {
        if (connected) api.disconnect(client);
        api.destroy(&client);
    }
    mock_free(writes);
    return 0;
}
