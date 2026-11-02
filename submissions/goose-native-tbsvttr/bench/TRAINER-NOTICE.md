`train_sqlite.c` is copied without changes from Scooter1337's Rust challenge entry at commit `95aa405a0003599dbc7fb4dfa47a09e8343239df`:

https://github.com/Scooter1337/twelve-dollar-server-challenge/blob/95aa405a0003599dbc7fb4dfa47a09e8343239df/submissions/rust-epoll-scooter1337/bench/train_sqlite.c

The upstream MIT license is retained in `TRAINER-LICENSE`.

The trainer runs only while building SQLite, against a disposable database of synthetic users, posts and likes. It never reads challenge seed data, handles HTTP requests or becomes part of the final server executable. Goose and Rust use the same trainer and SQLite 3.53.4 source to reduce the SQLite optimization difference between these implementations.
