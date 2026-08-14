import { Alert, Button, Card, Col, Row, Skeleton, Space, Tag, Typography } from 'antd';
import { useEffect, useState } from 'react';
import { ApiError, apiClient, type ServiceHealthItem } from '../api/client';

export function ServiceHealthPage() {
  const [items, setItems] = useState<ServiceHealthItem[]>([]);
  const [generatedAt, setGeneratedAt] = useState('');
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');

  async function load() {
    setLoading(true); setError('');
    try {
      const response = await apiClient.getServiceHealth();
      setItems(response.items); setGeneratedAt(response.generatedAt);
    } catch (caught) {
      setError(caught instanceof ApiError ? `${caught.code}: ${caught.message}` : caught instanceof Error ? caught.message : '未知网络错误');
    } finally { setLoading(false); }
  }
  useEffect(() => { void load(); }, []);

  return (
    <Space direction="vertical" size={18} className="page-stack">
      <div className="page-heading">
        <div><Typography.Title level={2}>服务健康</Typography.Title><Typography.Paragraph type="secondary">区分“实际健康检查”“仅已配置”和“当前无法证明”，避免把配置存在误报成服务正常。</Typography.Paragraph></div>
        <Button onClick={() => void load()} loading={loading}>重新检查</Button>
      </div>
      {error ? <Alert type="error" showIcon message={error} /> : null}
      {loading && items.length === 0 ? <Skeleton active /> : (
        <Row gutter={[16, 16]}>
          {items.map((item) => <Col xs={24} md={12} xl={8} key={item.name}><Card className="service-card"><div className="service-card-title"><Typography.Text strong>{item.name}</Typography.Text><HealthTag status={item.status} /></div><Typography.Paragraph type="secondary">{item.detail || '—'}</Typography.Paragraph><Typography.Text type="secondary" className="service-check-time">{item.checkedAt ? new Date(item.checkedAt).toLocaleString() : '未检查'}</Typography.Text></Card></Col>)}
        </Row>
      )}
      <Alert type="warning" showIcon message="TURN_RELAY 显示 UNKNOWN 是有意设计" description="配置存在、端口可达都不能证明真实客户端成功经 TURN relay 建链；后续需要接远端探针或真实会话验证。" />
      {generatedAt ? <Typography.Text type="secondary">快照：{new Date(generatedAt).toLocaleString()}</Typography.Text> : null}
    </Space>
  );
}

function HealthTag({ status }: { status: ServiceHealthItem['status'] }) {
  const color = status === 'UP' ? 'green' : status === 'DOWN' ? 'red' : status === 'CONFIGURED' ? 'blue' : status === 'NOT_CONFIGURED' ? 'orange' : 'default';
  return <Tag color={color}>{status}</Tag>;
}
