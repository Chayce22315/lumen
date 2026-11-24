# Linux toolchain for building and testing the portable LumenKit package.
# SWIFT_VERSION is pinned by scripts/lumenkit-linux.sh (default 6.1, matching Xcode 16.4).
ARG SWIFT_VERSION=6.1
FROM swift:${SWIFT_VERSION}-noble
RUN apt-get update \
 && apt-get install -y --no-install-recommends libsqlite3-dev \
 && rm -rf /var/lib/apt/lists/*
