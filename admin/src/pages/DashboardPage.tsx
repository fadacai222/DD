import { CloudOutlined, MessageOutlined, PhoneOutlined, TeamOutlined, UserOutlined } from '@ant-design/icons';
import { Alert, Card, Col, Row, Skeleton, Space, Statistic, Table, Tag, Typography } from 'antd';
import { useEffect, useState } from 'react';
import { ApiError, apiClient, type DashboardSnapshot } from '../api/client';

export function DashboardPage() {
  const [data, setData] = useState<DashboardSnapshot | null>(null);
  const [error, setError] = useState('');

  useEffect(() => {
    let active = true;
    apiClient.getDashboard()
      .then((value) => { if (active) setData(value); })
      .catch((caught) => { if (active) setError(formatError(caught)); });
    return () => { active = false; };
  }, []);

  if (error) return <Alert type="error" showIcon message="总览加载失败" description={error} />;
  if (!data) return <Skeleton active paragraph={{ rows: 10 }} />;

  const { summary } = data;
  return (
    <Space direction="vertical" size={20} className="page-stack">
      <div className="page-heading">
        <div>
          <Typography.Title level={2}>运营总览</Typography.Title>
          <Typography.Paragraph type="secondary">真实生产数据快照 · {new Date(data.generatedAt).toLocaleString()}</Typography.Paragraph>
        </div>
        <Tag color="blue">近实时</Tag>
      </div>

      <Row gutter={[16, 16]}>
        <Metric title="总用户" value={summary.totalUsers} suffix={`今日 +${summary.todayRegistrations}`} icon={<UserOutlined />} />
        <Metric title="在线用户" value={summary.onlineUsers} suffix="近 5 分钟" icon={<TeamOutlined />} />
        <Metric title="今日消息" value={summary.todayMessages} suffix={`累计 ${formatNumber(summary.totalMessages)}`} icon={<MessageOutlined />} />
        <Metric title="今日通话" value={summary.todayCalls} suffix={`进行中 ${summary.activeCalls}`} icon={<PhoneOutlined />} />
        <Metric title="活跃设备" value={summary.activeDevices24h} suffix="过去 24 小时" icon={<CloudOutlined />} />
        <Metric title="活跃群组" value={summary.totalGroups} suffix={`朋友圈 ${summary.totalMoments}`} icon={<TeamOutlined />} />
      </Row>

      <Row gutter={[16, 16]}>
        <Col xs={24} xl={16}>
          <Card title="14 天业务趋势" extra={<Typography.Text type="secondary">UTC 日界线</Typography.Text>}>
            <div className="trend-chart-grid">
              <TrendChart title="消息量" items={data.trend} field="messages" />
              <TrendChart title="新注册" items={data.trend} field="registrations" />
            </div>
            <Table
              className="trend-detail-table"
              size="small"
              rowKey="date"
              pagination={false}
              dataSource={data.trend}
              scroll={{ x: 620 }}
              columns={[
                { title: '日期', dataIndex: 'date', width: 120 },
                { title: '注册', dataIndex: 'registrations', align: 'right' },
                { title: '消息', dataIndex: 'messages', align: 'right' },
                { title: '通话', dataIndex: 'calls', align: 'right' },
                { title: '朋友圈', dataIndex: 'moments', align: 'right' },
              ]}
            />
          </Card>
        </Col>
        <Col xs={24} xl={8}>
          <Space direction="vertical" size={16} className="page-stack">
            <Card title="异步队列">
              <QueueRow label="Push 待处理" value={summary.pendingPushJobs} />
              <QueueRow label="语音转文字" value={summary.pendingVoiceTranscriptions} />
              <QueueRow label="Outbox 待发布" value={summary.pendingOutboxEvents} />
            </Card>
            <Card title="媒体存储">
              <Statistic title="READY 对象" value={summary.mediaObjects} />
              <Statistic title="逻辑大小" value={formatBytes(summary.mediaBytes)} />
            </Card>
          </Space>
        </Col>
      </Row>

      <Alert
        type="info"
        showIcon
        message="在线用户口径"
        description={`当前口径：${data.presenceDefinition}。它是设备活跃度近似值，不冒充 WebSocket 在线连接数。`}
      />
    </Space>
  );
}

function Metric({ title, value, suffix, icon }: { title: string; value: number; suffix: string; icon: React.ReactNode }) {
  return (
    <Col xs={24} sm={12} xl={8} xxl={4}>
      <Card className="metric-card">
        <Space align="start" className="metric-card-content">
          <div className="metric-icon">{icon}</div>
          <div>
            <Statistic title={title} value={value} />
            <Typography.Text type="secondary">{suffix}</Typography.Text>
          </div>
        </Space>
      </Card>
    </Col>
  );
}

function QueueRow({ label, value }: { label: string; value: number }) {
  return <div className="queue-row"><Typography.Text>{label}</Typography.Text><Tag color={value > 0 ? 'orange' : 'green'}>{value}</Tag></div>;
}

function TrendChart({ title, items, field }: { title: string; items: DashboardSnapshot['trend']; field: 'messages' | 'registrations' }) {
  const width = 560;
  const height = 140;
  const values = items.map((item) => item[field]);
  const max = Math.max(1, ...values);
  const coordinates = items.map((item, index) => {
    const value = item[field];
    const x = items.length <= 1 ? width / 2 : (index / (items.length - 1)) * width;
    const y = height - (value / max) * (height - 22) - 8;
    return { date: item.date, value, x: x.toFixed(1), y: y.toFixed(1) };
  });
  const points = coordinates.map((point) => `${point.x},${point.y}`).join(' ');
  return (
    <div className="trend-chart-card">
      <div className="trend-chart-header"><Typography.Text strong>{title}</Typography.Text><Typography.Text type="secondary">峰值 {formatNumber(max)}</Typography.Text></div>
      <svg className="trend-chart" viewBox={`0 0 ${width} ${height}`} role="img" aria-label={`${title} 14 天趋势`} preserveAspectRatio="none">
        <line x1="0" y1={height - 8} x2={width} y2={height - 8} className="trend-grid-line" />
        <polyline points={points} className="trend-line" />
        {coordinates.map((point) => <circle key={`${point.date}-${field}`} cx={point.x} cy={point.y} r="3.5" className="trend-point"><title>{`${point.date}: ${point.value}`}</title></circle>)}
      </svg>
      <div className="trend-axis"><span>{items[0]?.date.slice(5) ?? '—'}</span><span>{items.at(-1)?.date.slice(5) ?? '—'}</span></div>
    </div>
  );
}

function formatNumber(value: number): string { return new Intl.NumberFormat('zh-CN').format(value); }
function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  const units = ['KB', 'MB', 'GB', 'TB'];
  let value = bytes / 1024;
  let unit = units[0];
  for (let index = 1; index < units.length && value >= 1024; index += 1) { value /= 1024; unit = units[index]; }
  return `${value.toFixed(value >= 100 ? 0 : 1)} ${unit}`;
}
function formatError(error: unknown): string {
  if (error instanceof ApiError) return `${error.code}: ${error.message}${error.requestId ? ` · ${error.requestId}` : ''}`;
  return error instanceof Error ? error.message : '未知网络错误';
}
