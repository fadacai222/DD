import { Alert, Button, Card, Col, Row, Skeleton, Space, Statistic, Table, Tag, Typography } from 'antd';
import { useEffect, useState } from 'react';
import { ApiError, apiClient, type PushSnapshot, type RTCSnapshot, type StorageSnapshot } from '../api/client';

export function StoragePage() {
  const [data, setData] = useState<StorageSnapshot | null>(null);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);
  async function load() { setLoading(true); setError(''); try { setData(await apiClient.getStorageSnapshot()); } catch (caught) { setError(formatError(caught)); } finally { setLoading(false); } }
  useEffect(() => { void load(); }, []);
  return <Space direction="vertical" size={18} className="page-stack">
    <Heading title="媒体与存储" description="只展示对象统计与安全清理候选，不提供任意 S3 key 浏览/删除。" action={<Button onClick={() => void load()} loading={loading}>刷新</Button>} />
    {error ? <Alert type="error" showIcon message={error} /> : null}
    {!data ? <Skeleton active /> : <>
      <Row gutter={[16,16]}>
        <Metric title="READY 对象" value={data.readyObjects} />
        <Metric title="READY 大小" value={formatBytes(data.readyBytes)} />
        <Metric title="上传中" value={data.uploadingObjects} />
        <Metric title="失败" value={data.failedObjects} />
        <Metric title="隔离" value={data.quarantinedObjects} />
        <Metric title="过期未完成上传" value={data.expiredIncompleteUploads} />
      </Row>
      <Card title="按用途占用">
        <Table rowKey="purpose" size="small" pagination={false} dataSource={data.byPurpose} columns={[
          { title:'用途', dataIndex:'purpose', render:(v:string)=><Tag>{v}</Tag> },
          { title:'对象数', dataIndex:'objectCount', align:'right' },
          { title:'大小', dataIndex:'bytes', align:'right', render:(v:number)=>formatBytes(v) },
        ]}/>
      </Card>
      <Alert type="info" showIcon message="安全清理仍未开放" description="后续只会开放明确的过期上传/失败对象清理策略，不会提供任意对象路径删除。" />
    </>}
  </Space>;
}

export function PushPage() {
  const [data, setData] = useState<PushSnapshot | null>(null);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);
  async function load() { setLoading(true); setError(''); try { setData(await apiClient.getPushSnapshot()); } catch (caught) { setError(formatError(caught)); } finally { setLoading(false); } }
  useEffect(() => { void load(); }, []);
  return <Space direction="vertical" size={18} className="page-stack">
    <Heading title="Push 运营" description="查看队列、重试和 endpoint 状态；不提供按用户 ID 任意群发 Push。" action={<Button onClick={() => void load()} loading={loading}>刷新</Button>} />
    {error ? <Alert type="error" showIcon message={error} /> : null}
    {!data ? <Skeleton active /> : <>
      <Row gutter={[16,16]}>
        <Metric title="待处理" value={data.pendingJobs} />
        <Metric title="重试中" value={data.retryingJobs} />
        <Metric title="24h 已发送" value={data.sentJobs24h} />
        <Metric title="24h 已丢弃" value={data.droppedJobs24h} />
        <Metric title="24h endpoint 失败" value={data.endpointFailures24h} />
        <Metric title="最老待处理" value={data.oldestPendingAt ? ageLabel(data.oldestPendingAt) : '—'} />
      </Row>
      <Card title="设备 Push Endpoint">
        <Table rowKey={(row)=>`${row.provider}-${row.status}`} size="small" pagination={false} dataSource={data.endpoints} columns={[
          { title:'Provider', dataIndex:'provider' },
          { title:'状态', dataIndex:'status', render:(v:string)=><Tag color={v==='ACTIVE'?'green':v==='INVALID'?'red':'default'}>{v}</Tag> },
          { title:'数量', dataIndex:'count', align:'right' },
        ]}/>
      </Card>
      <Alert type="info" showIcon message="Provider 凭据状态仍由 Worker 持有" description="这里不把 API 进程“已初始化 Push service”冒充成 FCM/APNs 真实发送成功。后续接 Worker heartbeat/provider self-test。" />
    </>}
  </Space>;
}

export function RTCPage() {
  const [data, setData] = useState<RTCSnapshot | null>(null);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);
  async function load() { setLoading(true); setError(''); try { setData(await apiClient.getRTCSnapshot()); } catch (caught) { setError(formatError(caught)); } finally { setLoading(false); } }
  useEffect(() => { void load(); }, []);
  return <Space direction="vertical" size={18} className="page-stack">
    <Heading title="LiveKit / RTC" description="通话业务状态来自 DD 数据库；TURN 是否真正 relay 仍必须通过真实远端链路验证。" action={<Button onClick={() => void load()} loading={loading}>刷新</Button>} />
    {error ? <Alert type="error" showIcon message={error} /> : null}
    {!data ? <Skeleton active /> : <>
      <Row gutter={[16,16]}>
        <Metric title="今日单聊通话" value={data.directCallsToday} />
        <Metric title="进行中单聊" value={data.activeDirectCalls} />
        <Metric title="24h 已接通" value={data.acceptedDirectCalls24h} />
        <Metric title="24h 平均通话" value={`${Math.round(data.averageDirectSeconds24h)} 秒`} />
        <Metric title="今日群通话" value={data.groupCallsToday} />
        <Metric title="活跃群通话 / 人数" value={`${data.activeGroupCalls} / ${data.activeGroupParticipants}`} />
      </Row>
      <Alert type="warning" showIcon message="这不是 TURN relay 成功率" description="数据库通话状态可以证明 DD 呼叫状态机推进，但不能单独证明客户端媒体最终是否经 TURN/UDP/TCP 成功传输。" />
    </>}
  </Space>;
}

function Heading({title,description,action}:{title:string;description:string;action?:React.ReactNode}) { return <div className="page-heading"><div><Typography.Title level={2}>{title}</Typography.Title><Typography.Paragraph type="secondary">{description}</Typography.Paragraph></div>{action}</div>; }
function Metric({title,value}:{title:string;value:number|string}) { return <Col xs={24} sm={12} xl={8} xxl={4}><Card><Statistic title={title} value={value} /></Card></Col>; }
function formatBytes(bytes:number):string { if(bytes<1024)return `${bytes} B`; const u=['KB','MB','GB','TB']; let v=bytes/1024,i=0; while(v>=1024&&i<u.length-1){v/=1024;i+=1;} return `${v.toFixed(v>=100?0:1)} ${u[i]}`; }
function ageLabel(value:string):string { const seconds=Math.max(0,Math.floor((Date.now()-new Date(value).getTime())/1000)); if(seconds<60)return `${seconds}s`; if(seconds<3600)return `${Math.floor(seconds/60)}m`; return `${Math.floor(seconds/3600)}h`; }
function formatError(error:unknown):string { if(error instanceof ApiError)return `${error.code}: ${error.message}`; return error instanceof Error?error.message:'未知网络错误'; }
