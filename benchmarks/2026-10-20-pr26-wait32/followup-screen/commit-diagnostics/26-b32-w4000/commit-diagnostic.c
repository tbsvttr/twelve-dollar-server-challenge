/* Group commit against build/commit-server (see commit_fault.c): a failed commit answers 500 and rolls
 * back, rows it rolled back are never shown to anyone, and a success is not sent before its commit.
 * Run with SERVER=build/commit-server. */
#include "t.h"

static char *T;

static void touch(const char *name)
{
    char *p = fmt("%s/%s", srv_dir, name);
    int fd = open(p, O_CREAT | O_WRONLY, 0600);
    if (fd >= 0) close(fd);
    free(p);
}
static int exists(const char *name)
{
    char *p = fmt("%s/%s", srv_dir, name);
    int e = !access(p, F_OK);
    free(p);
    return e;
}
static void rm(const char *name)
{
    char *p = fmt("%s/%s", srv_dir, name);
    unlink(p);
    free(p);
}

static long long newest_id(void)
{
    resp r = {0};
    req("GET", "/feed", NULL, NULL, &r);
    long long id = jnum(r.body, "id");
    free(r.body);
    return id;
}

int main(void)
{
    srv_start();
    T = jwt_user("1", "\"golden_ember_1\"");
    resp r = {0};
    long long next = newest_id() + 1;
    char *path = fmt("/posts/%lld", next);

    touch("fail");
    int ok = req("POST", "/posts", T, "{\"body\":\"rolled back\"}", &r) == 500 && streq(r.body, "{\"error\":\"internal server error\"}");
    ok &= req("GET", path, NULL, NULL, &r) == 404;
    check(ok, "a failed commit answers 500, and the post does not exist");

    /* a read pipelined after the failing write, in the same transaction, is dropped with it */
    touch("fail");
    conn c = copen();
    char *w = rq("POST", "/posts", T, "{\"body\":\"phantom\"}", 18), *q = fmt("%sGET /feed HTTP/1.1\r\nHost: x\r\n\r\n", w);
    csends(&c, q);
    ok = cread(&c, &r) && r.status == 500 && has_header(&r, "\r\nConnection: close\r\n") && closed_by_server(&c, 2000);
    check(ok, "a read pipelined after a failed write gets no response: one 500, then the connection closes");
    cclose(&c);
    free(q);

    /* reads on other connections, sent together with failing writes, never show the rolled-back rows */
    int leaked = 0, trials = 20;
    for (int i = 0; i < trials; i++) {
        touch("fail");
        conn a = copen(), b[4];
        for (int k = 0; k < 4; k++) b[k] = copen();
        csends(&a, w);
        for (int k = 0; k < 4; k++) csends(&b[k], "GET /feed HTTP/1.1\r\nHost: x\r\n\r\n");
        int read_write = cread(&a, &r); fprintf(stderr, "DIAG round=%d write_read=%d write_status=%d\n", i, read_write, r.status);
        for (int k = 0; k < 4; k++) {
            if (cread(&b[k], &r) && r.status == 200 && strstr(r.body, "phantom")) leaked++;
            cclose(&b[k]);
        }
        cclose(&a);
        rm("fail");
    }
    int fs = req("GET", "/feed", NULL, NULL, &r);
    int fp = r.body && strstr(r.body, "phantom");
    fprintf(stderr, "DIAG final_feed_status=%d contains_phantom=%d body=%s\n", fs, fp, r.body ? r.body : "(null)");
    int ps = req("GET", path, NULL, NULL, &r);
    fprintf(stderr, "DIAG final_post_status=%d body=%s\n", ps, r.body ? r.body : "(null)");
    ok = !leaked && fs == 200 && !fp && ps == 404;
    check(ok, "%d rounds of a failing write with 4 concurrent feed reads: rolled-back rows shown %d times", trials, leaked);
    free(w);

    /* a success is withheld while its commit is still running */
    touch("hold");
    c = copen();
    char *cq = rq("POST", "/posts", T, "{\"body\":\"committed\"}", 20);
    csends(&c, cq);
    for (int i = 0; i < 200 && !exists("entered"); i++) sleep_ms(10);
    ok = exists("entered");
    sleep_ms(200);
    ok &= !readable(&c, 0);
    rm("hold");
    ok &= cread(&c, &r) && r.status == 201 && jnum(r.body, "id") == next;
    check(ok, "a 201 is not sent before its commit finishes");
    cclose(&c);
    ok = req("GET", path, NULL, NULL, &r) == 200;
    char *b = jstr(r.body, "body");
    ok &= streq(b, "committed");
    check(ok, "the next write after the rollbacks commits normally");
    free(b); free(cq); free(path); free(r.body);

    printf("commit: %d passed, %d failed\n", passes, fails);
    return fails != 0;
}
