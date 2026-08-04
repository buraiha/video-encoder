FROM docker.io/library/ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Tokyo
ENV APP_DIR=/app

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      bash \
      ca-certificates \
      coreutils \
      cron \
      ffmpeg \
      findutils \
      procps \
      tzdata \
      util-linux && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY . /app

RUN chmod +x /app/bin/encode-one.sh /app/bin/watch-and-encode.sh /app/docker/entrypoint.sh

ENTRYPOINT ["/bin/bash", "/app/docker/entrypoint.sh"]