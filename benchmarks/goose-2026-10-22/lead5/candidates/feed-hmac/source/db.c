/* Goose FFI adapters only: application SQL, routing and JSON live in app.goose. */
#define _POSIX_C_SOURCE 200809L
#include "net.h"
#include "json_fast.h"
#include "sqlite3.h"
#include <openssl/crypto.h>
#include <openssl/hmac.h>
#include <openssl/evp.h>
#include <openssl/core_names.h>
#include <openssl/params.h>
#include <stdint.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef struct {
    sqlite3 *raw;
    sqlite3_stmt *begin, *commit, *rollback;
    int wal_frames;
} Database;

static char *string_copy(bytes value) {
    if (value.len < 0 || value.len > 1048576) return NULL;
    char *result = malloc((size_t)value.len + 1);
    if (!result) return NULL;
    memcpy(result, value.data, (size_t)value.len);
    result[value.len] = 0;
    return result;
}

void native_env(bytes name, gs_rref output) {
    char *key = string_copy(name);
    if (!key) return;
    const char *value = getenv(key);
    if (value) gs_bld_append(output, value, (int64_t)strlen(value));
    free(key);
}

int64_t native_time_ms(void) {
    struct timespec time;
    clock_gettime(CLOCK_REALTIME, &time);
    return (int64_t)time.tv_sec * 1000 + time.tv_nsec / 1000000;
}

static int wal_hook(void *context, sqlite3 *raw, const char *name, int frames) {
    (void)raw; (void)name;
    ((Database *)context)->wal_frames = frames;
    return SQLITE_OK;
}

/* Operator memory tuning only; query results are never cached here. */
static int config_integer(const char *name, int64_t fallback, int64_t minimum,
                          int64_t maximum, int64_t *out) {
    const char *text = getenv(name);
    if (!text || !*text) { *out = fallback; return 1; }
    char *end = NULL;
    errno = 0;
    long long value = strtoll(text, &end, 10);
    if (errno || end == text || *end || value < minimum || value > maximum) {
        fprintf(stderr, "Invalid %s: expected an integer from %lld to %lld\n",
                name, (long long)minimum, (long long)maximum);
        return 0;
    }
    *out = (int64_t)value;
    return 1;
}

int64_t db_open(bytes path) {
    char *name = string_copy(path);
    Database *db = calloc(1, sizeof(*db));
    if (!name || !db) { free(name); free(db); return 0; }
    int rc = sqlite3_open_v2(name, &db->raw, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, NULL);
    free(name);
    if (rc == SQLITE_OK) {
        rc = sqlite3_exec(db->raw,
            "PRAGMA locking_mode=EXCLUSIVE; PRAGMA journal_mode=WAL;"
            "PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;"
            "PRAGMA temp_store=MEMORY; PRAGMA journal_size_limit=67108864;"
            "PRAGMA wal_autocheckpoint=0;", NULL, NULL, NULL);
    }
    if (rc == SQLITE_OK) {
        int64_t cache_kib, mmap_mib;
        if (!config_integer("GOOSE_SQLITE_CACHE_KIB", 8192, 1, 524288, &cache_kib) ||
            !config_integer("GOOSE_SQLITE_MMAP_MIB", 0, 0, 4096, &mmap_mib)) {
            rc = SQLITE_MISUSE;
        } else {
            char settings[160];
            snprintf(settings, sizeof(settings),
                     "PRAGMA cache_size=-%lld;PRAGMA mmap_size=%lld;",
                     (long long)cache_kib, (long long)(mmap_mib * INT64_C(1048576)));
            rc = sqlite3_exec(db->raw, settings, NULL, NULL, NULL);
            if (rc == SQLITE_OK)
                fprintf(stderr, "SQLite memory: cache_kib=%lld mmap_mib=%lld\n",
                        (long long)cache_kib, (long long)mmap_mib);
        }
    }
    if (rc == SQLITE_OK) rc = sqlite3_prepare_v3(db->raw, "BEGIN", -1, SQLITE_PREPARE_PERSISTENT, &db->begin, NULL);
    if (rc == SQLITE_OK) rc = sqlite3_prepare_v3(db->raw, "COMMIT", -1, SQLITE_PREPARE_PERSISTENT, &db->commit, NULL);
    if (rc == SQLITE_OK) rc = sqlite3_prepare_v3(db->raw, "ROLLBACK", -1, SQLITE_PREPARE_PERSISTENT, &db->rollback, NULL);
    if (rc != SQLITE_OK) {
        fprintf(stderr, "SQLite open/setup error (%d): %s\n", rc, sqlite3_errmsg(db->raw));
        sqlite3_finalize(db->begin); sqlite3_finalize(db->commit); sqlite3_finalize(db->rollback);
        sqlite3_close(db->raw); free(db); return 0;
    }
    sqlite3_wal_hook(db->raw, wal_hook, db);
    return (int64_t)(intptr_t)db;
}

int64_t db_prepare(int64_t handle, bytes sql) {
    Database *db = (Database *)(intptr_t)handle;
    sqlite3_stmt *stmt = NULL;
    int rc = sqlite3_prepare_v3(db->raw, (const char *)sql.data, (int)sql.len,
                              SQLITE_PREPARE_PERSISTENT, &stmt, NULL);
    if (rc != SQLITE_OK) {
        fprintf(stderr, "SQLite prepare error (%d): %s\n", rc, sqlite3_errmsg(db->raw));
        return 0;
    }
    return (int64_t)(intptr_t)stmt;
}

int32_t db_bind_int(int64_t handle, int32_t index, int64_t value) {
    return sqlite3_bind_int64((sqlite3_stmt *)(intptr_t)handle, index, value);
}

int32_t db_bind_text(int64_t handle, int32_t index, bytes value) {
    /* The Goose slice is borrowed only for this call; SQLite owns a copy. */
    return sqlite3_bind_text((sqlite3_stmt *)(intptr_t)handle, index,
                            (const char *)value.data, (int)value.len, SQLITE_TRANSIENT);
}

int32_t db_step(int64_t handle) { return sqlite3_step((sqlite3_stmt *)(intptr_t)handle); }
int32_t db_reset(int64_t handle) { return sqlite3_reset((sqlite3_stmt *)(intptr_t)handle); }
int64_t db_column_int(int64_t handle, int32_t column) {
    return sqlite3_column_int64((sqlite3_stmt *)(intptr_t)handle, column);
}

void db_column_text(int64_t handle, int32_t column, gs_rref output) {
    sqlite3_stmt *stmt = (sqlite3_stmt *)(intptr_t)handle;
    const unsigned char *text = sqlite3_column_text(stmt, column);
    int count = sqlite3_column_bytes(stmt, column);
    if (text && count) gs_bld_append(output, text, count);
}

/* SQLite owns this view through the next step/reset. Serialize it while it is
   borrowed, directly into the caller's output, without an intermediate copy. */
void db_column_json(int64_t handle, int32_t column, gs_rref output) {
    sqlite3_stmt *stmt = (sqlite3_stmt *)(intptr_t)handle;
    const unsigned char *text = sqlite3_column_text(stmt, column);
    int count = sqlite3_column_bytes(stmt, column);
    json_append_string((bytes){text, count}, output);
}

int64_t db_last_id(int64_t handle) {
    return sqlite3_last_insert_rowid(((Database *)(intptr_t)handle)->raw);
}
int32_t db_changes(int64_t handle) {
    return sqlite3_changes(((Database *)(intptr_t)handle)->raw);
}

static int transaction_step(sqlite3_stmt *stmt) {
    int rc = sqlite3_step(stmt);
    sqlite3_reset(stmt);
    return rc == SQLITE_DONE ? SQLITE_OK : rc;
}

int32_t db_begin(int64_t handle) {
    Database *db = (Database *)(intptr_t)handle;
    return sqlite3_get_autocommit(db->raw) ? transaction_step(db->begin) : SQLITE_OK;
}

int32_t db_commit(int64_t handle) {
    Database *db = (Database *)(intptr_t)handle;
    if (sqlite3_get_autocommit(db->raw)) return SQLITE_OK;
    int rc = transaction_step(db->commit);
    if (rc != SQLITE_OK) transaction_step(db->rollback);
    return rc;
}

void db_checkpoint(int64_t handle) {
    Database *db = (Database *)(intptr_t)handle;
    if (db->wal_frames >= 4096 && sqlite3_get_autocommit(db->raw)) {
        int rc = sqlite3_wal_checkpoint_v2(db->raw, NULL, SQLITE_CHECKPOINT_RESTART, NULL, NULL);
        if (rc == SQLITE_OK) db->wal_frames = 0;
    }
}

static int base64_value(unsigned char ch) {
    if (ch >= 'A' && ch <= 'Z') return ch - 'A';
    if (ch >= 'a' && ch <= 'z') return ch - 'a' + 26;
    if (ch >= '0' && ch <= '9') return ch - '0' + 52;
    if (ch == '-') return 62;
    if (ch == '_') return 63;
    return -1;
}

static int base64_decode(const uint8_t *input, int64_t length, uint8_t *output, size_t capacity) {
    if (length < 0 || length % 4 == 1) return -1;
    uint32_t accumulator = 0;
    unsigned bits = 0;
    size_t written = 0;
    for (int64_t i = 0; i < length; i++) {
        int value = base64_value(input[i]);
        if (value < 0) return -1;
        accumulator = (accumulator << 6) | (unsigned)value;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            if (written == capacity) return -1;
            output[written++] = (uint8_t)(accumulator >> bits);
        }
    }
    if (bits && (accumulator & ((1u << bits) - 1u))) return -1;
    return (int)written;
}

/* Callbacks run serially on the single application thread. Keep only the
   keyed SHA-256 state; every token still receives a fresh MAC computation.
   The owned key also detects a changed secret without borrowing Goose memory. */
static struct {
    EVP_MAC *algorithm;
    EVP_MAC_CTX *context;
    uint8_t *key;
    size_t key_length;
    int cleanup_registered;
} auth_hmac;

static void auth_hmac_clear_key(void) {
    EVP_MAC_CTX_free(auth_hmac.context);
    auth_hmac.context = NULL;
    OPENSSL_clear_free(auth_hmac.key, auth_hmac.key_length);
    auth_hmac.key = NULL;
    auth_hmac.key_length = 0;
}

static void auth_hmac_cleanup(void) {
    auth_hmac_clear_key();
    EVP_MAC_free(auth_hmac.algorithm);
    auth_hmac.algorithm = NULL;
}

static int auth_hmac_sha256(bytes secret, const uint8_t *message, size_t length,
                            uint8_t digest[32]) {
    if (!auth_hmac.algorithm) {
        EVP_MAC *algorithm = EVP_MAC_fetch(NULL, "HMAC", NULL);
        if (!algorithm) return 0;
        /* Register after OpenSSL initialization so this runs before its own
           exit cleanup. A failed registration leaves no retained allocation. */
        if (!auth_hmac.cleanup_registered) {
            if (atexit(auth_hmac_cleanup) != 0) { EVP_MAC_free(algorithm); return 0; }
            auth_hmac.cleanup_registered = 1;
        }
        auth_hmac.algorithm = algorithm;
    }
    size_t key_length = (size_t)secret.len;
    if (!auth_hmac.context || auth_hmac.key_length != key_length ||
        (key_length && CRYPTO_memcmp(auth_hmac.key, secret.data, key_length) != 0)) {
        /* Replace transactionally: allocation/setup failure cannot leave the
           old key mislabeled as the new secret. Non-NULL also permits an empty key. */
        uint8_t *key = OPENSSL_malloc(key_length ? key_length : 1);
        EVP_MAC_CTX *context = EVP_MAC_CTX_new(auth_hmac.algorithm);
        if (!key || !context) {
            OPENSSL_clear_free(key, key_length); EVP_MAC_CTX_free(context); return 0;
        }
        if (key_length) memcpy(key, secret.data, key_length);
        OSSL_PARAM params[] = {
            OSSL_PARAM_construct_utf8_string(OSSL_MAC_PARAM_DIGEST, "SHA256", 0),
            OSSL_PARAM_construct_end()
        };
        if (!EVP_MAC_init(context, key, key_length, params)) {
            OPENSSL_clear_free(key, key_length); EVP_MAC_CTX_free(context); return 0;
        }
        auth_hmac_clear_key();
        auth_hmac.context = context;
        auth_hmac.key = key;
        auth_hmac.key_length = key_length;
    } else if (!EVP_MAC_init(auth_hmac.context, NULL, 0, NULL)) {
        auth_hmac_clear_key();
        return 0;
    }
    size_t digest_length = 0;
    if (!EVP_MAC_update(auth_hmac.context, message, length) ||
        !EVP_MAC_final(auth_hmac.context, digest, &digest_length, 32) || digest_length != 32) {
        auth_hmac_clear_key();
        return 0;
    }
    return 1;
}

int32_t auth_decode(bytes token, bytes secret, gs_rref header, gs_rref payload) {
    if (token.len <= 0 || token.len > 16384 || secret.len < 0 || secret.len > 1048576) return 0;
    const uint8_t *first = memchr(token.data, '.', (size_t)token.len);
    if (!first || first == token.data) return 0;
    int64_t remaining = token.len - (first + 1 - token.data);
    const uint8_t *second = memchr(first + 1, '.', (size_t)remaining);
    if (!second || second == first + 1) return 0;
    int64_t signature_length = token.len - (second + 1 - token.data);
    uint8_t signature[32], digest[32];
    if (base64_decode(second + 1, signature_length, signature, sizeof(signature)) != 32) return 0;
    if (!auth_hmac_sha256(secret, token.data, (size_t)(second-token.data), digest)) return 0;
    if (CRYPTO_memcmp(signature, digest, 32) != 0) return 0;
    uint8_t decoded_header[16384], decoded_payload[16384];
    int nh = base64_decode(token.data, first-token.data, decoded_header, sizeof(decoded_header));
    int np = base64_decode(first+1, second-first-1, decoded_payload, sizeof(decoded_payload));
    if (nh <= 0 || np <= 0) return 0;
    gs_bld_append(header, decoded_header, nh);
    gs_bld_append(payload, decoded_payload, np);
    return 1;
}
