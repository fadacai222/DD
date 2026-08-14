import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { BrowserRouter } from 'react-router-dom';
import { App as AntdApp, ConfigProvider } from 'antd';
import zhCN from 'antd/locale/zh_CN';
import { App } from './App';
import { ErrorBoundary } from './components/ErrorBoundary';
import './styles.css';

const root = document.getElementById('root');
if (!root) throw new Error('Missing #root mount point');

createRoot(root).render(
  <StrictMode>
    <ErrorBoundary>
      <ConfigProvider
        locale={zhCN}
        theme={{
          token: {
            colorPrimary: '#16794f',
            colorInfo: '#16794f',
            borderRadius: 8,
            fontFamily: 'Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif',
          },
          components: {
            Layout: { headerBg: '#ffffff', siderBg: '#111915', bodyBg: '#f4f6f5' },
            Menu: { darkItemBg: '#111915', darkSubMenuItemBg: '#111915', darkItemSelectedBg: '#1f7657' },
          },
        }}
      >
        <AntdApp>
          <BrowserRouter basename="/admin">
            <App />
          </BrowserRouter>
        </AntdApp>
      </ConfigProvider>
    </ErrorBoundary>
  </StrictMode>,
);
