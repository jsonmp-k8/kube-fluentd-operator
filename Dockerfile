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

FROM --platform=${TARGETPLATFORM:-linux/amd64} ruby:3.3-alpine3.20

ARG RUBYOPT='-W:no-deprecated -W:no-experimental'

ENV FLUENTD_DISABLE_BUNDLER_INJECTION=1

RUN apk add --no-cache \
      findutils \
      procps \
      net-tools \
      bash

SHELL [ "/bin/bash", "-l", "-c" ]

COPY image/failsafe.conf image/entrypoint.sh image/Gemfile /fluentd/

# Install gems + jemalloc
RUN apk add --no-cache --virtual .build-deps \
      gmp-dev \
      libffi-dev \
      build-base \
      zlib-dev \
      libedit-dev \
      gdbm-dev \
      openssl-dev \
      gnupg \
      autoconf \
      ca-certificates \
      curl \
      bzip2 \
      wget \
      git \
      tar \
      gzip \
      gcc \
      linux-headers \
  && mkdir -p /fluentd/log /fluentd/etc /fluentd/plugins /usr/local/bundle/bin/ \
  && echo 'gem: --no-document' >> /etc/gemrc \
  && bundle config silence_root_warning true \
  && cd /fluentd \
  && bundle install \
  && gem sources --clear-all \
  && ln -s $(which fluentd) /usr/local/bundle/bin/fluentd \
  && gem cleanup \
  ## Install jemalloc
  && curl -sLo /tmp/jemalloc-5.3.0.tar.bz2 https://github.com/jemalloc/jemalloc/releases/download/5.3.0/jemalloc-5.3.0.tar.bz2 \
  && tar -C /tmp/ -xjvf /tmp/jemalloc-5.3.0.tar.bz2 \
  && cd /tmp/jemalloc-5.3.0 \
  && ./configure --disable-cxx && make \
  && mv -v lib/libjemalloc.so* /usr/lib \
  && rm -rf /tmp/* \
  # cleanup build deps
  && apk del .build-deps

COPY image/plugins /fluentd/plugins

COPY config-reloader/templates /templates
COPY config-reloader/validate-from-dir.sh /bin/validate-from-dir.sh
COPY --from=builder /go/src/github.com/vmware/kube-fluentd-operator/config-reloader/config-reloader /bin/config-reloader

# Make sure fluentd picks jemalloc 5.3.0 lib as default
ENV LD_PRELOAD="/usr/lib/libjemalloc.so"

# Add non-root user
RUN addgroup -S fluentd && adduser -S -G fluentd -h /fluentd -s /sbin/nologin fluentd \
    && mkdir -p /var/log/fluentd \
    && chown -R fluentd:fluentd /fluentd /var/log/fluentd

EXPOSE 24444 5140

USER fluentd

ENTRYPOINT ["/fluentd/entrypoint.sh"]
