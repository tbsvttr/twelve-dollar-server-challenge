#ifndef JWT_H
#define JWT_H

#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <stdlib.h>
#include "sha256.h"

#define JWT_OK 0
#define JWT_ERR_MISSING 1
#define JWT_ERR_INVALID 2
#define JWT_ERR_PAYLOAD 3

static struct hmac_key g_hmac_key;

static const int8_t k_b64url_table[256] = {
    -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
    -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
    -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, 62, -1, 62, -1, 63,
    52, 53, 54, 55, 56, 57, 58, 59, 60, 61, -1, -1, -1, -1, -1, -1,
    -1,  0,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14,
    15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, -1, -1, -1, -1, 63,
    -1, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40,
    41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, -1, -1, -1, -1, -1,
    -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
    -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
    -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
    -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
    -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
    -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
    -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
    -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
};

static inline int b64url_val(unsigned char c) {
    return (int)k_b64url_table[c];
}

static inline int b64url_decode(const char *in, size_t in_len, unsigned char *out, size_t max_out, size_t *out_len) {
    size_t o = 0;
    int val = 0, bits = 0;
    for (size_t i = 0; i < in_len; i++) {
        unsigned char c = (unsigned char)in[i];
        if (c == '=') break;
        int d = b64url_val(c);
        if (d < 0) return -1;
        val = (val << 6) | d;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            if (o >= max_out) return -1;
            out[o++] = (unsigned char)((val >> bits) & 0xFF);
        }
    }
    *out_len = o;
    return 0;
}

static inline void jwt_init(const char *secret) {
    hmac_key_init(&g_hmac_key, (const uint8_t*)secret, strlen(secret));
}

/* Fast verification of Header, Payload, Signature */
static inline int jwt_verify(const char *token, size_t token_len, int64_t now_s,
                             int64_t *out_user_id, char *out_username, size_t username_cap) {
    if (!token || token_len < 10) return JWT_ERR_INVALID;

    const char *dot1 = memchr(token, '.', token_len);
    if (!dot1) return JWT_ERR_INVALID;
    size_t d1_idx = (size_t)(dot1 - token);
    const char *dot2 = memchr(dot1 + 1, '.', token_len - d1_idx - 1);
    if (!dot2) return JWT_ERR_INVALID;

    size_t header_len = d1_idx;
    size_t payload_len = (size_t)(dot2 - dot1 - 1);
    const char *sig_str = dot2 + 1;
    size_t sig_len = token_len - (size_t)(sig_str - token);
    if (header_len == 0 || payload_len == 0 || sig_len == 0) return JWT_ERR_INVALID;

    /* 1. Verify signature */
    unsigned char expected_sig[32];
    memset(expected_sig, 0, 32);
    size_t dec_sig_len = 0;
    if (b64url_decode(sig_str, sig_len, expected_sig, sizeof(expected_sig), &dec_sig_len) != 0 || dec_sig_len != 32) {
        return JWT_ERR_INVALID;
    }

    unsigned char computed_sig[32];
    hmac_sha256(&g_hmac_key, (const uint8_t*)token, (size_t)(dot2 - token), computed_sig);

    // Constant-time compare
    unsigned diff = 0;
    for (int i = 0; i < 32; i++) {
        diff |= (expected_sig[i] ^ computed_sig[i]);
    }
    if (diff != 0) {
        return JWT_ERR_INVALID;
    }

    /* 2. Decode and check header (must be HS256) */
    unsigned char hdr[256];
    size_t hdr_len = 0;
    if (b64url_decode(token, header_len, hdr, sizeof(hdr) - 1, &hdr_len) != 0) return JWT_ERR_INVALID;
    hdr[hdr_len] = '\0';
    if (!strstr((char*)hdr, "\"HS256\"")) {
        return JWT_ERR_INVALID;
    }

    /* 3. Decode and check payload */
    unsigned char pld[512];
    size_t pld_len = 0;
    if (b64url_decode(dot1 + 1, payload_len, pld, sizeof(pld) - 1, &pld_len) != 0) return JWT_ERR_INVALID;
    pld[pld_len] = '\0';
    const char *p = (char*)pld;

    /* Check "exp" */
    const char *exp_p = strstr(p, "\"exp\"");
    if (!exp_p) return JWT_ERR_INVALID;
    exp_p = strchr(exp_p + 5, ':');
    if (!exp_p) return JWT_ERR_INVALID;
    while (*exp_p == ':' || *exp_p == ' ' || *exp_p == '\t') exp_p++;
    char *endp = NULL;
    int64_t exp_val = strtoll(exp_p, &endp, 10);
    if (exp_val <= now_s) return JWT_ERR_INVALID;

    /* Check "sub" - must be positive integer string e.g. "sub":"123" */
    const char *sub_p = strstr(p, "\"sub\"");
    if (!sub_p) return JWT_ERR_PAYLOAD;
    sub_p = strchr(sub_p + 5, ':');
    if (!sub_p) return JWT_ERR_PAYLOAD;
    while (*sub_p == ':' || *sub_p == ' ' || *sub_p == '\t') sub_p++;
    if (*sub_p != '"') return JWT_ERR_PAYLOAD;
    sub_p++; // skip quote
    if (*sub_p < '1' || *sub_p > '9') return JWT_ERR_PAYLOAD; // positive int starts with 1-9
    int64_t uid = strtoll(sub_p, &endp, 10);
    if (!endp || *endp != '"' || uid <= 0) return JWT_ERR_PAYLOAD;
    *out_user_id = uid;

    /* Check "username" - must be non-empty string */
    const char *un_p = strstr(p, "\"username\"");
    if (!un_p) return JWT_ERR_PAYLOAD;
    un_p = strchr(un_p + 10, ':');
    if (!un_p) return JWT_ERR_PAYLOAD;
    while (*un_p == ':' || *un_p == ' ' || *un_p == '\t') un_p++;
    if (*un_p != '"') return JWT_ERR_PAYLOAD;
    un_p++;
    const char *un_end = strchr(un_p, '"');
    if (!un_end || un_end == un_p) return JWT_ERR_PAYLOAD;
    size_t un_len = (size_t)(un_end - un_p);
    if (un_len >= username_cap) un_len = username_cap - 1;
    memcpy(out_username, un_p, un_len);
    out_username[un_len] = '\0';

    return JWT_OK;
}

#endif
