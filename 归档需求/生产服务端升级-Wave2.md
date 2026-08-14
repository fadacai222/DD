# DD 生产服务端 Wave2 升级

> 目的：让 `api.85746.pro` 的 API / Worker / migrations 与 Wave3 客户端使用的 Wave2 服务端合同同步。
>
> 目标 commit：`6ac4e6e6c2d37a234cde3219bb4ce5685a0c5298`
>
> 本轮直接关联真人失败：Android 后台 Push、全局备注名、语音转文字、群通话媒体服务。

## 1. Windows 本地物料

项目根目录已经生成：

```text
DD-Server-Wave2.bundle
SHA256: 7654EB0FD9516CA84FD4C8263E9993864EEA382501FB339866C46F97BE5A9266
```

只需要把这个文件上传到服务器：

```text
/opt/dd/DD-Server-Wave2.bundle
```

不要上传 `clients/app/build`、Windows ZIP、APK 或 `.devspace`。

## 2. 服务器升级

SSH 登录服务器后执行：

```bash
cd /opt/dd

git status --short
git bundle verify ./DD-Server-Wave2.bundle
git fetch ./DD-Server-Wave2.bundle refs/heads/integrate/2026-08-14-wave2:refs/remotes/dd-wave2/integrate

git checkout --detach 6ac4e6e6c2d37a234cde3219bb4ce5685a0c5298
git status --short

cd /opt/dd/infra/prod
bash scripts/upgrade.sh \
  --to-tag wave2-6ac4e6e \
  --to-version 0.4.0-wave2.1 \
  --build \
  --restore-on-failure

bash scripts/deployment-check.sh --public
```

`upgrade.sh` 会走现有生产升级流程：升级前备份、forward-only migrations、构建 API/Worker/migrate、应用新 migration、启动新 API/Worker、健康检查，并保留失败回滚能力。

## 3. 必须核对的 runtime 配置

### Android FCM

```bash
cd /opt/dd/infra/prod

docker compose exec -T worker sh -ec '
  test -s /run/secrets/fcm_service_account_json
  grep -q project_id /run/secrets/fcm_service_account_json
  grep -q private_key /run/secrets/fcm_service_account_json
  echo FCM_SECRET_OK
'
```

必须看到：

```text
FCM_SECRET_OK
```

### 群通话 LiveKit

```bash
cd /opt/dd/infra/prod

docker compose exec -T api sh -ec '
  test -n "$LIVEKIT_URL"
  test -s /run/secrets/livekit_api_key
  test -s /run/secrets/livekit_api_secret
  echo LIVEKIT_GROUP_CALL_CONFIG_OK
'
```

必须看到：

```text
LIVEKIT_GROUP_CALL_CONFIG_OK
```

### 语音转文字

```bash
cd /opt/dd/infra/prod

docker compose exec -T api sh -ec '
  echo "VOICE_TRANSCRIPTION_ENDPOINT=${VOICE_TRANSCRIPTION_ENDPOINT:-<empty>}"
  echo "VOICE_TRANSCRIPTION_MODEL=${VOICE_TRANSCRIPTION_MODEL:-<empty>}"
'
```

如果任意一项显示 `<empty>`，则 STT provider 当前没有启用。此时客户端不应再报英文 404，但“转文字”本身仍不能工作；需要在 `infra/prod/.env` 中补齐 `DD_VOICE_TRANSCRIPTION_ENDPOINT` 与 `DD_VOICE_TRANSCRIPTION_MODEL`，如 provider 需要鉴权，再把 token 写入 `infra/prod/secrets/voice_transcription_credential`，之后重新执行一次 `upgrade.sh` 或重建 API/Worker。

不要把 STT credential 写进 `.env`、客户端或 Git。

## 4. 升级后版本核对

```bash
curl -fsS https://api.85746.pro/api/v1/system/version
```

应看到目标版本：

```text
0.4.0-wave2.1
```

然后再使用最新 Wave3 人测修复版 APK 复测人工验收清单中的 #1～#8。
