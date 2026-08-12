# DD Observability Compose Overlay

本目录不是独立业务部署栈，而是给正式 `infra/prod/compose.yml` 叠加的 observability overlay。

包含：

- API metrics listener `:9464`（Compose 内网）；
- Worker metrics/live/ready listener `:9465`（Compose 内网）；
- Prometheus；
- Grafana（仅 localhost 暴露，禁匿名）；
- blackbox-exporter（LiveKit / embedded TURN listener / TLS mux listener）；
- node-exporter（宿主机磁盘）；
- 正式 Prometheus alert rules。

启动前复制并填写 observability 环境文件，但不要把真实 secret 放进仓库：

```bash
cp infra/observability/.env.example /opt/dd/observability.env
```

Grafana admin password 必须放在仓库外文件，并通过 `DD_GRAFANA_ADMIN_PASSWORD_FILE` 指向它。

组合示例：

```bash
docker compose \
  --env-file infra/prod/.env \
  --env-file /opt/dd/observability.env \
  -f infra/prod/compose.yml \
  -f infra/observability/compose.yml \
  up -d
```

本 overlay 以正式 Production Compose 的 `api`、`worker`、`livekit`、`tls-mux` service 名为契约，并显式加入其 `internal` network；bind mount 路径也按第一个 `-f infra/prod/compose.yml` 的目录基准解析为 `../observability/...`。若正式 service 名/端口变化，必须同步修改 `prometheus.yml` target 并重新执行最终 `docker compose ... config` 检查。

Compose 内 blackbox 只验证 `livekit:7880` HTTP、`livekit:7881` ICE/TCP listener、`livekit:443` embedded TURN/TLS TCP listener 与 `tls-mux:443` TCP listener 可达。它**不能**证明公网 UDP 443、RTC UDP range、SNI/TLS 证书链、NAT 穿透或跨运营商真实通话；这些继续标记 `HUMAN-PENDING`。

详细排障：

- `docs/runbooks/observability.md`
- `docs/runbooks/push-provider-operations.md`
