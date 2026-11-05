#define _GNU_SOURCE
#include "sqlite3.c"

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "rt.h"
#include "out.c"
#include "json.c"
#include "jwt.c"
#include "http.c"
#include "db.c"
#include "app.c"
#include "uring.c"

int main(void) {
  const char *path = getenv("SQLITE_PATH");
  const char *secret = getenv("JWT_SECRET");
  const char *host = getenv("HOST");
  const char *port = getenv("PORT");

  if (!path || !secret) {
    fprintf(stderr, "SQLITE_PATH and JWT_SECRET are required\n");
    return 1;
  }
  if (!host) host = "0.0.0.0";

  signal(SIGPIPE, SIG_IGN);
  hmac_init((const u8 *)secret, strlen(secret));

  db_open(path);
  app_init();

  const char *conns_env = getenv("CONNS");
  u32 want_conns = conns_env ? (u32)atoi(conns_env) : 600000;
  transport_init(host, port ? atoi(port) : 3000, want_conns);

  fprintf(stderr, "c-libsqlite-larvance listening on %s:%s\n", host, port ? port : "3000");
  transport_run();
  return 0;
}
