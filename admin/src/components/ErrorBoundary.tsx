import { Component, type ErrorInfo, type ReactNode } from 'react';

interface Props {
  children: ReactNode;
}

interface State {
  error: Error | null;
}

export class ErrorBoundary extends Component<Props, State> {
  state: State = { error: null };

  static getDerivedStateFromError(error: Error): State {
    return { error };
  }

  componentDidCatch(error: Error, info: ErrorInfo): void {
    console.error('DD admin render failure', error, info.componentStack);
  }

  render(): ReactNode {
    if (this.state.error) {
      return (
        <main className="fatal-shell">
          <section className="panel fatal-panel">
            <p className="eyebrow">DD Admin</p>
            <h1>页面渲染失败</h1>
            <p>错误已被隔离，没有继续渲染可能损坏状态的页面。</p>
            <button type="button" onClick={() => window.location.reload()}>
              重新加载
            </button>
          </section>
        </main>
      );
    }
    return this.props.children;
  }
}
