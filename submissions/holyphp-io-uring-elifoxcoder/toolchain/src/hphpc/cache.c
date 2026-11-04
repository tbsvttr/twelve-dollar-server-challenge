#include "util.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <direct.h>
#else
#include <sys/stat.h>
#endif

static const char *cache_dir(void) {
    static char *dir = NULL;
    if (dir) return dir;
    const char *base = getenv("LOCALAPPDATA");
#ifdef _WIN32
    if (!base || !*base) base = getenv("USERPROFILE");
    if (!base || !*base) base = getenv("TEMP");
#else
    if (!base || !*base) base = getenv("HOME");
#endif
    if (base && *base)
        dir = fmt("%s/.hphp/cache", base);
    else
        dir = xstrdup(".hphp/cache");
#ifdef _WIN32
    _mkdir(dir);
#else
    mkdir(dir, 0755);
#endif
    return dir;
}

static unsigned long simple_hash(const char *s) {
    unsigned long h = 5381;
    int c;
    while ((c = (unsigned char)*s++)) h = ((h << 5) + h) + c;
    return h;
}

static char *hash_file(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return xstrdup("0");
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return xstrdup("0"); }
    long len = ftell(f);
    if (len < 0) { fclose(f); return xstrdup("0"); }
    fseek(f, 0, SEEK_SET);
    char *buf = malloc((size_t)len + 1);
    if (!buf) { fclose(f); return xstrdup("0"); }
    fread(buf, 1, (size_t)len, f);
    buf[len] = 0;
    fclose(f);
    unsigned long h = 0;
    for (long i = 0; i < len; i++) h = ((h << 5) + h) + (unsigned char)buf[i];
    free(buf);
    char *out = malloc(32);
    snprintf(out, 32, "%lx_%ld", h, len);
    return out;
}

char *cache_key_for_files(PtrVec *files, PtrVec *tools) {
    char *key = malloc(8192);
    key[0] = 0;
    for (size_t i = 0; i < files->len; i++) {
        const char *p = files->items[i];
        char *h = hash_file(p);
        strcat(key, p);
        strcat(key, ":");
        strcat(key, h);
        strcat(key, ";");
        free(h);
    }
    /* The toolchain is an input as well: the compiler binary and the
     * runtime sources decide what the build produces. A key that leaves
     * them out hands back yesterday's binary after the compiler changed -
     * the program looks broken and nothing in it did. */
    if (tools) {
        for (size_t i = 0; i < tools->len; i++) {
            const char *p = tools->items[i];
            char *h = hash_file(p);
            strcat(key, p);
            strcat(key, ":");
            strcat(key, h);
            strcat(key, ";");
            free(h);
        }
    }
    /* An external static library is an input too. build.sh points
     * HPHP_SQLITE_LIB at a freshly built SQLite; a cache key that ignores it
     * hands back a binary linked against the system library instead. */
    {
        const char *slib = getenv("HPHP_SQLITE_LIB");
        if (slib && *slib) {
            char *h = hash_file(slib);
            strcat(key, slib);
            strcat(key, ":");
            strcat(key, h);
            strcat(key, ";");
            free(h);
        }
    }
    /* Compiler and link flags change both object code and linked images.
     * Include them in the cache identity so switching between portable O2
     * and target-tuned LTO builds cannot return a stale executable. */
    unsigned long kh = simple_hash(key);
    {
        const char *names[] = {"HPHP_OPT", "HPHP_CFLAGS"};
        for (size_t i = 0; i < sizeof names / sizeof names[0]; i++) {
            const char *v = getenv(names[i]);
            if (v && *v) {
                const char *parts[] = {names[i], "=", v, ";"};
                for (size_t j = 0; j < sizeof parts / sizeof parts[0]; j++)
                    for (const unsigned char *p = (const unsigned char *)parts[j];
                         *p; p++)
                        kh = ((kh << 5) + kh) + *p;
            }
        }
    }
    char *res = malloc(64);
    snprintf(res, 64, "cache_%lx", kh);
    free(key);
    return res;
}

bool cache_has_object(const char *key, const char *objname) {
    const char *dir = cache_dir();
    char *path = fmt("%s/%s_%s", dir, key, objname);
    FILE *f = fopen(path, "rb");
    bool ok = f != NULL;
    if (f) fclose(f);
    free(path);
    return ok;
}

bool cache_get_object(const char *key, const char *objname, const char *dest) {
    const char *dir = cache_dir();
    char *src = fmt("%s/%s_%s", dir, key, objname);
    FILE *fs = fopen(src, "rb");
    if (!fs) { free(src); return false; }
    FILE *fd = fopen(dest, "wb");
    if (!fd) { fclose(fs); free(src); return false; }
    char buf[4096];
    size_t n;
    while ((n = fread(buf, 1, sizeof buf, fs))) fwrite(buf, 1, n, fd);
    fclose(fs); fclose(fd);
    free(src);
    return true;
}

bool cache_put_object(const char *key, const char *objname, const char *src) {
    const char *dir = cache_dir();
    char *dst = fmt("%s/%s_%s", dir, key, objname);
    if (getenv("HPHP_VERBOSE")) fprintf(stderr, "[cache] put %s -> %s\n", src, dst);
    FILE *fs = fopen(src, "rb");
    if (!fs) { free(dst); return false; }
    FILE *fd = fopen(dst, "wb");
    if (!fd) { fclose(fs); free(dst); return false; }
    char buf[4096];
    size_t n;
    while ((n = fread(buf, 1, sizeof buf, fs))) fwrite(buf, 1, n, fd);
    fclose(fs); fclose(fd);
    free(dst);
    return true;
}

bool cache_has_generated(const char *key) {
    const char *dir = cache_dir();
    char *path = fmt("%s/%s_prog.c", dir, key);
    FILE *f = fopen(path, "rb");
    bool ok = f != NULL;
    if (f) fclose(f);
    free(path);
    return ok;
}

bool cache_get_generated(const char *key, const char *dest) {
    const char *dir = cache_dir();
    char *src = fmt("%s/%s_prog.c", dir, key);
    FILE *fs = fopen(src, "rb");
    if (!fs) { free(src); return false; }
    FILE *fd = fopen(dest, "wb");
    if (!fd) { fclose(fs); free(src); return false; }
    char buf[4096];
    size_t n;
    while ((n = fread(buf, 1, sizeof buf, fs))) fwrite(buf, 1, n, fd);
    fclose(fs); fclose(fd);
    free(src);
    return true;
}

bool cache_put_generated(const char *key, const char *src) {
    const char *dir = cache_dir();
    char *dst = fmt("%s/%s_prog.c", dir, key);
    FILE *fs = fopen(src, "rb");
    if (!fs) { free(dst); return false; }
    FILE *fd = fopen(dst, "wb");
    if (!fd) { fclose(fs); free(dst); return false; }
    char buf[4096];
    size_t n;
    while ((n = fread(buf, 1, sizeof buf, fs))) fwrite(buf, 1, n, fd);
    fclose(fs); fclose(fd);
    free(dst);
    return true;
}

/* The linked image is cached under its own name so a repeat build can skip
 * the link step entirely. The key already covers every input plus the
 * optimization mode, so the image is exactly what a fresh link would
 * produce. */
bool cache_has_exe(const char *key) {
    const char *dir = cache_dir();
    char *path = fmt("%s/%s_bin", dir, key);
    FILE *f = fopen(path, "rb");
    bool ok = f != NULL;
    if (f) fclose(f);
    free(path);
    return ok;
}

bool cache_get_exe(const char *key, const char *dest) {
    const char *dir = cache_dir();
    char *src = fmt("%s/%s_bin", dir, key);
    FILE *fs = fopen(src, "rb");
    if (!fs) { free(src); return false; }
    FILE *fd = fopen(dest, "wb");
    if (!fd) { fclose(fs); free(src); return false; }
    char buf[65536];
    size_t n;
    while ((n = fread(buf, 1, sizeof buf, fs))) fwrite(buf, 1, n, fd);
    fclose(fs); fclose(fd);
#ifndef _WIN32
    /* The cache entry is a plain fopen() copy, so it arrives without the
     * executable bit. A restored image that is not executable is useless:
     * the run fails with EACCES. */
    chmod(dest, 0755);
#endif
    free(src);
    return true;
}

bool cache_put_exe(const char *key, const char *src) {
    const char *dir = cache_dir();
    char *dst = fmt("%s/%s_bin", dir, key);
    if (getenv("HPHP_VERBOSE")) fprintf(stderr, "[cache] put exe %s -> %s\n", src, dst);
    FILE *fs = fopen(src, "rb");
    if (!fs) { free(dst); return false; }
    FILE *fd = fopen(dst, "wb");
    if (!fd) { fclose(fs); free(dst); return false; }
    char buf[65536];
    size_t n;
    while ((n = fread(buf, 1, sizeof buf, fs))) fwrite(buf, 1, n, fd);
    fclose(fs); fclose(fd);
    free(dst);
    return true;
}
