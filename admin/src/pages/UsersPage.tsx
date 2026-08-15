import { CheckCircleOutlined, StopOutlined } from '@ant-design/icons';
import { Alert, Button, Descriptions, Drawer, Form, Input, Modal, Select, Space, Table, Tag, Typography } from 'antd';
import { useCallback, useEffect, useState } from 'react';
import { ApiError, apiClient, type AdminSession, type UserDetail, type UserItem } from '../api/client';

interface Props { session: AdminSession; onSessionLost(): void; }
type PendingAction = { user: UserItem; action: 'suspend' | 'unsuspend' } | null;

export function UsersPage({ session, onSessionLost }: Props) {
  const [items, setItems] = useState<UserItem[]>([]);
  const [query, setQuery] = useState('');
  const [status, setStatus] = useState('');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  const [selected, setSelected] = useState<UserDetail | null>(null);
  const [detailLoading, setDetailLoading] = useState(false);
  const [pendingAction, setPendingAction] = useState<PendingAction>(null);
  const [form] = Form.useForm<{ reason: string }>();

  const load = useCallback(async () => {
    setLoading(true); setError('');
    try { setItems(await apiClient.listUsers(query, status)); }
    catch (caught) { handleError(caught, onSessionLost, setError); }
    finally { setLoading(false); }
  }, [onSessionLost, query, status]);

  useEffect(() => { void load(); }, []); // initial server snapshot; filters submit explicitly

  async function openDetail(user: UserItem) {
    setDetailLoading(true); setError('');
    try { setSelected(await apiClient.getUser(user.id)); }
    catch (caught) { handleError(caught, onSessionLost, setError); }
    finally { setDetailLoading(false); }
  }

  async function confirmModeration() {
    if (!pendingAction) return;
    const { reason } = await form.validateFields();
    setLoading(true); setError('');
    try {
      const updated = await apiClient.moderateUser(pendingAction.user.id, pendingAction.action, reason.trim());
      setItems((current) => current.map((item) => item.id === updated.id ? updated : item));
      setPendingAction(null); form.resetFields();
      if (selected?.id === updated.id) setSelected(await apiClient.getUser(updated.id));
    } catch (caught) { handleError(caught, onSessionLost, setError); }
    finally { setLoading(false); }
  }

  return (
    <Space direction="vertical" size={18} className="page-stack">
      <div className="page-heading"><div><Typography.Title level={2}>用户管理</Typography.Title><Typography.Paragraph type="secondary">账号状态、设备、活跃会话和 Push 状态都从正式库读取。</Typography.Paragraph></div></div>
      {error ? <Alert type="error" showIcon message={error} /> : null}
      <form className="filter-bar" onSubmit={(event) => { event.preventDefault(); void load(); }}>
        <Input.Search value={query} onChange={(event) => setQuery(event.target.value)} onSearch={() => void load()} allowClear placeholder="邮箱 / DDID / 昵称" className="filter-search" />
        <Select value={status} onChange={setStatus} className="filter-select" options={[
          { value: '', label: '全部状态' }, { value: 'ACTIVE', label: 'ACTIVE' }, { value: 'SUSPENDED', label: 'SUSPENDED' },
          { value: 'DELETING', label: 'DELETING' }, { value: 'DELETED', label: 'DELETED' },
        ]} />
        <Button type="primary" htmlType="submit" loading={loading}>查询</Button>
      </form>
      <Table
        rowKey="id"
        loading={loading}
        dataSource={items}
        pagination={false}
        scroll={{ x: 920 }}
        columns={[
          { title: '用户', key: 'user', render: (_, item) => <div><Typography.Text strong>{item.displayName}</Typography.Text><br /><Typography.Text type="secondary">@{item.handle}</Typography.Text></div> },
          { title: '邮箱', dataIndex: 'email', ellipsis: true },
          { title: '状态', dataIndex: 'status', width: 120, render: (value: string) => <StatusTag value={value} /> },
          { title: '注册时间', dataIndex: 'createdAt', width: 180, render: formatTime },
          { title: '操作', key: 'actions', width: 220, fixed: 'right', render: (_, item) => <Space>
            <Button size="small" onClick={() => void openDetail(item)}>详情</Button>
            {session.admin.role === 'SUPER_ADMIN' && item.status === 'ACTIVE' ? <Button danger size="small" icon={<StopOutlined />} onClick={() => setPendingAction({ user: item, action: 'suspend' })}>冻结</Button> : null}
            {session.admin.role === 'SUPER_ADMIN' && item.status === 'SUSPENDED' ? <Button size="small" icon={<CheckCircleOutlined />} onClick={() => setPendingAction({ user: item, action: 'unsuspend' })}>解冻</Button> : null}
          </Space> },
        ]}
      />

      <Drawer title={selected ? `${selected.displayName} · @${selected.handle}` : '用户详情'} width={720} open={Boolean(selected)} loading={detailLoading} onClose={() => setSelected(null)}>
        {selected ? <UserDetailView item={selected} /> : null}
      </Drawer>

      <Modal
        title={pendingAction?.action === 'suspend' ? '冻结账号' : '解除冻结'}
        open={Boolean(pendingAction)}
        okText="确认执行"
        okButtonProps={{ danger: pendingAction?.action === 'suspend', loading }}
        onOk={() => void confirmModeration()}
        onCancel={() => { setPendingAction(null); form.resetFields(); }}
      >
        <Alert type="warning" showIcon message="该操作会进入管理员审计日志。冻结账号同时撤销设备与登录会话。" />
        <Form form={form} layout="vertical" className="modal-form">
          <Form.Item name="reason" label="操作原因" rules={[{ required: true, min: 3, message: '至少填写 3 个字符的原因' }]}>
            <Input.TextArea rows={4} maxLength={500} showCount />
          </Form.Item>
        </Form>
      </Modal>
    </Space>
  );
}

function UserDetailView({ item }: { item: UserDetail }) {
  return (
    <Space direction="vertical" size={18} className="page-stack">
      <Descriptions bordered size="small" column={2} items={[
        { key: 'id', label: '用户 ID', children: <Typography.Text copyable>{item.id}</Typography.Text>, span: 2 },
        { key: 'email', label: '邮箱', children: item.email },
        { key: 'status', label: '状态', children: <StatusTag value={item.status} /> },
        { key: 'bio', label: '简介', children: item.bio || '—', span: 2 },
        { key: 'verified', label: '邮箱验证', children: formatTime(item.emailVerifiedAt) },
        { key: 'created', label: '注册', children: formatTime(item.createdAt) },
      ]} />
      <Descriptions title="业务关系" size="small" column={5} items={[
        { key: 'contacts', label: '好友', children: item.counts.contacts },
        { key: 'groups', label: '群组', children: item.counts.groups },
        { key: 'messages', label: '消息', children: item.counts.messages },
        { key: 'moments', label: '朋友圈', children: item.counts.moments },
        { key: 'sessions', label: '活跃会话', children: item.counts.activeSessions },
      ]} />
      <Typography.Title level={4}>设备与 Push</Typography.Title>
      <Table
        rowKey="id"
        size="small"
        pagination={false}
        dataSource={item.devices}
        scroll={{ x: 720 }}
        columns={[
          { title: '设备', key: 'device', render: (_, device) => <div><Typography.Text strong>{device.name}</Typography.Text><br /><Typography.Text type="secondary">{device.platform} · {device.appVersion || 'unknown'}</Typography.Text></div> },
          { title: '最后活跃', dataIndex: 'lastSeenAt', render: formatTime },
          { title: '设备状态', key: 'deviceStatus', render: (_, device) => <Tag color={device.revokedAt ? 'red' : 'green'}>{device.revokedAt ? 'REVOKED' : 'ACTIVE'}</Tag> },
          { title: 'Push', key: 'push', render: (_, device) => device.push.length ? <Space wrap>{device.push.map((push) => <Tag key={`${push.provider}-${push.environment}`} color={push.status === 'ACTIVE' ? 'green' : 'orange'}>{push.provider} · {push.status}</Tag>)}</Space> : <Typography.Text type="secondary">未注册</Typography.Text> },
        ]}
      />
      <Alert type="info" showIcon message="当前数据库没有独立的“成功登录历史”事实表，因此这里不伪造登录历史；当前展示的是设备最后活跃与有效 refresh session 数。" />
    </Space>
  );
}

function StatusTag({ value }: { value: string }) { return <Tag color={value === 'ACTIVE' ? 'green' : value === 'SUSPENDED' ? 'red' : 'default'}>{value}</Tag>; }
function formatTime(value?: string): string { return value ? new Date(value).toLocaleString() : '—'; }
function handleError(error: unknown, onSessionLost: () => void, setError: (value: string) => void) {
  if (error instanceof ApiError && error.status === 401) onSessionLost();
  setError(error instanceof ApiError ? `${error.code}: ${error.message}` : error instanceof Error ? error.message : '未知网络错误');
}
