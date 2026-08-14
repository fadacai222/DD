FROM node:24-alpine@sha256:d32cdf619f63fe0471182d08996dd516c6275bb5fd31ae06e55a570bd9e1ad43 AS admin-build

WORKDIR /src/admin
COPY admin/package.json admin/package-lock.json ./
RUN npm ci
COPY admin/index.html admin/tsconfig.json admin/tsconfig.app.json admin/tsconfig.node.json admin/vite.config.ts ./
COPY admin/src ./src
RUN npm run build

FROM golang:1.26.5-alpine@sha256:0178a641fbb4858c5f1b48e34bdaabe0350a330a1b1149aabd498d0699ff5fb2 AS build

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
      -o /out/im-migrate ./cmd/migrate && \
    CGO_ENABLED=0 GOOS=linux go build \
      -trimpath \
      -o /out/adminctl ./cmd/adminctl

FROM alpine:3.22.5@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce AS runtime
ARG VERSION=dev
ARG VCS_REF=unknown
ARG BUILD_DATE=unknown
ARG SOURCE_URL=unknown
LABEL org.opencontainers.image.title="DD server" \
      org.opencontainers.image.version="$VERSION" \
      org.opencontainers.image.revision="$VCS_REF" \
      org.opencontainers.image.created="$BUILD_DATE" \
      org.opencontainers.image.source="$SOURCE_URL"
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
COPY --from=build /out/adminctl /app/adminctl
COPY --from=admin-build /src/admin/dist /app/admin
EXPOSE 18473
ENTRYPOINT ["/app/im-api"]
