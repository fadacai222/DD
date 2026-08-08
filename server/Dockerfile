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
      -o /out/im-api ./cmd/api

FROM scratch

USER 65532:65532
COPY --from=build /out/im-api /app/im-api

EXPOSE 18473
ENTRYPOINT ["/app/im-api"]
