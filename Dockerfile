# Copyright © 2023 VMware, Inc. All Rights Reserved.
# SPDX-License-Identifier: BSD-2-Clause


FROM --platform=${BUILDPLATFORM:-linux/amd64} golang:1.24 AS builder

ARG TARGETPLATFORM
ARG BUILDPLATFORM
ARG TARGETOS
ARG TARGETARCH

WORKDIR /go/src/github.com/vmware/kube-fluentd-operator/config-reloader
COPY config-reloader .

# Speed up local builds where vendor is populated
ARG VERSION
RUN GO111MODULE=on GOOS=${TARGETOS} GOARCH=${TARGETARCH} CGO_ENABLED=0 \
    go build -v -ldflags "-X github.com/vmware/kube-fluentd-operator/config-reloader/config.Version=${VERSION} -w -s" .

FROM --platform=${TARGETPLATFORM:-linux/amd64} ruby:3.3-slim-bookworm

ARG RUBYOPT='-W:no-deprecated -W:no-experimental'
ARG TARGETPLATFORM
ARG BUILDPLATFORM
ARG TARGETOS
ARG TARGETARCH

ENV FLUENTD_DISABLE_BUNDLER_INJECTION=1
ENV BUILDDEPS="\
      libgmp-dev \
      libffi-dev \
      build-essential \
      zlib1g-dev \
      libedit-dev \
      libgdbm-dev \
      libssl-dev \
      gnupg2 \
      autoconf \
      ca-certificates \
      curl \
      bzip2 \
      wget \
      git \
      tar \
      gzip \
      gcc"

RUN rm -f /etc/apt/apt.conf.d/docker-clean && \
    echo 'Binary::apt::APT::Keep-Downloaded-Packages "false";' > /etc/apt/apt.conf.d/keep-cache && \
    apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
         findutils \
         procps \
         net-tools && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

SHELL [ "/bin/bash", "-l", "-c" ]

COPY image/failsafe.conf image/entrypoint.sh image/Gemfile /fluentd/

# Ruby is already provided by the base image; install gems + jemalloc
RUN apt-get update && apt-get install -y --no-install-recommends $BUILDDEPS \
  && mkdir -p /fluentd/log /fluentd/etc /fluentd/plugins /usr/local/bundle/bin/ \
  && echo 'gem: --no-document' >> /etc/gemrc \
  && bundle config silence_root_warning true \
  && cd /fluentd \
  && bundle install \
  && cd /fluentd \
  && gem specific_install https://github.com/javiercri/fluent-plugin-google-cloud.git \
  && cd /fluentd \
  && gem sources --clear-all \
  && ln -s $(which fluentd) /usr/local/bundle/bin/fluentd \
  && gem cleanup \
  ## Install jemalloc
  && curl -sLo /tmp/jemalloc-5.3.0.tar.bz2 https://github.com/jemalloc/jemalloc/releases/download/5.3.0/jemalloc-5.3.0.tar.bz2 \
  && tar -C /tmp/ -xjvf /tmp/jemalloc-5.3.0.tar.bz2 \
  && cd /tmp/jemalloc-5.3.0 \
  && ./configure && make \
  && mv -v lib/libjemalloc.so* /usr/lib \
  && rm -rf /tmp/* \
  # cleanup build deps
  && apt-get purge -y $BUILDDEPS \
  && apt-get autoremove -y \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

COPY image/plugins /fluentd/plugins

COPY config-reloader/templates /templates
COPY config-reloader/validate-from-dir.sh /bin/validate-from-dir.sh
COPY --from=builder /go/src/github.com/vmware/kube-fluentd-operator/config-reloader/config-reloader /bin/config-reloader

# Make sure fluentd picks jemalloc 5.3.0 lib as default
ENV LD_PRELOAD="/usr/lib/libjemalloc.so"

# Add non-root user
RUN groupadd -r fluentd && useradd -r -g fluentd -d /fluentd -s /sbin/nologin fluentd \
    && mkdir -p /var/log/fluentd \
    && chown -R fluentd:fluentd /fluentd /var/log/fluentd

EXPOSE 24444 5140

USER fluentd

ENTRYPOINT ["/fluentd/entrypoint.sh"]
