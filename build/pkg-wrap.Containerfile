FROM scratch
COPY *.rpm /rpms/
LABEL org.opencontainers.image.source=https://github.com/seilent/blockie-image
