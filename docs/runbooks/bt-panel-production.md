# DD 宝塔 / Nginx 共存部署（Debian 13）

> 目标：宝塔 Nginx 继续占用宿主机 TCP 80/443；DD 不抢 80/443。
>
> 当前实例示例：`85746.pro` / `56.10.68.127`。

## 1. DNS

给同一台服务器增加 4 条 A 记录：

```text
api.85746.pro    -> 56.10.68.127
rtc.85746.pro    -> 56.10.68.127
turn.85746.pro   -> 56.10.68.127
media.85746.pro  -> 56.10.68.127
```

根域 `85746.pro` 可继续留给 Web/官网。

## 2. 拉代码

推荐给私有仓库配置只读 Deploy Key：

```bash
mkdir -p /root/.ssh && chmod 700 /root/.ssh
ssh-keygen -t ed25519 -f /root/.ssh/dd_deploy -N '' -C dd-prod
cat /root/.ssh/dd_deploy.pub
```

把公钥加到 GitHub `fadacai222/DD -> Settings -> Deploy keys`，不要开启写权限。

然后：

```bash
GIT_SSH_COMMAND='ssh -i /root/.ssh/dd_deploy -o IdentitiesOnly=yes' \
  git clone git@github.com:fadacai222/DD.git /opt/dd

git -C /opt/dd config core.sshCommand \
  'ssh -i /root/.ssh/dd_deploy -o IdentitiesOnly=yes'
```

## 3. 一键生成宝塔模式配置

把邮箱替换为真实邮箱：

```bash
cd /opt/dd/infra/prod
bash scripts/prepare-bt.sh 85746.pro 56.10.68.127 your@email.com
bash scripts/init-secrets.sh
```

宝塔模式默认端口：

```text
127.0.0.1:18473  DD API
127.0.0.1:17880  LiveKit signaling
127.0.0.1:19000  MinIO media
3478/UDP         TURN/UDP
5349/TCP         TURN/TLS
7881/TCP         ICE/TCP
50000-50100/UDP  WebRTC media
```

DD 不绑定宿主机 TCP 80/443。

## 4. 宝塔里建 4 个站点

### `api.85746.pro`

- 开启 SSL / Let's Encrypt。
- 反向代理到：`http://127.0.0.1:18473`

### `rtc.85746.pro`

- 开启 SSL / Let's Encrypt。
- 反向代理到：`http://127.0.0.1:17880`
- 开启 WebSocket 支持。

如果宝塔版本没有 WebSocket 开关，在该站点 Nginx `server {}` 中补：

```nginx
proxy_http_version 1.1;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection "upgrade";
```

### `media.85746.pro`

- 开启 SSL / Let's Encrypt。
- 反向代理到：`http://127.0.0.1:19000`
- 在该站点 `server {}` 中增加：

```nginx
client_max_body_size 0;
proxy_request_buffering off;
proxy_buffering off;
proxy_set_header Host $host;
```

这是为了避免大视频/文件被 Nginx `413` 或整包缓冲。

### `turn.85746.pro`

只需要创建站点并申请可信 SSL 证书，不需要 HTTP 反向代理。LiveKit 自己在 `5349/TCP` 提供 TURN/TLS。

证书申请成功后导入 DD：

```bash
cd /opt/dd/infra/prod
bash scripts/import-bt-turn-cert.sh turn.85746.pro
```

脚本默认读取宝塔证书目录：

```text
/www/server/panel/vhost/cert/turn.85746.pro/
```

宝塔以后续签 TURN 证书后，再执行一次导入脚本并：

```bash
bash scripts/restart.sh livekit
```

## 5. 防火墙

保留宝塔现有：

```text
80/TCP
443/TCP
```

新增：

```text
3478/UDP
5349/TCP
7881/TCP
50000-50100/UDP
```

不要开放：

```text
5432  PostgreSQL
6379  Redis
9000  MinIO
9001  MinIO Console
18473 DD API
17880 LiveKit signaling
19000 MinIO host proxy port
```

其中 `18473/17880/19000` 只绑定 `127.0.0.1`。

## 6. 第一次部署

```bash
cd /opt/dd/infra/prod
bash scripts/preflight.sh
bash scripts/deploy.sh
```

`preflight.sh` 必须 PASS；失败就先解决报错，不要绕过。

部署后：

```bash
docker ps
bash scripts/deployment-check.sh --public
```

还可以直接检查：

```bash
curl -fsS https://api.85746.pro/api/v1/system/live
curl -fsS https://api.85746.pro/api/v1/system/ready
```

## 7. 第一阶段先不要开的东西

保持：

```text
DD_REGISTRATION_MODE=closed
```

等真实 SMTP 配好后再开放邮箱注册。

FCM/APNs Secret 也可以先留空；它们不阻塞 API/数据库/媒体/通话基础服务上线。

## 8. 当前能力边界

宝塔模式保留宝塔 Nginx 的 80/443，但 TURN/TLS 改用 5349/TCP。相比把 TURN/TLS 放在 443，这对“只允许 HTTPS 443 出站”的极端公司网络兼容性稍弱；家庭网络、移动网络和普通公网部署仍应通过真实设备测试确认。LiveKit 的信令仍通过 `wss://rtc.85746.pro` 的标准 443/TCP 走宝塔 Nginx。
