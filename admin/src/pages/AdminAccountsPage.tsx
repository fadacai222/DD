import { Alert, Button, Form, Input, Modal, Select, Space, Table, Tag, Typography } from 'antd';
import { useEffect, useState } from 'react';
import { ApiError, apiClient, type AdminAccountItem, type AdminRole, type AdminSession } from '../api/client';

interface Props { session: AdminSession; onSessionLost(): void; }
type EditState = { item: AdminAccountItem } | null;
type MFAState = { item: AdminAccountItem } | null;

export function AdminAccountsPage({ session, onSessionLost }: Props) {
  const [items, setItems] = useState<AdminAccountItem[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  const [createOpen, setCreateOpen] = useState(false);
  const [editState, setEditState] = useState<EditState>(null);
  const [mfaState, setMFAState] = useState<MFAState>(null);
  const [createForm] = Form.useForm<{ email: string; password: string; role: AdminRole }>();
  const [editForm] = Form.useForm<{ role: AdminRole; status: 'ACTIVE' | 'DISABLED'; reason: string }>();
  const [mfaForm] = Form.useForm<{ reason: string }>();

  async function load() {
    setLoading(true); setError('');
    try { setItems(await apiClient.listAdminAccounts()); }
    catch (caught) { handleError(caught, onSessionLost, setError); }
    finally { setLoading(false); }
  }
  useEffect(() => { if (session.admin.role === 'SUPER_ADMIN') void load(); }, []);

  if (session.admin.role !== 'SUPER_ADMIN') return <Alert type="warning" showIcon message="只有 SUPER_ADMIN 可以管理后台管理员账号。" />;

  async function createAccount() {
    const values = await createForm.validateFields();
    setLoading(true); setError('');
    try {
      const item = await apiClient.createAdminAccount(values.email.trim(), values.password, values.role);
      setItems((current) => [...current, item]);
      createForm.resetFields(); setCreateOpen(false);
    } catch (caught) { handleError(caught, onSessionLost, setError); }
    finally { setLoading(false); }
  }

  async function updateAccount() {
    if (!editState) return;
    const values = await editForm.validateFields();
    setLoading(true); setError('');
    try {
      const updated = await apiClient.updateAdminAccount(editState.item.id, values.role, values.status, values.reason.trim());
      setItems((current) => current.map((item) => item.id === updated.id ? updated : item));
      setEditState(null); editForm.resetFields();
    } catch (caught) { handleError(caught, onSessionLost, setError); }
    finally { setLoading(false); }
  }

  async function resetMFA() {
    if (!mfaState) return;
    const { reason } = await mfaForm.validateFields();
    setLoading(true); setError('');
    try {
      await apiClient.resetAdminMFA(mfaState.item.id, reason.trim());
      setItems((current) => current.map((item) => item.id === mfaState.item.id ? { ...item, mfaEnabled: false, activeSessions: 0 } : item));
      setMFAState(null); mfaForm.resetFields();
    } catch (caught) { handleError(caught, onSessionLost, setError); }
    finally { setLoading(false); }
  }

  function beginEdit(item: AdminAccountItem) {
    editForm.setFieldsValue({ role: item.role, status: item.status, reason: '' });
    setEditState({ item });
  }

  return <Space direction="vertical" size={18} className="page-stack">
    <div className="page-heading">
      <div><Typography.Title level={2}>管理员账号</Typography.Title><Typography.Paragraph type="secondary">创建独立后台账号、调整角色/状态、重置 MFA；所有变更写管理员审计。</Typography.Paragraph></div>
      <Button type="primary" onClick={() => setCreateOpen(true)}>新建管理员</Button>
    </div>
    {error ? <Alert type="error" showIcon message={error} /> : null}
    <Alert type="info" showIcon message="安全保护" description="当前 SUPER_ADMIN 不能自我禁用/降权，也不能移除系统最后一个 ACTIVE SUPER_ADMIN。MFA 重置会撤销目标管理员全部后台会话。" />
    <Table rowKey="id" loading={loading} dataSource={items} pagination={false} scroll={{ x: 1050 }} columns={[
      { title:'管理员', key:'admin', width:260, render:(_,item)=><div><Typography.Text strong>{item.email}</Typography.Text><br/><Typography.Text copyable type="secondary">{item.id}</Typography.Text></div> },
      { title:'角色', dataIndex:'role', width:170, render:(v:string)=><Tag color={v==='SUPER_ADMIN'?'purple':v==='MODERATOR'?'blue':'default'}>{v}</Tag> },
      { title:'状态', dataIndex:'status', width:110, render:(v:string)=><Tag color={v==='ACTIVE'?'green':'red'}>{v}</Tag> },
      { title:'MFA', dataIndex:'mfaEnabled', width:90, render:(v:boolean)=><Tag color={v?'green':'orange'}>{v?'ENABLED':'PENDING'}</Tag> },
      { title:'活跃会话', dataIndex:'activeSessions', width:100, align:'right' },
      { title:'最近登录', dataIndex:'lastLoginAt', width:180, render:formatTime },
      { title:'操作', key:'actions', width:210, fixed:'right', render:(_,item)=><Space>
        <Button size="small" onClick={()=>beginEdit(item)}>编辑</Button>
        <Button size="small" disabled={item.id===session.admin.id || !item.mfaEnabled} onClick={()=>setMFAState({item})}>重置 MFA</Button>
      </Space> },
    ]}/>

    <Modal title="新建管理员" open={createOpen} onCancel={()=>{setCreateOpen(false);createForm.resetFields();}} onOk={()=>void createAccount()} confirmLoading={loading} okText="创建">
      <Form form={createForm} layout="vertical" initialValues={{role:'SUPPORT_READ_ONLY'}}>
        <Form.Item name="email" label="管理员邮箱" rules={[{required:true,type:'email'}]}><Input autoComplete="off" /></Form.Item>
        <Form.Item name="password" label="初始密码" extra="至少 14 个字符；首次登录仍必须绑定 TOTP。" rules={[{required:true,min:14,max:1024}]}><Input.Password autoComplete="new-password" /></Form.Item>
        <Form.Item name="role" label="角色" rules={[{required:true}]}><Select options={roleOptions}/></Form.Item>
      </Form>
    </Modal>

    <Modal title="编辑管理员" open={Boolean(editState)} onCancel={()=>{setEditState(null);editForm.resetFields();}} onOk={()=>void updateAccount()} confirmLoading={loading} okText="保存">
      <Form form={editForm} layout="vertical">
        <Form.Item name="role" label="角色" rules={[{required:true}]}><Select options={roleOptions}/></Form.Item>
        <Form.Item name="status" label="状态" rules={[{required:true}]}><Select options={[{value:'ACTIVE',label:'ACTIVE'},{value:'DISABLED',label:'DISABLED'}]}/></Form.Item>
        <Form.Item name="reason" label="变更原因" rules={[{required:true,min:3,max:500}]}><Input.TextArea rows={3} showCount maxLength={500}/></Form.Item>
      </Form>
    </Modal>

    <Modal title="重置 MFA" open={Boolean(mfaState)} onCancel={()=>{setMFAState(null);mfaForm.resetFields();}} onOk={()=>void resetMFA()} confirmLoading={loading} okButtonProps={{danger:true}} okText="重置并撤销会话">
      <Alert type="warning" showIcon message={`目标管理员：${mfaState?.item.email ?? ''}`} description="其 TOTP、恢复码和全部活跃后台会话都会失效；下次登录必须重新绑定 MFA。" />
      <Form form={mfaForm} layout="vertical" className="modal-form"><Form.Item name="reason" label="重置原因" rules={[{required:true,min:3,max:500}]}><Input.TextArea rows={3} showCount maxLength={500}/></Form.Item></Form>
    </Modal>
  </Space>;
}

const roleOptions = [
  { value:'SUPER_ADMIN', label:'SUPER_ADMIN · 全部控制权限' },
  { value:'MODERATOR', label:'MODERATOR · 举报治理' },
  { value:'SUPPORT_READ_ONLY', label:'SUPPORT_READ_ONLY · 只读支持/审计' },
];
function formatTime(value?:string):string { return value?new Date(value).toLocaleString():'—'; }
function handleError(error:unknown,onSessionLost:()=>void,setError:(value:string)=>void){ if(error instanceof ApiError&&error.status===401)onSessionLost(); setError(error instanceof ApiError?`${error.code}: ${error.message}`:error instanceof Error?error.message:'未知网络错误'); }
