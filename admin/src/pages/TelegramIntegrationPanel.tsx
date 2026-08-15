import { Alert, Button, Card, Descriptions, Form, Input, Space, Tag, Typography } from 'antd';
import { useEffect, useState } from 'react';
import {
  ApiError,
  apiClient,
  type AdminSession,
  type TelegramBotInfo,
  type TelegramIntegrationStatus,
} from '../api/client';

interface Props { session: AdminSession; onSessionLost(): void; }

export function TelegramIntegrationPanel({ session, onSessionLost }: Props) {
  const [status, setStatus] = useState<TelegramIntegrationStatus | null>(null);
  const [bot, setBot] = useState<TelegramBotInfo | null>(null);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');
  const [form] = Form.useForm<{ botToken: string }>();

  useEffect(() => {
    let active = true;
    apiClient.getTelegramIntegration()
      .then((value) => { if (active) setStatus(value); })
      .catch((caught: unknown) => { if (active) handleError(caught, onSessionLost, setError); })
      .finally(() => { if (active) setLoading(false); });
    return () => { active = false; };
  }, [onSessionLost]);

  async function saveToken() {
    const { botToken } = await form.validateFields();
    setBusy(true); setError(''); setNotice(''); setBot(null);
    try {
      const result = await apiClient.configureTelegramIntegration(botToken.trim());
      setStatus(result.status); setBot(result.bot);
      setNotice('Bot Token 已验证、加密保存，并在当前 API 进程中热生效。');
      form.resetFields();
    } catch (caught) { handleError(caught, onSessionLost, setError); }
    finally { setBusy(false); }
  }

  async function testCurrent() {
    setBusy(true); setError(''); setNotice(''); setBot(null);
    try {
      const result = await apiClient.testTelegramIntegration();
      setStatus(result.status); setBot(result.bot); setNotice('Telegram Bot API 连通正常，当前 Token 可用。');
    } catch (caught) { handleError(caught, onSessionLost, setError); }
    finally { setBusy(false); }
  }

  return (
    <Space direction="vertical" size={18} className="page-stack">
      <div className="page-heading">
        <div><Typography.Title level={2}>集成服务</Typography.Title><Typography.Paragraph type="secondary">第三方凭据只保存在服务端；管理页面永远不回显 Token 明文。</Typography.Paragraph></div>
      </div>
      {error ? <Alert type="error" showIcon message={error} /> : null}
      {notice ? <Alert type="success" showIcon message={notice} /> : null}
      <Card
        loading={loading}
        title="Telegram Sticker Relay"
        extra={<Tag color={status?.configured ? 'green' : 'default'}>{status?.configured ? 'CONFIGURED' : 'NOT CONFIGURED'}</Tag>}
      >
        <Descriptions bordered size="small" column={2} items={[
          { key: 'enabled', label: '运行状态', children: status?.configured ? '已启用' : '未启用' },
          { key: 'source', label: '配置来源', children: sourceLabel(status?.source) },
          { key: 'updated', label: '最近后台修改', children: status?.updatedAt ? new Date(status.updatedAt).toLocaleString() : '—' },
          { key: 'bot', label: '最近验证 Bot', children: bot ? `${bot.username ? `@${bot.username}` : 'Telegram Bot'} · ID ${bot.id}` : '—' },
        ]} />
        <Space className="card-actions">
          <Button onClick={() => void testCurrent()} loading={busy} disabled={!status?.configured}>测试当前配置</Button>
        </Space>
      </Card>

      {session.admin.role === 'SUPER_ADMIN' ? (
        <Card title="设置 Telegram Bot Token">
          <Alert type="info" showIcon message="保存前调用 Telegram getMe 验证；验证通过后才加密落库并热切换 Relay。" />
          <Form form={form} layout="vertical" className="integration-token-form" onFinish={() => void saveToken()}>
            <Form.Item name="botToken" label="Bot Token" rules={[{ required: true, min: 20, max: 256, message: '请输入有效的 Bot Token' }]}>
              <Input.Password autoComplete="new-password" placeholder="123456789:AA…" />
            </Form.Item>
            <Button type="primary" htmlType="submit" loading={busy}>验证并保存</Button>
          </Form>
        </Card>
      ) : <Alert type="warning" showIcon message="只有 SUPER_ADMIN 可以修改 Telegram Bot Token；当前角色仍可查看并测试状态。" />}
    </Space>
  );
}

function sourceLabel(source?: TelegramIntegrationStatus['source']): string {
  if (source === 'ADMIN_OVERRIDE') return '后台加密配置';
  if (source === 'ENVIRONMENT') return '服务器环境变量 / Secret 文件';
  return '无';
}
function handleError(error: unknown, onSessionLost: () => void, setError: (value: string) => void) {
  if (error instanceof ApiError && error.status === 401) onSessionLost();
  setError(error instanceof ApiError ? `${error.code}: ${error.message}${error.requestId ? ` · ${error.requestId}` : ''}` : error instanceof Error ? error.message : '未知网络错误');
}
