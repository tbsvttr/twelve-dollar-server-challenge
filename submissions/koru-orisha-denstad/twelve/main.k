// Twelve Dollar Server Challenge — Orisha entry.
//
//   cd orisha/twelve
//   SQLITE_PATH=./feed.db koruc main.k && ./a.out
//
// Routes are ordered hottest-first — the router emits an ordered if-chain
// and the load model is feed -> post -> like (15%) -> post (2%).

import orisha
import twelve/handlers
import twelve/support
import std/io
import std/env
import std/string

orisha:handler = orisha:router(req)
! [GET /feed] |> twelve/handlers:feed(req)
! [GET /posts/:id] p |> twelve/handlers:get-post(req, p.id)
! [POST /posts/:id/like] p |> twelve/handlers:like-post(req, p.id)
! [POST /posts] |> twelve/handlers:create-post(req)
! [GET /health] |> twelve/handlers:health(req)
! [*] -> { status: 404, body: "{\"error\":\"not found\"}", content_type: "application/json", body_static: true }

std/env:get.or(name: "PORT", default: "3000"): ptxt
|> std/string:parse-int(s: ptxt)
    | ok n |> orisha:serve(port: @as(u16, @intCast(n)))
        | shutdown s |> std/io:print.ln(s)
        | failed f |> std/io:print.ln("failed: {{ f:s }}")
    | err _ |> orisha:serve(port: 3000)
        | shutdown s |> std/io:print.ln(s)
        | failed f |> std/io:print.ln("failed: {{ f:s }}")
