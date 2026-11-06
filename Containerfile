ARG KERNEL_REF

FROM ${KERNEL_REF} AS kernel

FROM scratch AS ctx
COPY build/steps /steps
COPY system_files /system_files

FROM registry.fedoraproject.org/fedora-bootc:44@sha256:4f7fb0a13ebd9a1e48380b1db60259a6fe398444a8277fe02e074338ef2d748e

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=bind,from=kernel,source=/rpms,target=/rpms \
    /ctx/steps/10-kernel.sh

RUN --mount=type=bind,from=ctx,source=/,target=/ctx /ctx/steps/20-release.sh

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=bind,from=pkgs,source=/,target=/pkgs \
    /ctx/steps/30-packages.sh

RUN --mount=type=bind,from=ctx,source=/,target=/ctx /ctx/steps/40-system-files.sh

ARG BLOCKIE_VERSION
ARG BLOCKIE_REVISION

RUN --mount=type=bind,from=ctx,source=/,target=/ctx BLOCKIE_VERSION=${BLOCKIE_VERSION} /ctx/steps/90-identity.sh

RUN --mount=type=bind,from=ctx,source=/,target=/ctx /ctx/steps/99-cleanup.sh

RUN bootc container lint --fatal-warnings --skip baseimage-composefs

LABEL org.opencontainers.image.source=https://github.com/seilent/blockie-image
LABEL org.opencontainers.image.version=${BLOCKIE_VERSION}
LABEL org.opencontainers.image.revision=${BLOCKIE_REVISION}
