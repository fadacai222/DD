# DD Observability Compose Overlay

本目录不是独立业务部署栈，而是给正式 `infra/prod/compose.yml` 叠加的 observability overlay。

包含：

- API metrics listener `:9464`（Compose 内网）；
- Worker metrics/live/ready listener `:9465`（Compose 内网）；
- Prometheus；
- Grafana（仅 localhost 暴露，禁匿名）；
- blackbox-exporter（LiveKit / TURN）；
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

如果 Production Compose 的 service 名/端口不是 `api`、`worker`、`livekit`、`turn` 及本文默认端口，先修改 `prometheus.yml` target，再执行最终 `docker compose ... config` 检查。

详细排障：

- `docs/runbooks/observability.md`
- `docs/runbooks/push-provider-operations.md`
