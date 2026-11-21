# Linux toolchain for building and testing the portable LumenKit package.
# The image tag is pinned so local runs match CI.
FROM swift:6.2-noble
RUN apt-get update \
 && apt-get install -y --no-install-recommends libsqlite3-dev \
 && rm -rf /var/lib/apt/lists/*
