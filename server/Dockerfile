FROM golang:1.26.5-alpine AS build

WORKDIR /src/server
COPY server/go.mod server/go.sum ./
RUN go mod download
COPY server/ ./
COPY packages/realtime_protocol/fixtures /src/packages/realtime_protocol/fixtures

ARG VERSION=dev
RUN go test ./... && \
    CGO_ENABLED=0 GOOS=linux go build \
      -trimpath \
      -ldflags="-s -w -X main.version=${VERSION}" \
      -o /out/im-api ./cmd/api && \
    CGO_ENABLED=0 GOOS=linux go build \
      -trimpath \
      -ldflags="-s -w -X main.version=${VERSION}" \
      -o /out/im-worker ./cmd/worker && \
    CGO_ENABLED=0 GOOS=linux go build \
      -trimpath \
      -o /out/im-migrate ./cmd/migrate

FROM alpine:3.22.1 AS runtime
RUN apk add --no-cache ca-certificates tzdata
RUN addgroup -g 65532 -S dd && adduser -u 65532 -S -D -H -G dd dd
WORKDIR /app
USER 65532:65532

FROM runtime AS worker
COPY --from=build /out/im-worker /app/im-worker
ENTRYPOINT ["/app/im-worker"]

FROM runtime AS migrate
COPY --from=build /out/im-migrate /app/im-migrate
ENTRYPOINT ["/app/im-migrate"]

FROM runtime AS api
COPY --from=build /out/im-api /app/im-api
EXPOSE 18473
ENTRYPOINT ["/app/im-api"]
