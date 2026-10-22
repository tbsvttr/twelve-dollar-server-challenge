# Node.js No-Framework Solution

A lightweight implementation built on top of Node.js core modules without Express or other web frameworks.

## Highlights

- Native `node:http` server
- SQLite with `better-sqlite3`
- SQLite-side JSON generation (`json_object`, `json_group_array`)
- Reduced JavaScript object allocations
- Direct BLOB/JSON response path
- Minimal routing layer
- JWT authentication
- Graceful shutdown support
- All challenge tests passing (42/42)

## Benchmark Notes (Macbook Apple M4 16gb ram)

Local benchmarks on Apple M4:

| Endpoint | Throughput |
|-----------|-----------:|
| `/health` | ~100k req/s |
| `/posts/:id` | ~100k req/s |
| `/feed` | ~40k req/s |

Mixed workload benchmark:

- Feed reads
- Post reads
- Likes
- Post creation
- JWT verification

Result:

- ~31k req/s

## Main Optimizations

- Moved JSON serialization into SQLite
- Eliminated most `JSON.stringify()` work on hot paths
- Returned pre-built JSON payloads directly from SQLite
- Reduced unnecessary allocations and copies
- Kept request handling close to the metal using Node.js core APIs

Thanks for reviewing.
