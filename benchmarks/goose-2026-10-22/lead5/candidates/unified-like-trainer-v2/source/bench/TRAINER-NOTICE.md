`train_sqlite.c` is copied without changes from Scooter1337's Rust challenge entry at commit `95aa405a0003599dbc7fb4dfa47a09e8343239df`:

https://github.com/Scooter1337/twelve-dollar-server-challenge/blob/95aa405a0003599dbc7fb4dfa47a09e8343239df/submissions/rust-epoll-scooter1337/bench/train_sqlite.c

The upstream MIT license is retained in `TRAINER-LICENSE`.

This unchanged SQL trainer is retained as credited historical comparison material.
The current unified build uses `train_app.py`, an independent HTTP trainer with
disposable synthetic users, posts and likes. It trains the actual generated
Goose application, native helpers and SQLite 3.53.4 together. Neither trainer
reads challenge seed data or becomes part of the production executable.
