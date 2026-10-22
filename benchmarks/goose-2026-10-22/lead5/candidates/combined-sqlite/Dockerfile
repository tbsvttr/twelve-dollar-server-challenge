FROM twelve-goose-final:2026-10-22
COPY --chown=bench:bench source /suite/sources/prgoose
USER root
WORKDIR /suite/sources/prgoose
ENV GOOSE_IO_BACKEND=epoll
