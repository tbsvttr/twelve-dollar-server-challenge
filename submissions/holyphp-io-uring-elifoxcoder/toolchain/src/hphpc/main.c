/* main.c — the `hphp` driver: the HolyPHP language toolchain.
 *
 * One self-contained binary. The C runtime sources and the hphp_rt.h header
 * are embedded inside hphp.exe at build time and extracted into a private
 * per-user cache directory on demand — an installed hphp.exe needs nothing
 * else on the machine. Users never see intermediate files: .hphp source goes
 * in, a native executable (or its output) comes out.
 *
 *   hphp file.hphp              run a HolyPHP program (default command)
 *   hphp run file.hphp          same, keeps argv pass-through
 *   hphp build file.hphp -o app build a native executable
 *   hphp check file.hphp        type- & borrow-check only
 *   hphp emit file.hphp         inspect the lowered internal representation
 *   hphp version                print version
 *
 * Set HPHP_VERBOSE=1 to see backend commands, HPHP_KEEP_BIN=1 to keep
 * executables produced by `run`.
 */
/* feature-test macros first: on glibc, POSIX symbols (usleep, popen,
 * S_IFDIR, dirent) are hidden under strict -std=c11 */
#if !defined(_WIN32)
#define _DEFAULT_SOURCE 1
#endif
#include "parser.h"
#include "sema.h"
#include "codegen.h"
#include "builtins.h"
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/stat.h>
#include <sys/types.h>

#define HPHP_VERSION "1.0.2"

/* Used by install/search/publish when the user has not configured a registry
 * (no registry_url file, no $HPHP_REGISTRY). Hosted alongside the project;
 * see registry/README.md. */
#define PKG_DEFAULT_REGISTRY "http://hphp.ch:8930"

#include "runtime_embed.h" /* the runtime, embedded in this binary */
#include "pkgcore.h"
#include "pkgnet.h"

#if defined(_WIN32)
#include <windows.h>
static void nap_ms(int ms) { Sleep((DWORD)ms); }
#else
#include <unistd.h>
#include <sys/wait.h>
static void nap_ms(int ms) { usleep((useconds_t)ms * 1000); }
#endif

/* package-manager hook: where an `import "name/..."` finds installed packages.
 * Layout in the pkg home: packages/<name>/<entry or name>.hphp. Also accepts
 * plain "name.hphp" when name is an installed package. Returns malloc'd path
 * or NULL. Defined here so it can use read_file-free path logic; the actual
 * file read is done by the caller. */
static char *pkg_import_candidate(const char *spec) {
    /* form: "<pkg>/file.hphp" or "<pkg>.hphp" or "<pkg>" (-> entry/<pkg>.hphp) */
    char *slash = strchr(spec, '/');
    if (slash) {
        char pkg[128];
        size_t pl = (size_t)(slash - spec);
        if (pl == 0 || pl >= sizeof pkg) return NULL;
        memcpy(pkg, spec, pl); pkg[pl] = 0;
        if (!pkg_is_installed(pkg)) return NULL;
        char *dir = pkg_dir_of(pkg);
        char *cand = fmt("%s/%s", dir, slash + 1);
        free(dir);
        return cand;
    }
    const char *stem = spec;
    size_t sl = strlen(spec);
    char stembuf[128];
    if (sl > 5 && !strcmp(spec + sl - 5, ".hphp")) {
        if (sl - 5 >= sizeof stembuf) return NULL;
        memcpy(stembuf, spec, sl - 5); stembuf[sl - 5] = 0;
        stem = stembuf;
    }
    if (!pkg_is_installed(stem)) return NULL;
    /* prefer the manifest entry, then <pkg>.hphp */
    char *dir = pkg_dir_of(stem);
    char *mf = fmt("%s/" PKG_MANIFEST, dir);
    char *cand = NULL;
    FILE *f = fopen(mf, "rb");
    if (f) {
        char js[4096];
        size_t got = fread(js, 1, sizeof js - 1, f);
        js[got] = 0;
        fclose(f);
        /* entry from manifest */
        const char *ek = strstr(js, "\"entry\"");
        if (ek) {
            const char *p = strchr(ek + 7, '"');
            if (p) {
                const char *e = strchr(p + 1, '"');
                if (e && e > p + 1) {
                    char entry[256];
                    size_t el = (size_t)(e - p - 1);
                    if (el < sizeof entry) {
                        memcpy(entry, p + 1, el); entry[el] = 0;
                        cand = fmt("%s/%s", dir, entry);
                    }
                }
            }
        }
    }
    if (!cand) cand = fmt("%s/%s.hphp", dir, stem);
    free(mf); free(dir);
    return cand;
}

/* like read_file_or_die, but a missing file is not an error (import search) */
static char *read_file_soft(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *buf = xmalloc((size_t)n + 1);
    size_t got = fread(buf, 1, (size_t)n, f);
    buf[got] = 0;
    fclose(f);
    return buf;
}

static char *read_file_or_die(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) fatal("cannot open '%s'", path);
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *buf = xmalloc((size_t)n + 1);
    size_t got = fread(buf, 1, (size_t)n, f);
    buf[got] = 0;
    fclose(f);
    return buf;
}

/* ------------------------------------------------------------------ */
/* paths                                                               */
/* ------------------------------------------------------------------ */

static const char *path_file_name(const char *p) {
    const char *slash = strrchr(p, '/'), *bslash = strrchr(p, '\\');
    const char *cut = slash > bslash ? slash : bslash;
    return cut ? cut + 1 : p;
}

static char *path_join(const char *a, const char *b) {
    size_t n = strlen(a);
    if (n && (a[n - 1] == '/' || a[n - 1] == '\\')) return fmt("%s%s", a, b);
    return fmt("%s/%s", a, b);
}

/* ------------------------------------------------------------------ */
/* hphp private directory (runtime extraction + build cache)           */
/* ------------------------------------------------------------------ */

#ifndef _WIN32
static int system_sh(const char *cmd); /* fwd */
#endif

/* Make a directory, quietly, whatever it takes: the build dirs are scratch
 * space that may or may not exist yet. No cmd.exe involved - every cmd
 * spawn used to cost a process per call. */
#ifdef _WIN32
static void ensure_dir(const char *dir) { CreateDirectoryA(dir, NULL); }
#else
static void ensure_dir(const char *dir) { mkdir(dir, 0755); }
#endif

static char *hphp_dir(void) {
    static char *dir = NULL;
    if (dir) return dir;
    const char *base = getenv("LOCALAPPDATA");
#ifdef _WIN32
    if (!base || !*base) base = getenv("USERPROFILE");
    if (!base || !*base) base = getenv("TEMP");
#else
    if (!base || !*base) base = getenv("XDG_CACHE_HOME");
    if (!base || !*base) base = getenv("HOME");
#endif
    if (base && *base)
        dir = fmt("%s/.hphp", base);
    else
        dir = xstrdup(".hphp");
#ifdef _WIN32
    ensure_dir(dir);
#else
    system_sh(fmt("mkdir -p \"%s\"", dir));
#endif
    return dir;
}

/* Per-invocation scratch directory: fixed short path (no spaces!), reused
 * across runs. Compilation and linking happen from inside it so command
 * lines only ever contain simple relative paths. */
static const char *work_dir(void) {
#ifdef _WIN32
    static const char *wd = "C:/hphpbuild";
    (void)hphp_dir();
    return wd;
#else
    return hphp_dir(); /* POSIX has no space problems */
#endif
}

/* ------------------------------------------------------------------ */
/* command execution                                                   */
/* ------------------------------------------------------------------ */

/* Run one backend command (gcc, ld, ...) directly - no cmd.exe in the
 * middle.
 *
 * cmd.exe used to wrap every call: a process per gcc/ld invocation, quote
 * mangling of the -L"..." paths, and - worst of all - ld crashed with
 * 0xC0000005 (and wrote zero-filled exes) when spawned through cmd from
 * hphp, while the identical command ran fine when started directly.
 * CreateProcess runs the program exactly as given. Returns the exit code,
 * or -1 when the program could not even start. */
static int run_direct(const char *cmdline, bool quiet) {
    int verbose = getenv("HPHP_VERBOSE") != NULL;
    if (verbose) fprintf(stderr, "[hphp backend] %s\n", cmdline);
#ifdef _WIN32
    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    memset(&si, 0, sizeof si);
    si.cb = sizeof si;
    HANDLE nul = INVALID_HANDLE_VALUE;
    BOOL inherit = FALSE;
    if (quiet) {
        nul = CreateFileA("NUL", GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
                          NULL, OPEN_EXISTING, 0, NULL);
        if (nul != INVALID_HANDLE_VALUE) {
            si.dwFlags = STARTF_USESTDHANDLES;
            si.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
            si.hStdOutput = nul;
            si.hStdError = nul;
            inherit = TRUE;
        }
    }
    char *line = xstrdup(cmdline);   /* CreateProcess may write to it */
    if (!CreateProcessA(NULL, line, NULL, NULL, inherit, 0, NULL, NULL, &si, &pi)) {
        free(line);
        if (nul != INVALID_HANDLE_VALUE) CloseHandle(nul);
        if (verbose) fprintf(stderr, "[hphp backend] cannot start (error %lu)\n",
                             (unsigned long)GetLastError());
        return -1;
    }
    free(line);
    CloseHandle(pi.hThread);
    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD code = 1;
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hProcess);
    if (nul != INVALID_HANDLE_VALUE) CloseHandle(nul);
    return (int)code;
#else
    char *q = quiet ? fmt("%s >/dev/null 2>&1", cmdline) : fmt("%s 2>&1", cmdline);
    int rc = system(q);
    free(q);
    return rc;
#endif
}

#ifndef _WIN32
/* Run cmd quietly; output discarded. */
static int system_sh(const char *cmd) {
    int verbose = getenv("HPHP_VERBOSE") != NULL;
    char *q = verbose ? fmt("(%s) 2>&1", cmd) : fmt("(%s) >/dev/null 2>&1", cmd);
    if (verbose) fprintf(stderr, "[hphp backend] %s\n", cmd);
    int rc = system(q);
    free(q);
    return rc;
}
#endif

/* Run several independent commands concurrently and wait for them all.
 * The object compiles are the only multi-second step of a cold build and
 * they share nothing but CPU cores, so running them at once is the single
 * biggest win. Returns 1 only when every command exited 0. */
#ifdef _WIN32
static int run_parallel(char **cmds, int n) {
    int verbose = getenv("HPHP_VERBOSE") != NULL;
    HANDLE procs[16];
    if (n > 16) n = 16;
    for (int i = 0; i < n; i++) {
        procs[i] = NULL;
        char *cmd = cmds[i];
        if (verbose) fprintf(stderr, "[hphp backend] %s\n", cmd);
        /* straight to gcc - no cmd.exe wrapper to pay for or to mangle
         * the paths; output goes to NUL like it always did */
        STARTUPINFOA si;
        PROCESS_INFORMATION pi;
        memset(&si, 0, sizeof si);
        si.cb = sizeof si;
        HANDLE nul = CreateFileA("NUL", GENERIC_WRITE,
                                  FILE_SHARE_READ | FILE_SHARE_WRITE,
                                  NULL, OPEN_EXISTING, 0, NULL);
        BOOL inherit = FALSE;
        if (nul != INVALID_HANDLE_VALUE) {
            si.dwFlags = STARTF_USESTDHANDLES;
            si.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
            si.hStdOutput = nul;
            si.hStdError = nul;
            inherit = TRUE;
        }
        char *line = xstrdup(cmd);
        if (!CreateProcessA(NULL, line, NULL, NULL, inherit, 0, NULL, NULL, &si, &pi)) {
            free(line);
            if (nul != INVALID_HANDLE_VALUE) CloseHandle(nul);
            continue;
        }
        free(line);
        CloseHandle(pi.hThread);
        if (nul != INVALID_HANDLE_VALUE) CloseHandle(nul);
        procs[i] = pi.hProcess;
    }
    int ok = 1;
    for (int i = 0; i < n; i++) {
        if (!procs[i]) { ok = 0; continue; }
        WaitForSingleObject(procs[i], INFINITE);
        DWORD code = 1;
        GetExitCodeProcess(procs[i], &code);
        CloseHandle(procs[i]);
        if (code != 0) ok = 0;
    }
    return ok;
}
#else
static int run_parallel(char **cmds, int n) {
    int verbose = getenv("HPHP_VERBOSE") != NULL;
    pid_t pids[16];
    if (n > 16) n = 16;
    for (int i = 0; i < n; i++) {
        if (verbose) fprintf(stderr, "[hphp backend] %s\n", cmds[i]);
        pid_t pid = fork();
        if (pid == 0) {
            execl("/bin/sh", "sh", "-c", cmds[i], (char *)NULL);
            _exit(127);
        }
        pids[i] = pid;
    }
    int ok = 1;
    for (int i = 0; i < n; i++) {
        if (pids[i] <= 0) { ok = 0; continue; }
        int status = 0;
        while (waitpid(pids[i], &status, 0) < 0) { /* retry on EINTR */ }
        if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) ok = 0;
    }
    return ok;
}
#endif

static int file_nonempty(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fclose(f);
    return sz > 0;
}

/* A "successful" link can still silently produce a corrupt/empty exe when a
 * scanner interferes with freshly written files. Detect a real PE image. */
static int file_looks_like_exe(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    unsigned char sig[2] = {0, 0};
    size_t got = fread(sig, 1, 2, f);
    fclose(f);
    if (got != 2) return 0;
#ifdef _WIN32
    /* PE image (MZ) */
    if (sig[0] != 0x4D || sig[1] != 0x5A) return 0;
#else
    /* ELF image on the POSIX target */
    if (sig[0] != 0x7F || sig[1] != 'E') return 0;
#endif
    return 1;
}

static void remove_quiet(const char *path) { remove(path); }

/* Move src onto dst. On Windows this goes through MoveFileEx with
 * REPLACE_EXISTING: a freshly linked image is prime scanner bait and
 * plain rename() fails outright when a scanner still holds the old file
 * open. The retry loop gives the scanner a moment to let go. */
static int move_file(const char *src, const char *dst) {
#ifdef _WIN32
    for (int attempt = 0; attempt < 5; attempt++) {
        if (MoveFileExA(src, dst,
                        MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
            return 0;
        DWORD err = GetLastError();
        if (err != ERROR_SHARING_VIOLATION && err != ERROR_ACCESS_DENIED)
            break;
        nap_ms(100 * (attempt + 1));   /* the scanner is still looking */
    }
    /* fall through to the copy path below */
#else
    remove_quiet(dst);
    if (rename(src, dst) == 0) return 0;
#endif
    /* cross-device fallback: copy */
    remove_quiet(dst);
    FILE *a = fopen(src, "rb"), *b = fopen(dst, "wb");
    if (!a || !b) { if (a) fclose(a); if (b) fclose(b); return -1; }
    char buf[65536];
    size_t n;
    while ((n = fread(buf, 1, sizeof buf, a)) > 0) fwrite(buf, 1, n, b);
    fclose(a);
    if (fclose(b) != 0) return -1;
#ifndef _WIN32
    /* a fresh copy is not executable; restore the mode the linker gave src */
    struct stat st;
    if (stat(src, &st) == 0)
        chmod(dst, st.st_mode | S_IXUSR | S_IXGRP | S_IXOTH);
#endif
    remove_quiet(src);
    return 0;
}

/* First line of `gcc -print-file-name=...` (or -print-libgcc-file-name etc). */
static char *gcc_query(const char *args) {
#ifdef _WIN32
    /* straight to gcc with a captured pipe - popen would spawn cmd.exe,
     * which costs a process per query and was the flaky middle layer */
    SECURITY_ATTRIBUTES sa;
    memset(&sa, 0, sizeof sa);
    sa.nLength = sizeof sa;
    sa.bInheritHandle = TRUE;
    HANDLE rd = NULL, wr = NULL;
    if (!CreatePipe(&rd, &wr, &sa, 0)) return xstrdup("");
    SetHandleInformation(rd, HANDLE_FLAG_INHERIT, 0);  /* keep the read end */
    STARTUPINFOA si;
    memset(&si, 0, sizeof si);
    si.cb = sizeof si;
    si.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;
    si.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
    si.hStdOutput = wr;
    si.hStdError = GetStdHandle(STD_ERROR_HANDLE);
    PROCESS_INFORMATION pi;
    char *line = fmt("gcc %s", args);
    if (!CreateProcessA(NULL, line, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi)) {
        free(line);
        CloseHandle(rd);
        CloseHandle(wr);
        return xstrdup("");
    }
    free(line);
    CloseHandle(wr);
    char buf[1024] = {0};
    DWORD got = 0, have = 0;
    while (have < sizeof buf - 1 &&
           ReadFile(rd, buf + have, (DWORD)(sizeof buf - 1 - have), &got, NULL) && got)
        have += got;
    CloseHandle(rd);
    WaitForSingleObject(pi.hProcess, INFINITE);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    buf[have] = 0;
    for (DWORD i = 0; i < have; i++)
        if (buf[i] == '\n' || buf[i] == '\r') { buf[i] = 0; break; }
    return xstrdup(buf);
#else
    char *cmd = fmt("(gcc %s) 2>/dev/null", args);
    FILE *p = popen(cmd, "r");
    free(cmd);
    if (!p) return xstrdup("");
    char buf[1024] = {0};
    if (!fgets(buf, sizeof buf, p)) buf[0] = 0;
    pclose(p);
    size_t n = strlen(buf);
    while (n && (buf[n - 1] == '\n' || buf[n - 1] == '\r')) buf[--n] = 0;
    return xstrdup(buf);
#endif
}

/* Directory part of a path. Returns a heap copy so two calls can be alive
 * at the same time — a shared static buffer silently made the second call
 * clobber the first. */
static char *path_dir_of(const char *p) {
    const char *slash = strrchr(p, '/'), *bslash = strrchr(p, '\\');
    const char *cut = slash > bslash ? slash : bslash;
    if (!cut) return xstrdup(".");
    return xstrndup(p, (size_t)(cut - p));
}

/* ------------------------------------------------------------------ */
/* embedded runtime: hphp.exe carries its own standard runtime         */
/* ------------------------------------------------------------------ */

/* Locate this very executable (argv[0] can be relative or bare). */
static char *find_compiler(const char *argv0) {
#ifdef _WIN32
    char *buf = xmalloc(4096);
    DWORD n = GetModuleFileNameA(NULL, buf, 4096);
    if (n > 0 && n < 4096) return buf;
    free(buf);
#endif
    if (strchr(argv0, '/') || strchr(argv0, '\\')) return xstrdup(argv0);
    /* bare name: search PATH */
    const char *pathenv = getenv("PATH");
    if (pathenv) {
        char *paths = xstrdup(pathenv);
        for (char *tok = strtok(paths, ";:"); tok; tok = strtok(NULL, ";:")) {
#ifdef _WIN32
            char *cand = fmt("%s/%s.exe", tok, argv0);
#else
            char *cand = fmt("%s/%s", tok, argv0);
#endif
            FILE *f = fopen(cand, "rb");
            if (f) { fclose(f); return cand; }
        }
    }
    return xstrdup(argv0);
}

/* runtime/<file> next to the compiler binary, or the embedded copy */
static char *runtime_path(const char *self, const char *file) {
    char *dir = path_dir_of(self);
    char *p = fmt("%s/runtime/%s", dir, file);
    free(dir);
    FILE *f = fopen(p, "rb");
    if (f) { fclose(f); return p; }
    return NULL; /* fall back to the embedded copy */
}

static char *embed_read(const char *self, const char *file) {
    char *p = runtime_path(self, file);
    if (p) return read_file_or_die(p);
    if (strcmp(file, "hphp_rt.c") == 0) return xstrdup(hp_embed_rt_c);
    if (strcmp(file, "hphp_std.c") == 0) return xstrdup(hp_embed_std_c);
    if (strcmp(file, "hphp_thr.c") == 0) return xstrdup(hp_embed_thr_c);
    if (strcmp(file, "hphp_ui.c") == 0) return xstrdup(hp_embed_ui_c);
    if (strcmp(file, "hphp_wv2.c") == 0) return xstrdup(hp_embed_wv2_c);
    if (strcmp(file, "hphp_rt.h") == 0) return xstrdup(hp_embed_rt_h);
    fatal("hphp: unknown runtime file '%s'", file);
    return NULL;
}

static void mkdir_p(const char *dir) {
#ifdef _WIN32
    ensure_dir(dir);
#else
    system_sh(fmt("mkdir -p \"%s\"", dir));
#endif
}

/* Write the three runtime files into <wd>/rt. Overwrite unconditionally so
 * the runtime always matches the compiler version. */
static void extract_runtime(const char *wd, const char *self) {
    static const char *files[] = {"hphp_rt.c", "hphp_std.c", "hphp_thr.c", "hphp_ui.c",
                                  "hphp_wv2.c", "hphp_rt.h"};
    mkdir_p(wd);
    char *rtdir = path_join(wd, "rt");
    mkdir_p(rtdir);
    for (int i = 0; i < 6; i++) {
        char *data = embed_read(self, files[i]);
        char *dest = fmt("%s/%s", rtdir, files[i]);
        FILE *f = fopen(dest, "wb");
        if (!f) fatal("hphp: cannot write runtime to build dir (%s)", dest);
        fwrite(data, 1, strlen(data), f);
        fclose(f);
        free(dest);
        free(data);
    }
}

/* ------------------------------------------------------------------ */
/* backend: compile + link inside the work dir                         */
/* ------------------------------------------------------------------ */

/* A per-run tag for the temporary build files. The build dir is shared by
 * every hphp on the machine, so two runs at the same time (a script that
 * compiles two programs, an editor running a build task) must not write
 * over each other's objects. */
static void build_tag(char *buf, size_t n) {
#ifdef _WIN32
    unsigned long pid = (unsigned long)GetCurrentProcessId();
#else
    unsigned long pid = (unsigned long)getpid();
#endif
    unsigned long r = (unsigned long)clock() ^ (pid * 2654435761UL);
    r = (r * 1103515245UL + 12345UL) & 0xFFFFFF;
    snprintf(buf, n, "%lx%lx", pid, r);
}

/* Remove this run's temporary build files. They all carry the per-run tag,
 * so nothing else can be using them. HPHP_KEEP_C=1 keeps the generated C
 * (prog_<tag>.c) so it can be read after the build. */
static void cleanup_build_files(const char *wd, const char *tag) {
    static const char *base[6] = {"prog", "hp_rt", "hp_std", "hp_thr", "hp_ui", "hp_wv2"};
    char path[1024];
    for (int i = 0; i < 6; i++) {
        snprintf(path, sizeof path, "%s/%s_%s.o", wd, base[i], tag);
        remove_quiet(path);
    }
    snprintf(path, sizeof path, "%s/prog_%s.c", wd, tag);
    if (!getenv("HPHP_KEEP_C")) remove_quiet(path);
    snprintf(path, sizeof path, "%s/prog_%s.out", wd, tag);
    remove_quiet(path);
}

/* Compile the C inputs in wd (relative paths only) and link them to
 * <wd>/prog-<tag>.out, then move the finished image to exepath. Never links
 * directly onto exepath — freshly-written exes are scanner bait; the final
 * rename is atomic-ish and safe. */
/* The whole file as a NUL-terminated string, or NULL when it cannot be
 * read. Used to see which runtime modules the generated code mentions. */
static char *read_file_string(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return NULL; }
    long len = ftell(f);
    if (len < 0) { fclose(f); return NULL; }
    fseek(f, 0, SEEK_SET);
    char *buf = malloc((size_t)len + 1);
    if (!buf) { fclose(f); return NULL; }
    size_t n = fread(buf, 1, (size_t)len, f);
    buf[n] = 0;
    fclose(f);
    return buf;
}

static int cc_build_in_dir(const char *wd, const char *rt, const char *cpath,
                           const char *exepath, bool gui, const char *cache_key,
                           const char *rt_key, bool dev, const char *tag) {
#ifdef _WIN32
    /* A desktop program that opens a console window is a bug the user sees
     * every single launch. -mwindows links against the GUI subsystem, so the
     * process has no console to leave behind. */
    const char *subsys = gui ? "-mwindows " : "";
#else
    const char *subsys = "";
    (void)gui;
#endif
    /* Cache slots keep stable names (the cache is keyed by source hash, not
     * by run), while the files on disk carry the per-run tag so parallel
     * hphp processes never collide. */
    const char *objbase[6] = {"prog", "hp_rt", "hp_std", "hp_thr", "hp_ui", "hp_wv2"};
    char objnames[6][64];   /* cache names:  prog.o, hp_rt.o, ... */
    char objs[6][64];       /* on-disk names: prog_<tag>.o, ... */
    for (int i = 0; i < 6; i++) {
        snprintf(objnames[i], sizeof objnames[i], "%s.o", objbase[i]);
        snprintf(objs[i], sizeof objs[i], "%s_%s.o", objbase[i], tag);
    }
    char csrc[64];
    snprintf(csrc, sizeof csrc, "prog_%s.c", tag);
    char out[64];
    snprintf(out, sizeof out, "prog_%s.out", tag);
    char *out_abs = path_join(wd, out);
    int verbose = getenv("HPHP_VERBOSE") != NULL;
    (void)rt;
    /* HPHP_CFLAGS is a debugging aid (sanitizers, coverage); it is appended
     * to the optimisation flag the backend already uses. */
    const char *extra = getenv("HPHP_CFLAGS");
    /* Release builds can select target-specific optimization flags without
     * changing HolyPHP source semantics. Keep -O2 as the portable default;
     * the challenge box can opt into native CPU tuning and LTO at build time. */
    const char *release_opt = getenv("HPHP_OPT");
    const char *opt = dev ? "-O0" :
                      (release_opt && *release_opt ? release_opt : "-O2");
    char optbuf[512];
    if (extra && *extra) {
        snprintf(optbuf, sizeof optbuf, "%s %s", opt, extra);
        opt = optbuf;
    }

    /* ---- which runtime modules this program actually uses ----
     * hp_rt and hp_std are the base and always come along. Thread, UI and
     * WebView are their own TUs, so a symbol prefix in the generated code is
     * what pulls them in - and so is a prefix in hphp_std.c itself, which
     * carries the UI and WebView builtins as thin wrappers over hpui_* and
     * hpwv2_*. The base is linked into every program, so those references are
     * there whatever the program does: scanning only the generated code left
     * every hello world with an undefined hpui_dispatch at link time. */
    bool needed[6] = {true, true, true, false, false, false};
    {
        char *genc = read_file_string(cpath);
        const char *stdc = hp_embed_std_c ? hp_embed_std_c : "";
        if (!genc) {
            needed[3] = needed[4] = needed[5] = true;   /* cannot tell: all */
        } else {
            needed[3] = strstr(genc, "hp_thr_") != NULL || strstr(stdc, "hp_thr_") != NULL;
            needed[4] = strstr(genc, "hp_ui_") != NULL || strstr(genc, "hpui_") != NULL ||
                        strstr(stdc, "hp_ui_") != NULL || strstr(stdc, "hpui_") != NULL;
            needed[5] = strstr(genc, "hp_wv2_") != NULL || strstr(genc, "hpwv2_") != NULL ||
                        strstr(stdc, "hp_wv2_") != NULL || strstr(stdc, "hpwv2_") != NULL;
            free(genc);
        }
    }

    /* ---- incremental cache: two levels ----
     * The runtime objects are the same for every program, so they live in
     * their own slot keyed by the runtime sources and the toolchain alone -
     * a new program does not pay for compiling them again. Only this
     * program's own object and its linked image are under the program key. */
    bool use_cache = cache_key && cache_key[0];
    bool have[6] = {false};
    if (use_cache) {
        if (rt_key && rt_key[0]) {
            for (int i = 1; i < 6; i++) {
                if (!needed[i]) continue;
                if (!cache_has_object(rt_key, objnames[i])) continue;
                char *dest = path_join(wd, objs[i]);
                have[i] = cache_get_object(rt_key, objnames[i], dest);
                free(dest);
            }
        }
        if (cache_has_object(cache_key, objnames[0])) {
            char *dest = path_join(wd, objs[0]);
            have[0] = cache_get_object(cache_key, objnames[0], dest);
            free(dest);
        }
        if (verbose) fprintf(stderr, "[hphp backend] cache: prog.o=%d rt=[%d%d%d%d%d]\n",
                             (int)have[0], (int)have[1], (int)have[2],
                             (int)have[3], (int)have[4], (int)have[5]);
    }
    bool all_cached = use_cache;
    for (int i = 0; i < 6; i++)
        if (needed[i] && !have[i]) all_cached = false;
    if (all_cached && verbose) fprintf(stderr, "[hphp backend] cache hit: all objects restored, skipping compile\n");

    /* work from inside wd so command lines stay short and quote-free */
#ifdef _WIN32
    char prev[1024] = {0};
    GetCurrentDirectoryA(sizeof prev, prev);
    if (!SetCurrentDirectoryA(wd)) {
        fprintf(stderr, "hphp: cannot enter build dir %s\n", wd);
        return -1;
    }
#else
    char *prev = getcwd(NULL, 0);
    if (chdir(wd) != 0) {
        fprintf(stderr, "hphp: cannot enter build dir %s\n", wd);
        return -1;
    }
#endif

    for (int attempt = 1; attempt <= 3; attempt++) {
        /* --- compile the objects (skip if fully cached) --- */
        bool compiled = true;
        const char *srcs[6] = {csrc, "rt/hphp_rt.c", "rt/hphp_std.c",
                               "rt/hphp_thr.c", "rt/hphp_ui.c", "rt/hphp_wv2.c"};
        if (!all_cached) {
        /* compile only the objects that are missing (and wanted at all) */
        char *ccmds[6];
        int cidx[6];
        int ncmd = 0;
        for (int i = 0; i < 6; i++) {
            if (!needed[i] || have[i]) continue;
            ccmds[ncmd] = fmt("gcc %s -std=c11 -I rt -c %s -o %s", opt, srcs[i], objs[i]);
            cidx[ncmd] = i;
            ncmd++;
        }
        if (!run_parallel(ccmds, ncmd)) {
            /* a concurrent compiler failure is often a transient exe-lock;
             * the outer retry loop sleeps and tries again */
            compiled = false;
        }
        for (int j = 0; j < ncmd; j++) {
            int i = cidx[j];
            free(ccmds[j]);
            if (!compiled) continue;
            char *objp = path_join(wd, objs[i]);
            if (!file_nonempty(objp)) {
                fprintf(stderr,
                        "hphp: internal error: cannot compile %s "
                        "(set HPHP_VERBOSE=1 for details)\n", srcs[i]);
                compiled = false;
            }
            free(objp);
        }
        /* freshly compiled objects: runtime ones go in the shared slot,
         * this program's own object in the program slot */
        if (compiled && use_cache) {
            for (int j = 0; j < ncmd; j++) {
                int i = cidx[j];
                const char *slot = (i == 0) ? cache_key : rt_key;
                if (!slot || !slot[0]) continue;
                char *srcp = path_join(wd, objs[i]);
                cache_put_object(slot, objnames[i], srcp);
                free(srcp);
            }
        }
        }
        if (!compiled) { nap_ms(300 * attempt); continue; }

        /* --- linked-image cache: skip the link when we already have it --- */
        if (use_cache && cache_has_exe(cache_key)) {
            char *cached = path_join(wd, out);
            if (cache_get_exe(cache_key, cached) && file_looks_like_exe(cached)) {
                if (verbose) fprintf(stderr, "[hphp backend] cache hit: linked image restored, skipping link\n");
#ifdef _WIN32
                SetCurrentDirectoryA(prev);
#else
                chdir(prev);
#endif
                remove_quiet(exepath);
                if (move_file(cached, exepath) == 0 && file_looks_like_exe(exepath)) {
                    free(cached);
                    cleanup_build_files(wd, tag);
                    return 0;
                }
            }
            free(cached);
        }

        /* --- link: mingw ld directly, plain gcc as fallback --- */
        /* only the modules that were actually built go to the linker */
        char objlist[512] = "";
        for (int i = 0; i < 6; i++) {
            if (!needed[i]) continue;
            if (objlist[0]) strcat(objlist, " ");
            strcat(objlist, objs[i]);
        }
        char *crt2 = gcc_query("-print-file-name=crt2.o");
        bool have_ld = crt2[0] && strchr(crt2, '/') != NULL;
        int rc = -1;
        /* The direct-ld path cannot honour -mwindows: that is a gcc driver
           switch which also picks the GUI start-up object, and bare ld has no
           idea which of main/WinMain the program actually defines. So a GUI
           build goes through the gcc driver instead. */
        if (have_ld && !gui) {
            char *libgcc = gcc_query("-print-libgcc-file-name");
            char *crtbegin = gcc_query("-print-file-name=crtbegin.o");
            char *crtend = gcc_query("-print-file-name=crtend.o");
            char *manifest = gcc_query("-print-file-name=default-manifest.o");
            char *ld = gcc_query("-print-prog-name=ld");
            /* HPHP_LD points at a different linker (e.g. ld.bfd) - an escape
             * hatch when security software interferes with the default one */
            const char *ldenv = getenv("HPHP_LD");
            if (ldenv && *ldenv) { free(ld); ld = xstrdup(ldenv); }
            char *gccdir = path_dir_of(libgcc);
            char *crtdir = path_dir_of(crt2);
            char *link = fmt(
                "\"%s\" -m i386pep -Bdynamic -o %s %s %s "
                "-L\"%s\" -L\"%s\" %s "
                "-lmingw32 -lgcc -lgcc_eh -lmingwex -lmsvcrt -lkernel32 "
                "-lws2_32 -lpthread -ladvapi32 -lshell32 -luser32 "
                "-lgdi32 -lgdiplus -lcomctl32 -lcomdlg32 -lole32 -loleaut32 -luuid "
                "-lversion -lshlwapi -lwinmm \"%s\" \"%s\"",
                ld, out, crt2, crtbegin, gccdir, crtdir, objlist,
                manifest, crtend);
            rc = run_direct(link, !verbose);
            if (verbose) fprintf(stderr, "[hphp backend] direct-ld rc=%d nonempty=%d exe=%d\n",
                                  rc, (int)file_nonempty(out_abs),
                                  (int)file_looks_like_exe(out_abs));
            free(link);
            free(gccdir);
            free(crtdir);
        }
        if (rc != 0 || !file_nonempty(out_abs)) {
#ifdef _WIN32
            char *link = fmt("gcc %s %s %s -o %s -lm -lws2_32 "
                             "-lgdi32 -lgdiplus -lcomctl32 -lcomdlg32 -lole32 -loleaut32 "
                             "-luuid -lversion -lshlwapi -lwinmm",
                             opt, subsys, objlist, out);
#else
            /* POSIX: sockets live in libc, the UI layer is inert stubs.
             * HPHP_SQLITE_LIB points at a static SQLite built by build.sh
             * (THREADSAFE=0); without it the system library is used. */
            const char *slib = getenv("HPHP_SQLITE_LIB");
            char *link = (slib && *slib)
                ? fmt("gcc %s %s -o %s -lm -lpthread %s", opt, objlist, out, slib)
                : fmt("gcc %s %s -o %s -lm -lpthread -lsqlite3", opt, objlist, out);
#endif
            rc = run_direct(link, !verbose);
            if (verbose) fprintf(stderr, "[hphp backend] gcc-fallback rc=%d nonempty=%d exe=%d\n",
                                  rc, (int)file_nonempty(out_abs),
                                  (int)file_looks_like_exe(out_abs));
            free(link);
        }
        if (rc == 0 && file_looks_like_exe(out_abs)) {
            /* keep the linked image so the next run can skip the link too */
            if (use_cache) cache_put_exe(cache_key, out_abs);
#ifdef _WIN32
            SetCurrentDirectoryA(prev);
#else
            chdir(prev);
#endif
            /* link finished in wd; place the finished image at exepath */
            if (verbose) fprintf(stderr, "[hphp backend] moving %s -> %s\n", out, exepath);
            remove_quiet(exepath);
            if (move_file(out_abs, exepath) == 0 && file_looks_like_exe(exepath)) {
                cleanup_build_files(wd, tag);
                return 0;
            }
            fprintf(stderr, "hphp: cannot place executable at %s\n", exepath);
            cleanup_build_files(wd, tag);
            return -1;
        }
        fprintf(stderr, "hphp: backend link attempt %d failed (output %s)\n",
                attempt, file_looks_like_exe(out_abs) ? "ok" : "invalid/missing");
        remove_quiet(out_abs);
        nap_ms(500 * attempt);
    }
#ifdef _WIN32
    SetCurrentDirectoryA(prev);
#else
    chdir(prev);
#endif
    cleanup_build_files(wd, tag);
    return -1;
}

/* Spawn exepath with an inherited console and wait; returns its exit code. */
static int spawn_wait(const char *exepath, PtrVec args) {
#ifdef _WIN32
    STARTUPINFOA si = {0};
    PROCESS_INFORMATION pi = {0};
    si.cb = sizeof si;
    Buf cmdline;
    buf_init(&cmdline);
    buf_printf(&cmdline, "\"%s\"", exepath);
    for (size_t i = 0; i < args.len; i++)
        buf_printf(&cmdline, " \"%s\"", (const char *)args.items[i]);
    if (!CreateProcessA(NULL, cmdline.data, NULL, NULL, TRUE, 0, NULL, NULL,
                        &si, &pi))
        return -1;
    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD code = 1;
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return (int)code;
#else
    Buf cmdline;
    buf_init(&cmdline);
    buf_printf(&cmdline, "\"%s\"", exepath);
    for (size_t i = 0; i < args.len; i++)
        buf_printf(&cmdline, " \"%s\"", (const char *)args.items[i]);
    int rc = system(cmdline.data);
    free(cmdline.data);
    return rc;
#endif
}

/* ------------------------------------------------------------------ */
/* multi-file loading                                                  */
/* ------------------------------------------------------------------ */

typedef struct LoadCtx {
    PtrVec programs;   /* Program* in import order (deps first) */
    PtrVec visited;    /* const char* absolute-ish paths */
} LoadCtx;

/* the search path, in order: project libraries, the bundled std, the
 * importing file's own directory, $HPHP_PATH, then libraries compiled into
 * the hphp binary (so an installed compiler still has its stdlib). */
static Program *load_source_recursive(LoadCtx *ctx, const char *path, const char *src);
static bool load_once(LoadCtx *ctx, const char *path, const char *src);

/* The name a spec has inside lib/. A library is a package folder, so a bare
 * "ui" names that package's entry ("ui/ui.hphp"), while a spec that already
 * names a part ("html/dom.hphp") is used as it is. */
static char *lib_rel_spec(const char *spec) {
    const char *slash = strrchr(spec, '/');
    const char *bslash = strrchr(spec, '\\');
    const char *cut = slash > bslash ? slash : bslash;
    if (cut) return xstrdup(spec);
    size_t n = strlen(spec);
    if (n > 5 && !strcmp(spec + n - 5, ".hphp")) n -= 5;
    char *stem = xstrndup(spec, n);
    char *rel = fmt("%s/%s", stem, spec);
    free(stem);
    return rel;
}

/* Bundled libraries are named by their path inside lib/ (see genembed.c). */
static bool lib_name_matches(const char *spec, const char *name) {
    char *rel = lib_rel_spec(spec);
    bool hit = strcmp(rel, name) == 0;
    free(rel);
    return hit;
}

/* A script run from a subdirectory (say `examples/foo.hphp`) must still find
 * its own project's lib/. The plain `lib/<name>` candidate is relative to the
 * CURRENT directory, so from anywhere but the project root that lookup misses,
 * the search falls through to an installed package of the same name, and a
 * stale copy silently outranks the bundled library. Walk up from the importing
 * file toward the filesystem root and take the first lib/<name> found. */
static char *abs_dir_of(const char *dir) {
    if (dir && (dir[0] == '/' || dir[0] == '\\' ||
                (dir[0] && dir[1] == ':'))) return xstrdup(dir);
    char cwd[1024];
#ifdef _WIN32
    if (!_getcwd(cwd, sizeof cwd)) snprintf(cwd, sizeof cwd, ".");
#else
    if (!getcwd(cwd, sizeof cwd)) snprintf(cwd, sizeof cwd, ".");
#endif
    if (!dir || !dir[0] || strcmp(dir, ".") == 0) return xstrdup(cwd);
    return fmt("%s/%s", cwd, dir);
}

/* Load a file once, or nothing when it is already in the program.
 *
 * Two libraries that both import a third is the normal shape of a
 * dependency graph, not an error: the second import has nothing left to
 * do, and reporting "cannot import" for it was what made `import "ide"`
 * fail as soon as anything else had pulled in the editor. */
static bool load_once(LoadCtx *ctx, const char *path, const char *src) {
    const char *ipath = intern(path);
    for (size_t i = 0; i < ctx->visited.len; i++)
        if (ctx->visited.items[i] == ipath) return true;
    load_source_recursive(ctx, path, src);
    return true;
}

/* Try one candidate path: true when the file is there and (now) loaded. */
static bool load_candidate(LoadCtx *ctx, const char *path) {
    char *src = read_file_soft(path);
    if (!src) return false;
    return load_once(ctx, path, src);
}

static bool upwards_lib(LoadCtx *ctx, const char *start_dir, const char *spec) {
    char *full = abs_dir_of(start_dir);
    char *dir = xstrdup(full);
    free(full);
    size_t n = strlen(dir);
    while (n > 1 && (dir[n - 1] == '/' || dir[n - 1] == '\\')) dir[--n] = 0;
    bool hit = false;
    for (int depth = 0; depth < 12; depth++) {
        char *cand = fmt("%s/lib/%s", dir, spec);
        if (load_candidate(ctx, cand)) { hit = true; break; }
        /* a library is a package folder: lib/ui/ui.hphp, lib/html/dom.hphp */
        char *rel = lib_rel_spec(spec);
        char *pkg = fmt("%s/lib/%s", dir, rel);
        free(rel);
        if (load_candidate(ctx, pkg)) { hit = true; break; }
        char *slash = strrchr(dir, '/');
        char *bslash = strrchr(dir, '\\');
        char *cut = slash > bslash ? slash : bslash;
        if (!cut || cut == dir) break;
        *cut = 0;
    }
    free(dir);
    return hit;
}

static bool load_import(LoadCtx *ctx, const char *importer, const char *spec) {
    /* convention: an import spec without an extension names a library or
     * package ("websocket"), not a source file - resolve it to "<spec>.hphp"
     * everywhere (lib/, std/, installed packages, importer's directory, and
     * $HPHP_PATH). Explicit "websocket.hphp" keeps meaning "this exact file". */
    char *norm = NULL;
    {
        size_t sl = strlen(spec);
        const char *dot = strrchr(spec, '.');
        const char *sep = strrchr(spec, '/');
        bool has_ext = dot && (!sep || dot > sep);
        if (!has_ext) {
            norm = fmt("%s.hphp", spec);
            spec = norm;
        }
    }
    bool relative = spec[0] == '.' || spec[0] == '/' || spec[0] == '\\';
    if (relative) {
        char *idir = path_dir_of(importer);
        char *cand = fmt("%s/%s", idir, spec);
        free(idir);
        if (load_candidate(ctx, cand)) return true;
    } else {
        /* 1. lib/<name> relative to the cwd   2. the importing file's own
         * project, searched upward   3. src/hphpc/std/<name>
         * 4. next to the importer   5. installed packages */
        char *cwd_lib = fmt("lib/%s", spec);
        if (load_candidate(ctx, cwd_lib)) return true;
        char *rel = lib_rel_spec(spec);
        char *cwd_pkg = fmt("lib/%s", rel);
        free(rel);
        if (load_candidate(ctx, cwd_pkg)) return true;
        char *idir = path_dir_of(importer);
        if (upwards_lib(ctx, idir, spec)) { free(idir); return true; }
        char *cands[3];
        cands[0] = fmt("src/hphpc/std/%s", spec);
        cands[1] = fmt("%s/%s", idir, spec);
        cands[2] = pkg_import_candidate(spec);   /* installed packages */
        free(idir);
        for (int i = 0; i < 3; i++) {
            if (load_candidate(ctx, cands[i])) return true;
        }
        /* 4. $HPHP_PATH (; or : separated), like PHP's include_path */
        const char *path = getenv("HPHP_PATH");
        if (path) {
            char *copy = xstrndup(path, strlen(path));
            for (char *p = copy, *nxt = copy; p && *p; p = nxt) {
                nxt = strpbrk(p, ";:");
                if (nxt) *nxt++ = 0;
                if (!*p) continue;
                char *cand = fmt("%s/%s", p, spec);
                if (load_candidate(ctx, cand)) return true;
            }
        }
    }
    /* 5. a library shipped inside the compiler binary */
    for (size_t i = 0; i < hp_embed_libs_len; i++) {
        if (lib_name_matches(spec, hp_embed_libs[i].name)) {
            char *disp = fmt("<hphp-lib>/%s", hp_embed_libs[i].name);
            return load_once(ctx, disp, hp_embed_libs[i].src);
        }
    }
    return false;
}

static Program *load_source_recursive(LoadCtx *ctx, const char *path, const char *src) {
    const char *ipath = intern(path);
    for (size_t i = 0; i < ctx->visited.len; i++)
        if (ctx->visited.items[i] == ipath) return NULL;   /* see load_once */

    Program *prog = parse_program(src, path);
    ptrvec_push(&ctx->visited, (void *)ipath);

    /* imports first (depth-first, deps before user code) */
    for (size_t i = 0; i < prog->imports.len; i++) {
        Import *im = prog->imports.items[i];
        if (!load_import(ctx, path, im->path)) {
            char *dir = path_dir_of(path);
            fatal("%s: cannot import \"%s\"\n"
                  "  searched: lib/, src/hphpc/std/, %s/, installed packages, $HPHP_PATH, built-in libraries",
                  path, im->path, dir);
        }
    }
    ptrvec_push(&ctx->programs, prog);
    return prog;
}

static Program *load_file_recursive(LoadCtx *ctx, const char *path) {
    return load_source_recursive(ctx, path, read_file_or_die(path));
}

static void collect_source_files(PtrVec *out, LoadCtx *ctx, const char *root_file){ ptrvec_push(out,(void*)root_file); for(size_t i=0;i<ctx->programs.len;i++){ Program *p=ctx->programs.items[i]; if(p->file) ptrvec_push(out,(void*)p->file); } }

static void merge_programs(Program *out, PtrVec progs) {
    for (size_t i = 0; i < progs.len; i++) {
        Program *p = progs.items[i];
        for (size_t k = 0; k < p->decls.len; k++)
            ptrvec_push(&out->decls, p->decls.items[k]);
        /* top-level statements only from the root file (last one) */
    }
}

/* ------------------------------------------------------------------ */
/* package manager: hphp pkg <command>                                 */
/* ------------------------------------------------------------------ */

static int  do_check_file(const char *path);
static bool rm_rf_path(const char *path);   /* wrapper over pkgcore helper */

#define rm_rf rm_rf_path

#ifdef _WIN32
#include <direct.h>
#endif
static void pkg_read_manifest_of(const char *dir, PkgManifest *m) {
    char *mf = fmt("%s/" PKG_MANIFEST, dir);
    char *js = read_file_soft(mf);
    if (!js) fatal("%s: missing " PKG_MANIFEST, dir);
    *m = pkg_manifest_parse(js, dir);
    free(js); free(mf);
}

/* Pack the current project (or --dir) into <name>-<version>.hpx in cache/. */
static int pkg_cmd_pack(int argc, char **argv) {
    const char *dir = ".";
    for (int i = 0; i < argc; i++)
        if (!strcmp(argv[i], "--dir") && i + 1 < argc) dir = argv[++i];
    PkgManifest m;
    pkg_read_manifest_of(dir, &m);
    char *cache = pkg_home_file("cache");
    mkdir_p(cache);
    char *out = fmt("%s/%s-%s.hpx", cache, m.name, m.version);
    pkg_pack_dir(dir, out);
    printf("packed %s (%s %s) -> %s\n", dir, m.name, m.version, out);
    return 0;
}

/* Install from a local .hpx file (no network needed). */
static int pkg_install_file(const char *hpx_path) {
    /* peek the manifest: extract to a temp pkg dir then read it */
    char *tmp = pkg_home_file("cache/.tmp-install");
    pkg_extract(hpx_path, tmp);
    PkgManifest m;
    pkg_read_manifest_of(tmp, &m);
    char *destdir = pkg_dir_of(m.name);
    rm_rf(destdir);
    mkdir_p(destdir);
    if (pkg_extract(hpx_path, destdir) <= 0)
        fatal("%s: empty package", hpx_path);
    /* sanity: entry must exist */
    char *entry = fmt("%s/%s", destdir, m.entry);
    if (!read_file_soft(entry))
        fatal("%s: package entry \"%s\" missing (rename it or set \"entry\" in hphp.json)",
              m.name, m.entry);
    pkg_registry_add(m.name, m.version);
    printf("installed %s %s -> %s\n", m.name, m.version, destdir);
    printf("import it with:  import \"%s\";\n", m.name);
    return 0;
}

/* Install from the registry over HTTP. */
static char *pkg_registry_url_or_default(void) {
    /* effective registry URL: $HPHP_REGISTRY, then the registry_url file,
     * then the public default */
    const char *env = getenv("HPHP_REGISTRY");
    if (env && *env) return xstrdup(env);
    char *from_file = pkg_registry_url();
    if (from_file) return from_file;
    return xstrdup(PKG_DEFAULT_REGISTRY);
}

static int pkg_install_registry(const char *name) {
    char *base = pkg_registry_url_or_default();
    char *url = fmt("%s/pkg/%s", base, name);
    size_t n;
    int status = 0;
    char *body = pkgnet_get(url, &n, &status);
    if (!body) return 2;   /* unreachable — caller may fall back */
    if (status == 404) {
        fprintf(stderr, "package not found on registry: %s\n", name);
        return 2;
    }
    if (status != 200) {
        fprintf(stderr, "registry error %d for %s\n", status, name);
        return 2;
    }
    /* save to cache, then install from the file */
    char *cache = pkg_home_file("cache");
    mkdir_p(cache);
    char *out = fmt("%s/%s.hpx", cache, name);
    FILE *f = fopen(out, "wb");
    if (!f) fatal("cannot write %s", out);
    fwrite(body, 1, n, f);
    fclose(f);
    free(body);
    return pkg_install_file(out);
}

/* Install a library that ships inside the hphp binary itself (the package
 * folders under lib/ are compiled into the compiler at build time). Used as
 * an offline fallback when the registry is unreachable — the toolchain is
 * self-contained like `go`. A library is a folder, so every embedded part of
 * it is staged, not just the entry file. Returns 0 on success, 1 when the
 * name is not a bundled library. */
static int pkg_install_embedded(const char *name) {
    /* normalize "websocket.hphp" -> "websocket" */
    char stem[128];
    snprintf(stem, sizeof stem, "%s", name);
    size_t sl = strlen(stem);
    if (sl > 5 && !strcmp(stem + sl - 5, ".hphp")) stem[sl - 5] = 0;
    size_t plen = strlen(stem);

    /* embedded names are lib-relative: the entry of `ui` is ui/ui.hphp */
    char *entry = fmt("%s/%s.hphp", stem, stem);
    bool known = false;
    for (size_t i = 0; i < hp_embed_libs_len; i++) {
        if (strcmp(hp_embed_libs[i].name, entry) == 0) { known = true; break; }
    }
    free(entry);
    if (!known) return 1;

    /* stage the sources into a temp dir, then pack it into a real .hpx so
     * the installed layout is identical to a registry install */
    {
        char *stage = pkg_home_file("cache/.embedded");
        FILE *f;
        rm_rf(stage);
        mkdir_p(stage);
        for (size_t i = 0; i < hp_embed_libs_len; i++) {
            const char *ln = hp_embed_libs[i].name;
            if (strncmp(ln, stem, plen) != 0 || ln[plen] != '/') continue;
            const char *rest = ln + plen + 1;
            char *dst = fmt("%s/%s", stage, rest);
            char *dir = xstrdup(dst);
            char *cut = strrchr(dir, '/');
            if (cut) { *cut = 0; mkdir_p(dir); }
            free(dir);
            f = fopen(dst, "wb");
            if (!f) fatal("cannot write %s", dst);
            fputs(hp_embed_libs[i].src, f);
            fclose(f);
            free(dst);
        }
        char *mf = fmt("%s/" PKG_MANIFEST, stage);
        f = fopen(mf, "wb");
        if (!f) fatal("cannot write %s", mf);
        fprintf(f,
            "{\n"
            "  \"name\": \"%s\",\n"
            "  \"version\": \"%s\",\n"
            "  \"entry\": \"%s.hphp\",\n"
            "  \"description\": \"Bundled library (installed from the hphp binary).\",\n"
            "  \"author\": \"HolyPHP\"\n"
            "}\n", stem, HPHP_VERSION, stem);
        fclose(f);
        char *hpx = fmt("%s/%s.hpx", stage, stem);
        pkg_pack_dir(stage, hpx);
        int rc = pkg_install_file(hpx);
        rm_rf(stage);
        return rc;
    }
}

static int pkg_cmd_install(int argc, char **argv) {
    if (argc < 1) { fprintf(stderr, "usage: hphp pkg install <name | ./file.hpx>\n"); return 1; }
    const char *what = argv[0];
    bool looks_file = strchr(what, '/') || strstr(what, ".hpx");
    if (looks_file) return pkg_install_file(what);
    int rc = pkg_install_registry(what);
    if (rc == 2) {
        /* registry unreachable / missing: fall back to the bundled copy */
        fprintf(stderr, "(registry unreachable — trying the libraries bundled in hphp)\n");
        rc = pkg_install_embedded(what);
        if (rc != 0)
            fatal("cannot install \"%s\": registry unreachable and not a bundled library", what);
        return 0;
    }
    return rc;
}

static int pkg_cmd_remove(int argc, char **argv) {
    if (argc < 1) { fprintf(stderr, "usage: hphp pkg remove <name>\n"); return 1; }
    if (!pkg_is_installed(argv[0])) { fprintf(stderr, "not installed: %s\n", argv[0]); return 1; }
    char *dir = pkg_dir_of(argv[0]);
    rm_rf(dir);
    pkg_registry_remove(argv[0]);
    printf("removed %s\n", argv[0]);
    return 0;
}

static int pkg_cmd_list(void) {
    size_t n;
    InstalledPkg *v = pkg_registry_read(&n);
    if (n == 0) { printf("no packages installed (try: hphp pkg install <name>)\n"); return 0; }
    printf("%-20s %s\n", "PACKAGE", "VERSION");
    for (size_t i = 0; i < n; i++)
        printf("%-20s %s\n", v[i].name, v[i].version);
    return 0;
}

static int pkg_cmd_search(int argc, char **argv) {
    const char *q = argc ? argv[0] : "";
    char *base = pkg_registry_url_or_default();
    {
        char *url = fmt("%s/search?q=%s", base, q);
        size_t n;
        int status = 0;
        char *body = pkgnet_get(url, &n, &status);
        if (body && status == 200) {
            fputs(body, stdout);
            return 0;
        }
        fprintf(stderr, "(registry unreachable, showing local packages)\n");
    }
    return pkg_search(q) > 0 ? 0 : 1;
}

/* init: create hphp.json skeleton in cwd */
static int pkg_cmd_init(int argc, char **argv) {
    /* name = directory name (sanitized) */
    char cwd[1024];
#ifdef _WIN32
    _getcwd(cwd, sizeof cwd);
#else
    if (!getcwd(cwd, sizeof cwd)) snprintf(cwd, sizeof cwd, ".");
#endif
    char *base = cwd;
    for (const char *p = cwd; *p; p++)
        if (*p == '/' || *p == '\\') base = (char *)(p + 1);
    char name[128]; size_t ni = 0;
    for (const char *p = base; *p && ni + 1 < sizeof name; p++) {
        char c = *p;
        if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
        if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_') name[ni++] = c;
    }
    name[ni] = 0;
    if (!ni) snprintf(name, sizeof name, "mypkg");
    const char *forced = NULL;
    for (int i = 0; i < argc; i++)
        if (!strcmp(argv[i], "--name") && i + 1 < argc) forced = argv[++i];
    if (forced) snprintf(name, sizeof name, "%s", forced);
    if (!pkg_name_ok(name))
        fatal("package name must be lowercase letters, digits, _ (got \"%s\")", name);
    char *mf = fmt("./" PKG_MANIFEST);
    if (read_file_soft(mf)) { printf("%s already exists\n", mf); return 1; }
    FILE *f = fopen(mf, "wb");
    if (!f) fatal("cannot write %s", mf);
    fprintf(f,
        "{\n"
        "  \"name\": \"%s\",\n"
        "  \"version\": \"0.1.0\",\n"
        "  \"entry\": \"%s.hphp\",\n"
        "  \"description\": \"A HolyPHP package.\",\n"
        "  \"author\": \"\"\n"
        "}\n", name, name);
    fclose(f);
    printf("created %s — add %s.hphp and run:\n", mf, name);
    printf("  hphp pkg check      (validate it imports)\n");
    printf("  hphp pkg pack       (build the .hpx)\n");
    return 0;
}

/* check: the package entry must type-check on its own */
static int pkg_cmd_check(void) {
    PkgManifest m;
    pkg_read_manifest_of(".", &m);
    char *entry = fmt("./%s", m.entry);
    if (!read_file_soft(entry))
        fatal("entry \"%s\" missing (create it or set \"entry\" in hphp.json)", m.entry);
    printf("checking %s %s (%s)... ", m.name, m.version, m.entry);
    fflush(stdout);
    return do_check_file(entry);   /* shared with `hphp check` */
}

/* publish: pack + POST the .hpx to the registry */
static int pkg_cmd_publish(int argc, char **argv) {
    const char *dir = ".";
    for (int i = 0; i < argc; i++)
        if (!strcmp(argv[i], "--dir") && i + 1 < argc) dir = argv[++i];
    PkgManifest m;
    pkg_read_manifest_of(dir, &m);
    char *cache = pkg_home_file("cache");
    mkdir_p(cache);
    char *hpx = fmt("%s/%s-%s.hpx", cache, m.name, m.version);
    pkg_pack_dir(dir, hpx);
    char *base = pkg_registry_url_or_default();
    size_t hn;
    char *hpx_data = read_file_soft(hpx);
    hn = hpx_data ? strlen(hpx_data) : 0;
    if (!hpx_data) fatal("pack failed: %s", hpx);
    char *url = fmt("%s/publish", base);
    int status = 0;
    char *resp = pkgnet_post(url, "application/octet-stream", hpx_data, hn, &status);
    if (!resp) fatal("registry unreachable: %s", base);
    printf("%s", resp);
    return status == 200 ? 0 : 1;
}

static int pkg_cmd_registry(int argc, char **argv) {
    if (argc < 1) {
        const char *env = getenv("HPHP_REGISTRY");
        char *from_file = pkg_registry_url();
        char *eff = pkg_registry_url_or_default();
        printf("registry: %s\n", eff);
        if (env && *env) {
            printf("  (from $HPHP_REGISTRY; override with: hphp pkg registry <url>)\n");
        } else if (from_file) {
            printf("  (change it with: hphp pkg registry <url>)\n");
        } else {
            printf("  (default — pin yours with: hphp pkg registry <url>\n"
                   "           or:        export HPHP_REGISTRY=<url>)\n");
        }
        return 0;
    }
    if (strncmp(argv[0], "http://", 7) != 0)
        fatal("registry URL must start with http:// (TLS comes later)");
    char *f = pkg_home_file(PKG_REGISTRY_FILE);
    FILE *fp = fopen(f, "wb");
    if (!fp) fatal("cannot write %s", f);
    fputs(argv[0], fp);
    fclose(fp);
    printf("registry set to %s\n", argv[0]);
    return 0;
}

static int pkg_cmd_home(void) {
    char *h = pkg_home();
    printf("%s\n", h);
    return 0;
}

static int pkg_command(int argc, char **argv) {
    if (argc < 1 || !strcmp(argv[0], "help") || !strcmp(argv[0], "--help")) {
        printf(
            "usage: hphp pkg <command>\n"
            "\n"
            "  init               create an hphp.json skeleton in this folder\n"
            "  check              type-check this package's entry\n"
            "  pack               build <name>-<version>.hpx from this folder\n"
            "  publish            pack + upload to the registry\n"
            "  install <what>     install a package (registry name or ./file.hpx)\n"
            "  remove <name>      uninstall\n"
            "  list               list installed packages\n"
            "  search [q]         search (registry when reachable, else local)\n"
            "  registry [url]     show or set the registry URL\n"
            "  home               print the package home directory\n");
        return argc < 1 ? 1 : 0;
    }
    const char *sub = argv[0];
    if (!strcmp(sub, "init"))     return pkg_cmd_init(argc - 1, argv + 1);
    if (!strcmp(sub, "check"))    return pkg_cmd_check();
    if (!strcmp(sub, "pack"))     return pkg_cmd_pack(argc - 1, argv + 1);
    if (!strcmp(sub, "publish"))  return pkg_cmd_publish(argc - 1, argv + 1);
    if (!strcmp(sub, "install"))  return pkg_cmd_install(argc - 1, argv + 1);
    if (!strcmp(sub, "remove"))   return pkg_cmd_remove(argc - 1, argv + 1);
    if (!strcmp(sub, "uninstall"))return pkg_cmd_remove(argc - 1, argv + 1);
    if (!strcmp(sub, "list"))     return pkg_cmd_list();
    if (!strcmp(sub, "search"))   return pkg_cmd_search(argc - 1, argv + 1);
    if (!strcmp(sub, "registry")) return pkg_cmd_registry(argc - 1, argv + 1);
    if (!strcmp(sub, "home"))     return pkg_cmd_home();
    fprintf(stderr, "hphp pkg: unknown command \"%s\" (try: hphp pkg help)\n", sub);
    return 1;
}

/* ------------------------------------------------------------------ */
/* main                                                                */
/* ------------------------------------------------------------------ */

/* check one file on its own (used by `hphp check` and `hphp pkg check`).
 * Returns process exit code. */
static bool rm_rf_path(const char *path) {
    /* implemented by pkgcore via this trampoline: pkgcore's rm_rf is static,
     * so expose removal through the public API (pkg_cmd_remove uses it too). */
    extern bool pkg_remove_tree(const char *path);   /* pkgcore.c */
    return pkg_remove_tree(path);
}

int do_check_file(const char *path) {
    LoadCtx c = {0};
    load_file_recursive(&c, path);
    if (c.programs.len == 0) fatal("no programs loaded");
    Program *w = xcalloc(1, sizeof(Program));
    w->file = intern(path);
    merge_programs(w, c.programs);
    Program *r = c.programs.items[c.programs.len - 1];
    w->stmts = r->stmts;
    builtins_init();
    sema_run(w);
    if (!sema_result_ok()) {
        fprintf(stderr, "hphp: compilation failed\n");
        return 1;
    }
    fprintf(stderr, "%s: OK (types and borrows check)\n", path);
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2 || strcmp(argv[1], "--help") == 0 || strcmp(argv[1], "-h") == 0) {
        fprintf(stderr,
                "HolyPHP %s — a low-level, PHP-flavored compiled language\n"
                "\n"
        "usage: hphp <file.hphp>               run a HolyPHP program\n"
        "       hphp run <file.hphp>           run a HolyPHP program\n"
        "       hphp dev <file.hphp>           run in dev mode (faster builds, -O0)\n"
        "       hphp build <file.hphp> [-o app]  build a native executable\n"
                "       hphp check <file.hphp>         type- & borrow-check only\n"
                "       hphp emit <file.hphp>          inspect the internal representation\n"
                "       hphp pkg <command> [args]      package manager (hphp pkg help)\n"
                "       hphp install <package>         install a package (shorthand)\n"
                "       hphp version                   print version\n",
                HPHP_VERSION);
        return argc < 2 ? 1 : 0;
    }
    const char *cmd = argv[1];
    const char *file = NULL;
    const char *outname = NULL;
    bool gui = false;
    if (strcmp(cmd, "version") == 0 || strcmp(cmd, "--version") == 0 ||
        strcmp(cmd, "-v") == 0) {
        printf("HolyPHP %s\n", HPHP_VERSION);
        return 0;
    }
    if (strcmp(cmd, "pkg") == 0 || strcmp(cmd, "package") == 0) {
        return pkg_command(argc - 2, argv + 2);   /* consumes argv[2..] */
    }
    /* hphp install <pkg> — the common case, same as `hphp pkg install` */
    if (strcmp(cmd, "install") == 0) {
        return pkg_cmd_install(argc - 2, argv + 2);
    }
    /* default command is "run" — hphp file.hphp just works */
    if (strcmp(cmd, "run") != 0 && strcmp(cmd, "build") != 0 &&
        strcmp(cmd, "emit") != 0 && strcmp(cmd, "check") != 0 &&
        strcmp(cmd, "dev") != 0) {
        file = cmd;
        cmd = "run";
    }
    PtrVec prog_args = {0};
    for (int i = 2; i < argc; i++) {
        if (strcmp(argv[i], "-o") == 0 && i + 1 < argc) outname = argv[++i];
        else if (strcmp(argv[i], "--gui") == 0) gui = true;
        else if (!file) file = argv[i];
        else ptrvec_push(&prog_args, argv[i]);
    }
    if (!file) { fprintf(stderr, "hphp: no input file\n"); return 1; }
    bool do_emit = strcmp(cmd, "emit") == 0;
    bool do_check = strcmp(cmd, "check") == 0;

    LoadCtx ctx = {0};
    load_file_recursive(&ctx, file);
    if (ctx.programs.len == 0) fatal("no programs loaded");

    Program *whole = xcalloc(1, sizeof(Program));
    whole->file = intern(file);
    merge_programs(whole, ctx.programs);
    /* root file = last loaded (it imports its deps first) */
    Program *root = ctx.programs.items[ctx.programs.len - 1];
    whole->stmts = root->stmts;

    builtins_init();
    sema_run(whole);
    if (!sema_result_ok()) {
        fprintf(stderr, "hphp: compilation failed\n");
        return 1;
    }
    if (do_check) {
        fprintf(stderr, "%s: OK (types and borrows check)\n", file);
        return 0;
    }

    Buf out;
    buf_init(&out);
    codegen_emit(whole, &out);
    if (do_emit) {
        fwrite(out.data, 1, out.len, stdout);
        return 0;
    }

    /* ---- backend: everything happens in hphp's private build dir ---- */
    /* incremental cache: try to reuse generated C + objects */
    bool dev = strcmp(cmd, "dev") == 0;
    PtrVec cache_files = {0};
    collect_source_files(&cache_files, &ctx, file);

    char *self = find_compiler(argv[0]);
    const char *wd = work_dir();
    extract_runtime(wd, self);
    char *rt = path_join(wd, "rt");

    /* The cache key covers everything the build reads: the program sources,
     * the compiler binary and the runtime sources. The last two are what
     * made a stale binary look like a compiler bug - the program was fine,
     * the cache just did not know the tools had changed. */
    PtrVec tool_files = {0};
    ptrvec_push(&tool_files, (void *)self);
    static const char *rt_names[] = {"hphp_rt.c", "hphp_std.c", "hphp_thr.c",
                                     "hphp_ui.c", "hphp_wv2.c", "hphp_rt.h"};
    for (size_t i = 0; i < sizeof rt_names / sizeof rt_names[0]; i++) {
        char *p = path_join(rt, rt_names[i]);
        ptrvec_push(&tool_files, p);
    }
    char *cache_key = cache_key_for_files(&cache_files, &tool_files);
    /* Level-1 key: the runtime objects are identical for every program, so
     * they get their own slot keyed by the toolchain (compiler binary +
     * runtime sources) alone - a new program starts fast. */
    PtrVec rt_only = {0};
    char *rt_key = cache_key_for_files(&rt_only, &tool_files);
    for (size_t i = 1; i < tool_files.len; i++) free(tool_files.items[i]);
    /* dev (-O0) and release (-O2) objects are not interchangeable: keep
     * them in separate cache slots or a dev build would poison a release
     * build (and vice versa). */
    if (dev) {
        char *tagged = fmt("%s_dev", cache_key);
        free(cache_key);
        cache_key = tagged;
        char *rt_tagged = fmt("%s_dev", rt_key);
        free(rt_key);
        rt_key = rt_tagged;
    }
    bool no_cache = getenv("HPHP_NO_CACHE") != NULL;
    (void)no_cache;

    /* generated C goes into the private dir — never the user's project.
     * The per-run tag keeps two concurrent builds from colliding. */
    char tag[32];
    build_tag(tag, sizeof tag);
    char *cpath = path_join(wd, fmt("prog_%s.c", tag));
    FILE *cf = fopen(cpath, "wb");
    if (!cf) fatal("hphp: cannot write build file %s", cpath);
    fwrite(out.data, 1, out.len, cf);
    fclose(cf);

    /* executable destination: -o path, else next to the source file.
     * Always absolute so the final rename and spawn work from inside wd. */
#ifdef _WIN32
    char cwd_buf[2048];
    GetCurrentDirectoryA(sizeof cwd_buf, cwd_buf);
    const char *cwd = cwd_buf;
#else
    char *cwd = getcwd(NULL, 0);
#endif
    char *exepath;
    if (outname) {
        bool absolute = outname[0] == '/' || outname[0] == '\\' ||
                        (outname[1] == ':' &&
                         (outname[2] == '/' || outname[2] == '\\'));
        if (absolute) {
            exepath = xstrdup(outname);
        } else {
            exepath = fmt("%s/%s", cwd, outname);
        }
#ifdef _WIN32
        if (!strchr(path_file_name(exepath), '.'))
            exepath = fmt("%s.exe", exepath); /* runnable name on Windows */
#endif
    } else {
        const char *base = path_file_name(file);
        const char *stem = "prog";
        const char *dot = strrchr(base, '.');
        if (dot && dot != base) stem = xstrndup(base, dot - base);
        const char *slash = strrchr(file, '/'), *bslash = strrchr(file, '\\');
        const char *cut = slash > bslash ? slash : bslash;
        if (cut) {
            char *dir = xstrndup(file, cut - file);
            exepath = fmt("%s/%s", dir, stem);
#ifdef _WIN32
            exepath = fmt("%s.exe", exepath);
#endif
        } else {
            exepath = fmt("%s/%s", cwd, stem);
#ifdef _WIN32
            exepath = fmt("%s.exe", exepath);
#endif
        }
    }

    if (cc_build_in_dir(wd, rt, cpath, exepath, gui, no_cache ? NULL : cache_key,
                        no_cache ? NULL : rt_key, dev, tag) != 0) {
        fprintf(stderr, "hphp: backend failed to produce an executable\n");
        return 1;
    }

    if (strcmp(cmd, "build") == 0) {
        fprintf(stderr, "hphp: built %s\n", exepath);
        return 0;
    }

    /* run: execute the freshly built binary (console I/O passes through) */
    int rc = spawn_wait(exepath, prog_args);
    if (!getenv("HPHP_KEEP_BIN")) remove_quiet(exepath); /* ephemeral run */
    return rc;
}
