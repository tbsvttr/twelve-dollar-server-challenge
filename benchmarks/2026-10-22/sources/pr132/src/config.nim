## Environment configuration (env-only, per SPEC).
##
## Values are read once at startup. Defaults keep a local checkout runnable, so
## `HOST` defaults to loopback and the database path is relative to the process
## working directory unless the deployment overrides them.
import std/[os, strutils]

type Config* = object
  ## Runtime settings derived solely from the process environment.
  sqlitePath*: string   ## `SQLITE_PATH`; database file handed to the DB layer
  jwtSecret*: string    ## `JWT_SECRET`; HMAC key for HS256 verification
  host*: string         ## `HOST`; bind address for the listener
  port*: int            ## `PORT`; parsed TCP port, default 3000

proc loadConfig*(): Config =
  ## Read the supported environment variables and apply the local defaults.
  ## A non-numeric `PORT` falls back to 3000; range checking is left to bind.
  result.sqlitePath = getEnv("SQLITE_PATH", "seed/feed.db")
  result.jwtSecret = getEnv("JWT_SECRET", "twelve-dollar-challenge")
  result.host = getEnv("HOST", "127.0.0.1")
  var port = 3000
  try:
    port = parseInt(getEnv("PORT", "3000"))
  except ValueError:
    port = 3000
  result.port = port
