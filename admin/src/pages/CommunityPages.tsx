import { Alert, Button, Input, Select, Space, Table, Tag, Typography } from 'antd';
import { useEffect, useState } from 'react';
import { ApiError, apiClient, type GroupItem, type MomentItem } from '../api/client';

export function GroupsPage() {
  const [items, setItems] = useState<GroupItem[]>([]);
  const [query, setQuery] = useState('');
  const [status, setStatus] = useState('');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');

  async function load() {
    setLoading(true); setError('');
    try { setItems(await apiClient.listGroups(query, status)); }
    catch (caught) { setError(formatError(caught)); }
    finally { setLoading(false); }
  }
  useEffect(() => { void load(); }, []);

  return (
    <Space direction="vertical" size={18} className="page-stack">
      <PageHeading title="群组管理" description="当前先提供真实群元数据、成员规模和状态查询；强制解散将在带原因与审计的治理动作中单独开放。" />
      {error ? <Alert type="error" showIcon message={error} /> : null}
      <form className="filter-bar" onSubmit={(event) => { event.preventDefault(); void load(); }}>
        <Input.Search value={query} onChange={(event) => setQuery(event.target.value)} onSearch={() => void load()} allowClear placeholder="群名 / 创建者 DDID" className="filter-search" />
        <Select value={status} onChange={setStatus} className="filter-select" options={[{ value: '', label: '全部状态' }, { value: 'ACTIVE', label: 'ACTIVE' }, { value: 'DISSOLVED', label: 'DISSOLVED' }]} />
        <Button type="primary" htmlType="submit" loading={loading}>查询</Button>
      </form>
      <Table rowKey="conversationId" loading={loading} dataSource={items} pagination={false} scroll={{ x: 980 }} columns={[
        { title: '群组', key: 'group', width: 260, render: (_, item) => <div><Typography.Text strong>{item.name}</Typography.Text><br /><Typography.Text type="secondary" copyable>{item.conversationId}</Typography.Text></div> },
        { title: '成员', dataIndex: 'memberCount', width: 90, align: 'right' },
        { title: '加入方式', dataIndex: 'joinMode', width: 130, render: (value: string) => <Tag>{value}</Tag> },
        { title: '状态', dataIndex: 'status', width: 110, render: (value: string) => <Tag color={value === 'ACTIVE' ? 'green' : 'default'}>{value}</Tag> },
        { title: '创建者', key: 'creator', width: 160, render: (_, item) => <Typography.Text>@{item.createdByHandle || item.createdByUserId}</Typography.Text> },
        { title: '公告', dataIndex: 'announcement', ellipsis: true, render: (value: string) => value || '—' },
        { title: '更新时间', dataIndex: 'updatedAt', width: 180, render: formatTime },
      ]} />
    </Space>
  );
}

export function MomentsPage() {
  const [items, setItems] = useState<MomentItem[]>([]);
  const [query, setQuery] = useState('');
  const [status, setStatus] = useState('');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');

  async function load() {
    setLoading(true); setError('');
    try { setItems(await apiClient.listMoments(query, status)); }
    catch (caught) { setError(formatError(caught)); }
    finally { setLoading(false); }
  }
  useEffect(() => { void load(); }, []);

  return (
    <Space direction="vertical" size={18} className="page-stack">
      <PageHeading title="朋友圈治理" description="读取朋友圈元数据、作者、媒体/点赞/评论数量；不在后台展示私聊消息正文。" />
      {error ? <Alert type="error" showIcon message={error} /> : null}
      <form className="filter-bar" onSubmit={(event) => { event.preventDefault(); void load(); }}>
        <Input.Search value={query} onChange={(event) => setQuery(event.target.value)} onSearch={() => void load()} allowClear placeholder="正文 / 作者 DDID / 昵称" className="filter-search" />
        <Select value={status} onChange={setStatus} className="filter-select" options={[{ value: '', label: '全部状态' }, { value: 'ACTIVE', label: 'ACTIVE' }, { value: 'DELETED', label: 'DELETED' }]} />
        <Button type="primary" htmlType="submit" loading={loading}>查询</Button>
      </form>
      <Table rowKey="id" loading={loading} dataSource={items} pagination={false} scroll={{ x: 1100 }} columns={[
        { title: '作者', key: 'author', width: 180, render: (_, item) => <div><Typography.Text strong>{item.authorDisplayName}</Typography.Text><br /><Typography.Text type="secondary">@{item.authorHandle}</Typography.Text></div> },
        { title: '内容', dataIndex: 'text', ellipsis: true, width: 360, render: (value: string) => value || <Typography.Text type="secondary">仅媒体</Typography.Text> },
        { title: '可见性', dataIndex: 'visibility', width: 140, render: (value: string) => <Tag>{value}</Tag> },
        { title: '状态', dataIndex: 'status', width: 110, render: (value: string) => <Tag color={value === 'ACTIVE' ? 'green' : 'default'}>{value}</Tag> },
        { title: '媒体', dataIndex: 'mediaCount', width: 70, align: 'right' },
        { title: '点赞', dataIndex: 'likeCount', width: 70, align: 'right' },
        { title: '评论', dataIndex: 'commentCount', width: 70, align: 'right' },
        { title: '发布时间', dataIndex: 'createdAt', width: 180, render: formatTime },
      ]} />
    </Space>
  );
}

function PageHeading({ title, description }: { title: string; description: string }) {
  return <div className="page-heading"><div><Typography.Title level={2}>{title}</Typography.Title><Typography.Paragraph type="secondary">{description}</Typography.Paragraph></div></div>;
}
function formatTime(value?: string): string { return value ? new Date(value).toLocaleString() : '—'; }
function formatError(error: unknown): string {
  if (error instanceof ApiError) return `${error.code}: ${error.message}${error.requestId ? ` · ${error.requestId}` : ''}`;
  return error instanceof Error ? error.message : '未知网络错误';
}
