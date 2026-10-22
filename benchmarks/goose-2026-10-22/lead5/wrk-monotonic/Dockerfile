# PREPARED ONLY. No image has been built from this recipe yet.
ARG BASE_IMAGE=twelve-unified:2026-10-07
FROM ${BASE_IMAGE} AS builder
USER root
ARG BUILD_CPUSET=3,4
RUN taskset -c "${BUILD_CPUSET}" sh -c 'apt-get update && apt-get install -y --no-install-recommends \
      gcc make patch pkg-config libluajit-5.1-dev libssl-dev luajit dpkg-dev python3 \
    && rm -rf /var/lib/apt/lists/*'
COPY source-archives /recipe/source-archives
COPY build.sh mock_clock_test.py monotonic-clock-only.patch /recipe/
RUN taskset -c "${BUILD_CPUSET}" bash /recipe/build.sh /output

FROM ${BASE_IMAGE}
ARG WRK_CLOCK_VARIANT=monotonic
COPY --from=builder /output/${WRK_CLOCK_VARIANT}/ /opt/wrk-clock/bin/
COPY --from=builder /output/build-proof.json /output/source-identities.json /opt/wrk-clock/
COPY --from=builder /output/mock-clock* /opt/wrk-clock/mock/
COPY provenance.json monotonic-clock-only.patch /opt/wrk-clock/
ENV PATH="/opt/wrk-clock/bin:${PATH}"
LABEL wrk.source_package="4.1.0-4build2" wrk.clock_variant="${WRK_CLOCK_VARIANT}"
