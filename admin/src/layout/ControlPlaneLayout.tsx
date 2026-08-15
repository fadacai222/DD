import {
  AuditOutlined,
  CloudServerOutlined,
  DashboardOutlined,
  LogoutOutlined,
  DatabaseOutlined,
  MessageOutlined,
  PhoneOutlined,
  SafetyCertificateOutlined,
  SendOutlined,
  SettingOutlined,
  TeamOutlined,
  UserOutlined,
} from '@ant-design/icons';
import { Avatar, Button, Layout, Menu, Space, Tag, Typography } from 'antd';
import { Outlet, useLocation, useNavigate } from 'react-router-dom';
import { apiClient, type AdminSession } from '../api/client';

const { Header, Content, Sider } = Layout;

interface Props {
  session: AdminSession;
  onSessionLost(): void;
}

const menuItems = [
  { key: '/', icon: <DashboardOutlined />, label: '运营总览' },
  { key: '/users', icon: <UserOutlined />, label: '用户管理' },
  { key: '/groups', icon: <TeamOutlined />, label: '群组管理' },
  { key: '/moments', icon: <MessageOutlined />, label: '朋友圈' },
  { key: '/reports', icon: <SafetyCertificateOutlined />, label: '举报治理' },
  { key: '/storage', icon: <DatabaseOutlined />, label: '媒体与存储' },
  { key: '/push', icon: <SendOutlined />, label: 'Push 运营' },
  { key: '/rtc', icon: <PhoneOutlined />, label: 'LiveKit / RTC' },
  { key: '/services', icon: <CloudServerOutlined />, label: '服务健康' },
  { key: '/audit', icon: <AuditOutlined />, label: '安全审计' },
  { key: '/admins', icon: <SafetyCertificateOutlined />, label: '管理员账号' },
  { key: '/sessions', icon: <SafetyCertificateOutlined />, label: '管理员会话' },
  { key: '/integrations', icon: <CloudServerOutlined />, label: '集成服务' },
  { key: '/settings', icon: <SettingOutlined />, label: '系统设置' },
];

export function ControlPlaneLayout({ session, onSessionLost }: Props) {
  const location = useLocation();
  const navigate = useNavigate();
  const selectedKey = menuItems.find((item) => item.key !== '/' && location.pathname.startsWith(item.key))?.key ?? '/';

  async function logout() {
    try {
      await apiClient.logoutAdmin();
    } finally {
      onSessionLost();
      navigate('/login', { replace: true });
    }
  }

  return (
    <Layout className="control-plane-layout">
      <Sider className="control-plane-sider" width={224} breakpoint="lg" collapsedWidth={72}>
        <div className="control-plane-brand" role="banner">
          <div className="control-plane-logo">DD</div>
          <div className="control-plane-brand-copy">
            <strong>Control Plane</strong>
            <span>Self-hosted operations</span>
          </div>
        </div>
        <Menu
          className="control-plane-menu"
          theme="dark"
          mode="inline"
          selectedKeys={[selectedKey]}
          items={menuItems}
          onClick={({ key }) => navigate(key)}
        />
      </Sider>
      <Layout>
        <Header className="control-plane-header">
          <div>
            <Typography.Text strong>DD 管理后台</Typography.Text>
            <Typography.Text type="secondary" className="control-plane-header-subtitle">正式运营与治理控制面</Typography.Text>
          </div>
          <Space size={12}>
            <Tag>{roleLabel(session.admin.role)}</Tag>
            <Space size={8} className="control-plane-admin-identity">
              <Avatar size="small" icon={<UserOutlined />} />
              <Typography.Text>{session.admin.email}</Typography.Text>
            </Space>
            <Button type="text" icon={<LogoutOutlined />} onClick={() => void logout()}>退出</Button>
          </Space>
        </Header>
        <Content className="control-plane-content">
          <Outlet />
        </Content>
      </Layout>
    </Layout>
  );
}

function roleLabel(role: AdminSession['admin']['role']): string {
  if (role === 'SUPER_ADMIN') return 'SUPER ADMIN';
  if (role === 'MODERATOR') return 'MODERATOR';
  return 'READ ONLY';
}
