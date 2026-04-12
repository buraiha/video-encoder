FROM docker.io/library/ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Tokyo

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ffmpeg \
      ca-certificates \
      bash \
      coreutils \
      findutils \
      procps \
      tzdata && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /work

ENTRYPOINT ["/usr/bin/ffmpeg"]
