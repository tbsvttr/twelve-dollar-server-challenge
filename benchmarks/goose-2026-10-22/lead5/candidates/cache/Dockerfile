FROM twelve-goose-final:2026-10-22
COPY --chown=bench:bench source /suite/sources/prgoose
USER bench
WORKDIR /suite/sources/prgoose
RUN /opt/goose/build/goose -O2 --standalone -o .build/app.c app.goose && gcc -O3 -march=native -DNDEBUG -std=gnu11 -I.deps -I.build -pthread -flto=2 -fno-semantic-interposition -fno-plt .build/app.c net.c db.c json_fast.c .build/sqlite-pgo.o -lcrypto -lm -pthread -o bin/server
USER root
ENV GOOSE_IO_BACKEND=epoll
