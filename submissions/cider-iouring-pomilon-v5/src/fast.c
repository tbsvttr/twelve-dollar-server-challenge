// Hot-path helpers that are easier to express efficiently in C than in the
// current Cider code generator.  These are ordinary in-process functions; they
// do not cache anything and do not bypass SQLite.
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <emmintrin.h>
#include <sys/mman.h>
#include <unistd.h>

// Lock the executable's own mappings in RAM. On a box with no swap,
// file-backed code pages are what reclaim takes first; a major fault on the
// event loop's own code while requests wait in the kernel is a long stall.
// Best effort: if RLIMIT_MEMLOCK is too small, the server runs unlocked.
long long fast_lock_code(void) {
    char exe[512];
    ssize_t n = readlink("/proc/self/exe", exe, sizeof exe - 1);
    if (n <= 0) {
        return 0;
    }
    exe[n] = 0;
    FILE *f = fopen("/proc/self/maps", "r");
    if (!f) {
        return 0;
    }
    char line[1024];
    long long locked = 0;
    while (fgets(line, sizeof line, f)) {
        unsigned long lo, hi;
        char perms[8];
        int path = 0;
        if (sscanf(line, "%lx-%lx %7s %*s %*s %*s %n", &lo, &hi, perms, &path) < 3 || !path) {
            continue;
        }
        line[strcspn(line, "\n")] = 0;
        if (strcmp(line + path, exe)) {
            continue;
        }
        if (mlock((void *)lo, hi - lo) == 0) {
            locked += (long long)(hi - lo);
        }
    }
    fclose(f);
    return locked;
}

typedef struct {
    char *buf;
    int len;
    int cap;
} BufWriterC;

static int bw_put(BufWriterC *w, const char *src, int n) {
    if (n <= 0) {
        return 1;
    }
    if (w->len + n >= w->cap) {
        return 0;
    }
    memcpy(w->buf + w->len, src, (size_t)n);
    w->len += n;
    return 1;
}

void fast_append_i64(void *writer, long long value) {
    BufWriterC *w = (BufWriterC *)writer;
    unsigned long long u;
    int neg = value < 0;
    if (neg) {
        u = (unsigned long long)(-(value + 1)) + 1ULL;
    } else {
        u = (unsigned long long)value;
    }

    char tmp[20];
    int n = 0;
    while (u >= 100ULL) {
        unsigned long long q = u / 100ULL;
        unsigned r = (unsigned)(u - q * 100ULL);
        tmp[n++] = (char)('0' + (r % 10U));
        tmp[n++] = (char)('0' + (r / 10U));
        u = q;
    }
    if (u >= 10ULL) {
        tmp[n++] = (char)('0' + (u % 10ULL));
        tmp[n++] = (char)('0' + (u / 10ULL));
    } else {
        tmp[n++] = (char)('0' + u);
    }

    int total = n + neg;
    if (w->len + total >= w->cap) {
        return;
    }
    char *d = w->buf + w->len;
    if (neg) {
        *d++ = '-';
    }
    while (n > 0) {
        *d++ = tmp[--n];
    }
    w->len += total;
}

void fast_append_json_string(void *writer, const char *s, int slen) {
    static const char hex[] = "0123456789abcdef";
    BufWriterC *w = (BufWriterC *)writer;
    if (!bw_put(w, "\"", 1)) {
        return;
    }

    int i = 0;
    int start = 0;
    const __m128i vq = _mm_set1_epi8('"');
    const __m128i vb = _mm_set1_epi8('\\');
    const __m128i vmask = _mm_set1_epi8((char)0xE0);

    while (i + 16 <= slen) {
        __m128i v = _mm_loadu_si128((const __m128i *)(const void *)(s + i));
        __m128i q = _mm_cmpeq_epi8(v, vq);
        __m128i b = _mm_cmpeq_epi8(v, vb);
        __m128i c = _mm_cmpeq_epi8(_mm_and_si128(v, vmask), _mm_setzero_si128());
        int mask = _mm_movemask_epi8(_mm_or_si128(_mm_or_si128(q, b), c));
        if (mask == 0) {
            i += 16;
            continue;
        }

        int off = __builtin_ctz((unsigned)mask);
        if (!bw_put(w, s + start, (i + off) - start)) {
            return;
        }
        unsigned char ch = (unsigned char)s[i + off];
        char esc[6];
        int en;
        switch (ch) {
            case '"':  esc[0] = '\\'; esc[1] = '"';  en = 2; break;
            case '\\': esc[0] = '\\'; esc[1] = '\\'; en = 2; break;
            case 10:   esc[0] = '\\'; esc[1] = 'n';  en = 2; break;
            case 13:   esc[0] = '\\'; esc[1] = 'r';  en = 2; break;
            case 9:    esc[0] = '\\'; esc[1] = 't';  en = 2; break;
            case 8:    esc[0] = '\\'; esc[1] = 'b';  en = 2; break;
            case 12:   esc[0] = '\\'; esc[1] = 'f';  en = 2; break;
            default:
                esc[0] = '\\'; esc[1] = 'u'; esc[2] = '0'; esc[3] = '0';
                esc[4] = hex[ch >> 4];
                esc[5] = hex[ch & 15];
                en = 6;
                break;
        }
        if (!bw_put(w, esc, en)) {
            return;
        }
        i += off + 1;
        start = i;
    }

    while (i < slen) {
        unsigned char ch = (unsigned char)s[i];
        if (ch < 32 || ch == (unsigned char)'"' || ch == (unsigned char)'\\') {
            if (!bw_put(w, s + start, i - start)) {
                return;
            }
            char esc[6];
            int en;
            switch (ch) {
                case '"':  esc[0] = '\\'; esc[1] = '"';  en = 2; break;
                case '\\': esc[0] = '\\'; esc[1] = '\\'; en = 2; break;
                case 10:   esc[0] = '\\'; esc[1] = 'n';  en = 2; break;
                case 13:   esc[0] = '\\'; esc[1] = 'r';  en = 2; break;
                case 9:    esc[0] = '\\'; esc[1] = 't';  en = 2; break;
                case 8:    esc[0] = '\\'; esc[1] = 'b';  en = 2; break;
                case 12:   esc[0] = '\\'; esc[1] = 'f';  en = 2; break;
                default:
                    esc[0] = '\\'; esc[1] = 'u'; esc[2] = '0'; esc[3] = '0';
                    esc[4] = hex[ch >> 4];
                    esc[5] = hex[ch & 15];
                    en = 6;
                    break;
            }
            if (!bw_put(w, esc, en)) {
                return;
            }
            start = i + 1;
        }
        i++;
    }
    if (slen > start) {
        bw_put(w, s + start, slen - start);
    }
    bw_put(w, "\"", 1);
}
