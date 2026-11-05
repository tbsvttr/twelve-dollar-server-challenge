#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#ifndef HTTP_H
#define HTTP_H

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <ctype.h>

#define METHOD_UNKNOWN 0
#define METHOD_GET 1
#define METHOD_POST 2

// 32-bit SWAR constants (little-endian x86-64)
#define METHOD_GET_U32  0x20544547U // "GET " -> 'G' | ('E'<<8) | ('T'<<16) | (' '<<24)
#define METHOD_POST_U32 0x54534f50U // "POST" -> 'P' | ('O'<<8) | ('S'<<16) | ('T'<<24)

typedef struct {
    int method;
    const char *path;
    size_t path_len;
    const char *auth_token;
    size_t auth_token_len;
    int has_auth_header;
    int is_bearer;
    size_t content_length;
    const char *body;
    size_t body_len;
    int keep_alive;
} http_request_t;

/* Parse HTTP/1.1 request */
static inline int http_parse_request(const char *buf, size_t len, http_request_t *req) {
    memset(req, 0, sizeof(*req));
    req->keep_alive = 1; // HTTP/1.1 default

    if (len < 14) return -1; // minimal request length

    // 1. Method (Single 32-bit SWAR comparison)
    const char *p = buf;
    const char *end = buf + len;
    uint32_t m4;
    memcpy(&m4, p, sizeof(m4));
    if (m4 == METHOD_GET_U32) {
        req->method = METHOD_GET;
        p += 4;
    } else if (m4 == METHOD_POST_U32 && p[4] == ' ') {
        req->method = METHOD_POST;
        p += 5;
    } else {
        req->method = METHOD_UNKNOWN;
        while (p < end && *p != ' ') p++;
        if (p < end) p++;
    }

    // 2. Path
    req->path = p;
    while (p < end && *p != ' ' && *p != '\r' && *p != '\n') p++;
    req->path_len = (size_t)(p - req->path);
    if (p >= end || *p != ' ') return -1;

    // Skip to first header line
    const char *line = strstr(p, "\r\n");
    if (!line) return -1;
    line += 2;

    // 3. Headers
    while (line < end) {
        if (line[0] == '\r' && line + 1 < end && line[1] == '\n') {
            line += 2;
            break; // End of headers
        }
        if (line[0] == '\n') {
            line += 1;
            break;
        }

        const char *next_line = strstr(line, "\r\n");
        if (!next_line) break;
        size_t hlen = (size_t)(next_line - line);

        // Check Authorization header
        if (hlen >= 14 && strncasecmp(line, "authorization:", 14) == 0) {
            req->has_auth_header = 1;
            const char *val = line + 14;
            while (val < next_line && (*val == ' ' || *val == '\t')) val++;
            if (next_line - val >= 7 && strncmp(val, "Bearer ", 7) == 0) {
                req->is_bearer = 1;
                val += 7;
                while (val < next_line && (*val == ' ' || *val == '\t')) val++;
                req->auth_token = val;
                req->auth_token_len = (size_t)(next_line - val);
                // trim trailing spaces
                while (req->auth_token_len > 0 && 
                       (req->auth_token[req->auth_token_len - 1] == ' ' || 
                        req->auth_token[req->auth_token_len - 1] == '\t')) {
                    req->auth_token_len--;
                }
            }
        } else if (hlen >= 15 && strncasecmp(line, "content-length:", 15) == 0) {
            const char *val = line + 15;
            while (val < next_line && (*val == ' ' || *val == '\t')) val++;
            req->content_length = (size_t)strtoul(val, NULL, 10);
        } else if (hlen >= 11 && strncasecmp(line, "connection:", 11) == 0) {
            const char *val = line + 11;
            while (val < next_line && (*val == ' ' || *val == '\t')) val++;
            if (strncasecmp(val, "close", 5) == 0) {
                req->keep_alive = 0;
            }
        }

        line = next_line + 2;
    }

    req->body = line;
    req->body_len = (size_t)(end - line);
    if (req->body_len > req->content_length && req->content_length > 0) {
        req->body_len = req->content_length;
    }

    return 0;
}

/* Fast JSON string escaper using 256-byte sparse index table -> content table */
static const char JSON_ESC_CONTENT[40][7] = {
    "",         // 0: plain byte
    "\\\"",     // 1: "
    "\\\\",     // 2: \
    "\\b",      // 3: \b
    "\\f",      // 4: \f
    "\\n",      // 5: \n
    "\\r",      // 6: \r
    "\\t",      // 7: \t
    "\\u0000", "\\u0001", "\\u0002", "\\u0003", "\\u0004", "\\u0005", "\\u0006", "\\u0007",
    "\\u0008", "\\u0009", "\\u000a", "\\u000b", "\\u000c", "\\u000d", "\\u000e", "\\u000f",
    "\\u0010", "\\u0011", "\\u0012", "\\u0013", "\\u0014", "\\u0015", "\\u0016", "\\u0017",
    "\\u0018", "\\u0019", "\\u001a", "\\u001b", "\\u001c", "\\u001d", "\\u001e", "\\u001f"
};

static const uint8_t JSON_ESC_MAP[256] = {
     8,  9, 10, 11, 12, 13, 14, 15,  3,  7,  5, 19,  4,  6, 22, 23,
    24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39,
     0,  0,  1,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
     0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
     0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
     0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  2,  0,  0,  0,
     0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
     0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
     0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
     0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
     0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
     0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
     0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
     0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
     0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
     0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0
};

static inline size_t json_escape_string(const char *src, size_t src_len, char *dst, size_t dst_cap) {
    size_t o = 0;
    for (size_t i = 0; i < src_len && o + 6 < dst_cap; i++) {
        unsigned char c = (unsigned char)src[i];
        uint8_t idx = JSON_ESC_MAP[c];
        if (__builtin_expect(idx == 0, 1)) {
            dst[o++] = (char)c;
        } else {
            size_t len = (idx < 8) ? 2 : 6;
            memcpy(dst + o, JSON_ESC_CONTENT[idx], len);
            o += len;
        }
    }
    return o;
}

/* Single-character JSON unescape map ('u' -> 0 sentinel) */
static const char JSON_UNESCAPE_MAP[256] = {
      0,   1,   2,   3,   4,   5,   6,   7,   8,   9,  10,  11,  12,  13,  14,  15,
     16,  17,  18,  19,  20,  21,  22,  23,  24,  25,  26,  27,  28,  29,  30,  31,
     32,  33,  34,  35,  36,  37,  38,  39,  40,  41,  42,  43,  44,  45,  46,  47,
     48,  49,  50,  51,  52,  53,  54,  55,  56,  57,  58,  59,  60,  61,  62,  63,
     64,  65,  66,  67,  68,  69,  70,  71,  72,  73,  74,  75,  76,  77,  78,  79,
     80,  81,  82,  83,  84,  85,  86,  87,  88,  89,  90,  91,  92,  93,  94,  95,
     96,  97,   8,  99, 100, 101,  12, 103, 104, 105, 106, 107, 108, 109,  10, 111,
    112, 113,  13, 115,   9,   0, 118, 119, 120, 121, 122, 123, 124, 125, 126, 127,
    128, 129, 130, 131, 132, 133, 134, 135, 136, 137, 138, 139, 140, 141, 142, 143,
    144, 145, 146, 147, 148, 149, 150, 151, 152, 153, 154, 155, 156, 157, 158, 159,
    160, 161, 162, 163, 164, 165, 166, 167, 168, 169, 170, 171, 172, 173, 174, 175,
    176, 177, 178, 179, 180, 181, 182, 183, 184, 185, 186, 187, 188, 189, 190, 191,
    192, 193, 194, 195, 196, 197, 198, 199, 200, 201, 202, 203, 204, 205, 206, 207,
    208, 209, 210, 211, 212, 213, 214, 215, 216, 217, 218, 219, 220, 221, 222, 223,
    224, 225, 226, 227, 228, 229, 230, 231, 232, 233, 234, 235, 236, 237, 238, 239,
    240, 241, 242, 243, 244, 245, 246, 247, 248, 249, 250, 251, 252, 253, 254, 255
};

/* Parse post body from JSON: {"body":"..."} */
#define POST_BODY_OK 0
#define POST_BODY_MALFORMED 1
#define POST_BODY_REQUIRED 2
#define POST_BODY_TOO_LONG 3

static inline int parse_post_body(const char *raw, size_t raw_len, char *out_body, size_t out_cap, size_t *out_len) {
    if (!raw || raw_len == 0) return POST_BODY_MALFORMED;

    // Check basic JSON syntax
    const char *p = raw;
    const char *end = raw + raw_len;
    while (p < end && isspace((unsigned char)*p)) p++;
    if (p >= end || *p != '{') return POST_BODY_MALFORMED;
    p++;
    while (p < end && isspace((unsigned char)*p)) p++;

    const char *key = NULL;
    if (__builtin_expect(p + 6 <= end && memcmp(p, "\"body\"", 6) == 0, 1)) {
        key = p;
    } else {
        key = (const char *)memmem(p, (size_t)(end - p), "\"body\"", 6);
    }

    if (!key) {
        // If not malformed JSON, then body is missing -> body is required
        // Check if there is closing brace
        const char *close_brace = (const char *)memchr(p, '}', (size_t)(end - p));
        if (!close_brace) return POST_BODY_MALFORMED;
        return POST_BODY_REQUIRED;
    }

    if (key + 6 > end) return POST_BODY_MALFORMED;
    const char *colon = (const char *)memchr(key + 6, ':', (size_t)(end - (key + 6)));
    if (!colon) return POST_BODY_MALFORMED;
    p = colon + 1;
    while (p < end && isspace((unsigned char)*p)) p++;
    if (p >= end) return POST_BODY_MALFORMED;
    if (*p != '"') {
        // numeric, boolean, null, or array/object -> body is required
        return POST_BODY_REQUIRED;
    }
    p++; // skip starting quote

    // Extract and unescape string until unescaped closing quote
    char unescaped[2048];
    size_t u_len = 0;
    int closed = 0;
    while (p < end && u_len + 1 < sizeof(unescaped)) {
        if (*p == '"') {
            closed = 1;
            p++;
            break;
        }
        if (*p == '\\') {
            p++;
            if (p >= end) return POST_BODY_MALFORMED;
            char mapped = JSON_UNESCAPE_MAP[(unsigned char)*p];
            if (__builtin_expect(mapped != 0, 1)) {
                unescaped[u_len++] = mapped;
            } else {
                // \uXXXX
                if (p + 4 >= end) return POST_BODY_MALFORMED;
                unescaped[u_len++] = '?';
                p += 4;
            }
            p++;
        } else {
            unescaped[u_len++] = *p++;
        }
    }
    if (!closed) return POST_BODY_MALFORMED;

    // Check rest of JSON up to closing brace
    while (p < end && isspace((unsigned char)*p)) p++;
    if (p >= end || *p != '}') return POST_BODY_MALFORMED;

    // Trim leading and trailing whitespace
    size_t start_idx = 0;
    while (start_idx < u_len && isspace((unsigned char)unescaped[start_idx])) start_idx++;
    if (start_idx >= u_len) return POST_BODY_REQUIRED; // empty after trim

    size_t end_idx = u_len;
    while (end_idx > start_idx && isspace((unsigned char)unescaped[end_idx - 1])) end_idx--;

    size_t trimmed_len = end_idx - start_idx;
    if (trimmed_len == 0) return POST_BODY_REQUIRED;
    if (trimmed_len > 500) return POST_BODY_TOO_LONG;
    if (trimmed_len >= out_cap) trimmed_len = out_cap - 1;

    memcpy(out_body, unescaped + start_idx, trimmed_len);
    out_body[trimmed_len] = '\0';
    *out_len = trimmed_len;

    return POST_BODY_OK;
}

/* HTTP response formatters */
static inline size_t format_response(char *buf, size_t cap, int status, const char *status_str,
                                     const char *body, size_t body_len, int keep_alive) {
    const char *conn = keep_alive ? "keep-alive" : "close";
    int header_len = snprintf(buf, cap,
        "HTTP/1.1 %d %s\r\n"
        "Content-Type: application/json\r\n"
        "Content-Length: %zu\r\n"
        "Connection: %s\r\n"
        "\r\n",
        status, status_str, body_len, conn);

    if (header_len < 0 || (size_t)header_len + body_len > cap) return 0;
    memcpy(buf + header_len, body, body_len);
    return (size_t)header_len + body_len;
}

static inline size_t format_error(char *buf, size_t cap, int status, const char *status_str,
                                  const char *msg, int keep_alive) {
    char body[256];
    int body_len = snprintf(body, sizeof(body), "{\"error\":\"%s\"}", msg);
    return format_response(buf, cap, status, status_str, body, (size_t)body_len, keep_alive);
}

#endif
