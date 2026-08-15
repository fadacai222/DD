import { Alert, Button, Card, Descriptions, Form, Input, Modal, Space, Tag, Typography } from 'antd';
import { useEffect, useState } from 'react';
import { ApiError, apiClient, type AdminSession, type SystemSettings } from '../api/client';

interface Props { session: AdminSession; onSessionLost(): void; }

export function SettingsPage({ session, onSessionLost }: Props) {
  const [settings, setSettings] = useState<SystemSettings | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [pendingMode, setPendingMode] = useState<'open' | 'closed' | null>(null);
  const [form] = Form.useForm<{ reason: string }>();

  async function load() {
    setLoading(true); setError('');
    try { setSettings(await apiClient.getSystemSettings()); }
    catch (caught) { handleError(caught); }
    finally { setLoading(false); }
  }
  useEffect(() => { void load(); }, []);

  async function applyMode() {
    if (!pendingMode) return;
    const { reason } = await form.validateFields();
    setLoading(true); setError('');
    try {
      setSettings(await apiClient.setRegistrationMode(pendingMode, reason.trim()));
      setPendingMode(null); form.resetFields();
    } catch (caught) { handleError(caught); }
    finally { setLoading(false); }
  }

  function handleError(caught: unknown) {
    if (caught instanceof ApiError && caught.status === 401) onSessionLost();
    setError(caught instanceof ApiError ? `${caught.code}: ${caught.message}` : caught instanceof Error ? caught.message : '未知网络错误');
  }

  return <Space direction="vertical" size={18} className="page-stack">
    <div className="page-heading"><div><Typography.Title level={2}>系统设置</Typography.Title><Typography.Paragraph type="secondary">这里只开放可以安全热更新的业务配置；数据库密码、SMTP 密码、S3/FCM/APNs/STT 凭据仍由服务器 Secret 管理。</Typography.Paragraph></div><Button onClick={() => void load()} loading={loading}>刷新</Button></div>
    {error ? <Alert type="error" showIcon message={error} /> : null}
    <Card title="注册策略" loading={loading && !settings} extra={settings ? <Tag color={settings.registrationMode === 'open' ? 'green' : 'default'}>{settings.registrationMode.toUpperCase()}</Tag> : null}>
      {settings ? <>
        <Descriptions bordered size="small" column={2} items={[
          { key:'mode', label:'当前运行模式', children: settings.registrationMode },
          { key:'source', label:'来源', children: settings.source === 'ADMIN_OVERRIDE' ? '后台运行时配置' : '服务器环境配置' },
          { key:'ready', label:'开放注册依赖', children: <Tag color={settings.registrationOpenAvailable ? 'green' : 'orange'}>{settings.registrationOpenAvailable ? 'READY' : 'NOT READY'}</Tag> },
          { key:'updated', label:'最近后台修改', children: settings.updatedAt ? new Date(settings.updatedAt).toLocaleString() : '—' },
        ]}/>
        <Space className="card-actions" wrap>
          <Button type="primary" disabled={session.admin.role !== 'SUPER_ADMIN' || settings.registrationMode === 'open' || !settings.registrationOpenAvailable} onClick={() => setPendingMode('open')}>开放注册</Button>
          <Button danger disabled={session.admin.role !== 'SUPER_ADMIN' || settings.registrationMode === 'closed'} onClick={() => setPendingMode('closed')}>关闭注册</Button>
        </Space>
        {settings.persistedRegistrationMode && settings.persistedRegistrationMode !== settings.registrationMode ? <Alert className="recovery-alert" type="warning" showIcon message="持久化配置未能激活，当前运行状态已安全降级" description={`数据库期望 ${settings.persistedRegistrationMode.toUpperCase()}，当前实际运行 ${settings.registrationMode.toUpperCase()}。通常是 SMTP/验证码依赖在本次启动时不可用；API 已保持 fail-closed，不会假装开放注册。`} /> : null}
        {!settings.registrationOpenAvailable ? <Alert className="recovery-alert" type="warning" showIcon message="当前不能切换到 OPEN" description="服务器没有完整初始化 EMAIL_CODE_PEPPER + SMTP 发送能力。先补齐服务器 Secret/SMTP 配置，再重启 API，后台才会允许开放注册。" /> : null}
        {settings.registrationMode === 'invite' || settings.registrationMode === 'approval' ? <Alert className="recovery-alert" type="info" showIcon message={`当前环境配置为 ${settings.registrationMode}`} description="DD 当前正式注册链只实现 OPEN/CLOSED；后台不会把未实现的 invite/approval 伪装成可用功能。你可以明确切换为 OPEN 或 CLOSED。" /> : null}
      </> : null}
    </Card>

    <Card title="服务器 Secret">
      <Alert type="info" showIcon message="不会在 Web 后台展示或编辑敏感凭据" description="Telegram Bot Token 是当前唯一已实现的专用加密集成配置。数据库、Redis、SMTP 密码、FCM service account、APNs key、S3 secret、STT credential、Admin Security Secret 继续走服务器 Secret 文件。" />
    </Card>

    <Modal title={pendingMode === 'open' ? '开放新用户注册' : '关闭新用户注册'} open={Boolean(pendingMode)} onCancel={() => { setPendingMode(null); form.resetFields(); }} onOk={() => void applyMode()} confirmLoading={loading} okButtonProps={{danger: pendingMode === 'closed'}} okText="确认切换">
      <Alert type={pendingMode === 'open' ? 'info' : 'warning'} showIcon message={pendingMode === 'open' ? '切换后新用户将立即可以申请邮箱验证码并注册。' : '切换后新注册请求会立即被拒绝，现有用户登录不受影响。'} />
      <Form form={form} layout="vertical" className="modal-form"><Form.Item name="reason" label="变更原因" rules={[{required:true,min:3,max:500}]}><Input.TextArea rows={3} maxLength={500} showCount /></Form.Item></Form>
    </Modal>
  </Space>;
}
