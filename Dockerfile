ARG GO_IMAGE=golang:1.26.8
ARG BASE_IMAGE=gcr.io/distroless/base-debian13:nonroot@sha256:0896741ba5bafd3ac87ea025a5f578952f2d238ddc3614cb368acc983a687aa2

FROM --platform=$BUILDPLATFORM ${GO_IMAGE} AS builder
ARG TARGETOS
ARG TARGETARCH
ARG CLOUDFLARED_VERSION=dev
ENV GO111MODULE=on \
  CGO_ENABLED=0 \
  CONTAINER_BUILD=1

WORKDIR /go/src/github.com/cloudflare/cloudflared/

COPY go.mod go.sum ./
RUN go mod download

COPY . .

RUN make cloudflared \
  VERSION="${CLOUDFLARED_VERSION}" \
  TARGET_OS="${TARGETOS}" \
  TARGET_ARCH="${TARGETARCH}"

FROM ${BASE_IMAGE}

COPY --from=builder --chown=65532:65532 /go/src/github.com/cloudflare/cloudflared/cloudflared /usr/local/bin/

USER 65532:65532

ENTRYPOINT ["cloudflared", "--no-autoupdate"]
CMD ["version"]
