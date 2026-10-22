FROM twelve-goose-final:2026-10-22
COPY --chown=bench:bench source /suite/sources/prgoose
USER bench
WORKDIR /suite/sources/prgoose
RUN GOOSE_BIN=/opt/goose/build/goose GOOSE_REUSE_SQLITE_PGO_SHA256=2c5663ef60e2bbc9f87a54f05f8eca1057b64614f5ced6fc34591ed3ef3b2178 bash build.sh
USER root
ENV GOOSE_IO_BACKEND=epoll
