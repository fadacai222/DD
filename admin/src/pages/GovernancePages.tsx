import { Alert, Button, Form, Input, Modal, Select, Space, Table, Tag, Typography } from 'antd';
import { useEffect, useState } from 'react';
import {
  ApiError,
  apiClient,
  type AdminSession,
  type AdminSessionItem,
  type AuditItem,
  type ReportItem,
  type ReportStatus,
} from '../api/client';

interface SessionProps { session: AdminSession; onSessionLost(): void; }

export function ReportsPage({ session, onSessionLost }: SessionProps) {
  const [items, setItems] = useState<ReportItem[]>([]);
  const [status, setStatus] = useState('');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  const [pending, setPending] = useState<{ item: ReportItem; status: ReportStatus } | null>(null);
  const [form] = Form.useForm<{ reason: string }>();

  async function load() {
    setLoading(true); setError('');
    try { setItems(await apiClient.listReports(status)); }
    catch (caught) { handleError(caught, onSessionLost, setError); }
    finally { setLoading(false); }
  }
  useEffect(() => { void load(); }, []);

  async function submitTransition() {
    if (!pending) return;
    const { reason } = await form.validateFields();
    setLoading(true);
    try {
      const updated = await apiClient.updateReport(pending.item.id, pending.status, reason.trim());
      setItems((current) => current.map((item) => item.id === updated.id ? updated : item));
      setPending(null); form.resetFields();
    } catch (caught) { handleError(caught, onSessionLost, setError); }
    finally { setLoading(false); }
  }

  return (
    <Space direction="vertical" size={18} className="page-stack">
      <PageHeading title="举报治理" description="举报状态迁移需要管理员会话、CSRF 和处置原因；所有写操作进入审计日志。" />
      {error ? <Alert type="error" showIcon message={error} /> : null}
      <div className="filter-bar">
        <Select value={status} onChange={setStatus} className="filter-select" options={[{ value: '', label: '全部状态' }, { value: 'PENDING', label: '待处理' }, { value: 'IN_REVIEW', label: '处理中' }, { value: 'RESOLVED', label: '已解决' }, { value: 'DISMISSED', label: '已驳回' }]} />
        <Button type="primary" onClick={() => void load()} loading={loading}>刷新</Button>
      </div>
      <Table rowKey="id" loading={loading} dataSource={items} pagination={false} scroll={{ x: 1050 }} columns={[
        { title: '类型', dataIndex: 'category', width: 140, render: (value: string) => <Tag>{value}</Tag> },
        { title: '原因', dataIndex: 'reason', ellipsis: true, width: 300 },
        { title: '举报关系', key: 'relationship', width: 240, render: (_, item) => <Typography.Text>@{item.reporterHandle || item.reporterUserId} → @{item.targetHandle || item.targetUserId}</Typography.Text> },
        { title: '状态', dataIndex: 'status', width: 120, render: (value: string) => <ReportTag value={value} /> },
        { title: '时间', dataIndex: 'createdAt', width: 180, render: formatTime },
        { title: '操作', key: 'actions', width: 250, fixed: 'right', render: (_, item) => session.admin.role === 'SUPPORT_READ_ONLY' || !['PENDING', 'IN_REVIEW'].includes(item.status) ? '—' : <Space>
          {item.status === 'PENDING' ? <Button size="small" onClick={() => setPending({ item, status: 'IN_REVIEW' })}>接手</Button> : null}
          <Button size="small" type="primary" onClick={() => setPending({ item, status: 'RESOLVED' })}>解决</Button>
          <Button size="small" onClick={() => setPending({ item, status: 'DISMISSED' })}>驳回</Button>
        </Space> },
      ]} />
      <Modal title="记录举报处置" open={Boolean(pending)} okText="确认" onOk={() => void submitTransition()} onCancel={() => { setPending(null); form.resetFields(); }} confirmLoading={loading}>
        <Form form={form} layout="vertical"><Form.Item name="reason" label="处置原因" rules={[{ required: true, min: 3, message: '至少 3 个字符' }]}><Input.TextArea rows={4} maxLength={500} showCount /></Form.Item></Form>
      </Modal>
    </Space>
  );
}

export function AuditPage({ session, onSessionLost }: SessionProps) {
  const [items, setItems] = useState<AuditItem[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  const [action, setAction] = useState('');
  const [targetType, setTargetType] = useState('');
  const [actorAdminId, setActorAdminId] = useState('');

  async function load() {
    setLoading(true); setError('');
    try { setItems(await apiClient.listAudit({ action, targetType, actorAdminId })); }
    catch (caught) { handleError(caught, onSessionLost, setError); }
    finally { setLoading(false); }
  }
  useEffect(() => { if (session.admin.role !== 'MODERATOR') void load(); }, []);

  if (session.admin.role === 'MODERATOR') return <Alert type="warning" showIcon message="当前 MODERATOR 角色无权浏览全量管理员安全审计。" />;
  return (
    <Space direction="vertical" size={18} className="page-stack">
      <div className="page-heading"><div><Typography.Title level={2}>安全审计</Typography.Title><Typography.Paragraph type="secondary">管理员敏感操作与拒绝事件，支持按动作、目标类型和管理员 ID 服务端筛选。</Typography.Paragraph></div><Button onClick={() => void load()} loading={loading}>刷新</Button></div>
      {error ? <Alert type="error" showIcon message={error} /> : null}
      <form className="filter-bar" onSubmit={(event)=>{event.preventDefault();void load();}}>
        <Input value={action} onChange={(event)=>setAction(event.target.value)} placeholder="动作，如 USER_SUSPEND" className="filter-search" allowClear />
        <Input value={targetType} onChange={(event)=>setTargetType(event.target.value)} placeholder="目标类型，如 USER" style={{width:200}} allowClear />
        <Input value={actorAdminId} onChange={(event)=>setActorAdminId(event.target.value)} placeholder="管理员 UUID" style={{width:300}} allowClear />
        <Button type="primary" htmlType="submit" loading={loading}>筛选</Button>
      </form>
      <Table rowKey="id" loading={loading} dataSource={items} pagination={false} scroll={{ x: 1100 }} columns={[
        { title: '动作', dataIndex: 'action', width: 240, render: (value: string) => <Typography.Text strong>{value}</Typography.Text> },
        { title: '角色', dataIndex: 'actorRole', width: 150, render: (value?: string) => <Tag>{value || 'SYSTEM'}</Tag> },
        { title: '目标', key: 'target', width: 260, render: (_, item) => `${item.targetType || '—'} ${item.targetId || ''}` },
        { title: '原因', dataIndex: 'reason', ellipsis: true, render: (value?: string) => value || '—' },
        { title: 'IP', dataIndex: 'clientIp', width: 150, render: (value?: string) => value || '—' },
        { title: '时间', dataIndex: 'createdAt', width: 180, render: formatTime },
      ]} />
    </Space>
  );
}

export function AdminSessionsPage({ onSessionLost }: SessionProps) {
  const [items, setItems] = useState<AdminSessionItem[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  const [recoveryCodes, setRecoveryCodes] = useState<string[]>([]);
  const [form] = Form.useForm<{ code: string }>();

  async function load() {
    setLoading(true); setError('');
    try { setItems(await apiClient.listAdminSessions()); }
    catch (caught) { handleError(caught, onSessionLost, setError); }
    finally { setLoading(false); }
  }
  useEffect(() => { void load(); }, []);

  async function revoke(item: AdminSessionItem) {
    Modal.confirm({
      title: item.current ? '撤销当前管理员会话？' : '撤销该管理员会话？',
      content: item.current ? '当前页面会立即退出。' : `${item.clientIp || 'unknown'} · ${item.userAgent || 'unknown user agent'}`,
      okText: '撤销', okButtonProps: { danger: true },
      onOk: async () => {
        await apiClient.revokeAdminSession(item.id);
        if (item.current) onSessionLost(); else await load();
      },
    });
  }

  async function regenerate() {
    const { code } = await form.validateFields();
    setLoading(true);
    try { setRecoveryCodes(await apiClient.regenerateRecoveryCodes(code)); form.resetFields(); }
    catch (caught) { handleError(caught, onSessionLost, setError); }
    finally { setLoading(false); }
  }

  return (
    <Space direction="vertical" size={18} className="page-stack">
      <PageHeading title="管理员会话" description="查看、撤销后台会话并管理一次性恢复码。" />
      {error ? <Alert type="error" showIcon message={error} /> : null}
      <Table rowKey="id" loading={loading} dataSource={items} pagination={false} scroll={{ x: 900 }} columns={[
        { title: '会话', key: 'session', render: (_, item) => <Space><Tag color={item.current ? 'blue' : 'default'}>{item.current ? 'CURRENT' : 'SESSION'}</Tag><Typography.Text copyable>{item.id}</Typography.Text></Space> },
        { title: '来源', key: 'client', width: 300, render: (_, item) => <div>{item.clientIp || 'unknown'}<br /><Typography.Text type="secondary" ellipsis>{item.userAgent || 'unknown'}</Typography.Text></div> },
        { title: '最后活动', dataIndex: 'lastSeenAt', width: 180, render: formatTime },
        { title: '状态', key: 'status', width: 110, render: (_, item) => <Tag color={item.revokedAt ? 'red' : 'green'}>{item.revokedAt ? 'REVOKED' : 'ACTIVE'}</Tag> },
        { title: '操作', key: 'actions', width: 120, render: (_, item) => item.revokedAt ? '—' : <Button danger size="small" onClick={() => void revoke(item)}>撤销</Button> },
      ]} />
      <div className="recovery-panel">
        <Typography.Title level={4}>重新生成恢复码</Typography.Title>
        <Typography.Paragraph type="secondary">需要新的 TOTP。生成后旧恢复码立即全部失效。</Typography.Paragraph>
        <Form form={form} layout="inline"><Form.Item name="code" rules={[{ required: true, pattern: /^\d{6}$/, message: '输入 6 位 TOTP' }]}><Input placeholder="6 位 TOTP" inputMode="numeric" maxLength={6} /></Form.Item><Button type="primary" onClick={() => void regenerate()} loading={loading}>重新生成</Button></Form>
        {recoveryCodes.length ? <Alert className="recovery-alert" type="warning" showIcon message="新的恢复码只显示本次" description={<Space wrap>{recoveryCodes.map((code) => <Typography.Text code copyable key={code}>{code}</Typography.Text>)}</Space>} /> : null}
      </div>
    </Space>
  );
}

function PageHeading({ title, description }: { title: string; description: string }) { return <div className="page-heading"><div><Typography.Title level={2}>{title}</Typography.Title><Typography.Paragraph type="secondary">{description}</Typography.Paragraph></div></div>; }
function ReportTag({ value }: { value: string }) { const color = value === 'PENDING' ? 'orange' : value === 'IN_REVIEW' ? 'blue' : value === 'RESOLVED' ? 'green' : 'default'; return <Tag color={color}>{value}</Tag>; }
function formatTime(value?: string): string { return value ? new Date(value).toLocaleString() : '—'; }
function handleError(error: unknown, onSessionLost: () => void, setError: (value: string) => void) { if (error instanceof ApiError && error.status === 401) onSessionLost(); setError(error instanceof ApiError ? `${error.code}: ${error.message}` : error instanceof Error ? error.message : '未知网络错误'); }
