import 'package:flutter/material.dart';

import '../features/auth/presentation/auth_page.dart';
import '../features/calls/presentation/call_debug_page.dart';
import '../features/calls/presentation/two_party_call_page.dart';
import '../features/foundation/presentation/instance_discovery_page.dart';
import '../features/realtime/presentation/realtime_debug_page.dart';

class DebugConsoleHome extends StatelessWidget {
  const DebugConsoleHome({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('DD'),
            Text(
              'Protocol and media verification console',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w400),
            ),
          ],
        ),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 18),
            child: Center(child: Text('P2 · v0.5.0')),
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final horizontal = constraints.maxWidth >= 760;
            final padding = constraints.maxWidth < 480 ? 14.0 : 24.0;
            final cards = [
              _ConsoleCard(
                icon: Icons.person_add_alt_1_rounded,
                title: '账号注册 / 登录',
                description:
                    '验证 Mailpit 邮箱验证码、注册事务、Argon2id 登录和 Refresh Token 轮换。',
                status: 'P2 账号垂直切片',
                onOpen: () => _open(context, const AuthPage()),
              ),
              _ConsoleCard(
                icon: Icons.travel_explore_outlined,
                title: '实例发现',
                description:
                    '验证正式 /api/v1 实例合同、Realtime/LiveKit 地址与 requestId。',
                status: 'P1 正式网络层',
                onOpen: () => _open(context, const InstanceDiscoveryPage()),
              ),
              _ConsoleCard(
                icon: Icons.hub_outlined,
                title: '实时通信',
                description: '验证 REST、WebSocket 握手、Ping/Pong、事件游标与自动重连。',
                status: '已通过人工验收',
                onOpen: () => _open(context, const RealtimeDebugPage()),
              ),
              _ConsoleCard(
                icon: Icons.video_call_outlined,
                title: '音视频通话',
                description: '验证 LiveKit 短期令牌、麦克风、摄像头、远端轨道与媒体重连。',
                status: '底层媒体已通过',
                onOpen: () => _open(context, const CallDebugPage()),
              ),
              _ConsoleCard(
                icon: Icons.ring_volume_outlined,
                title: '双端通话',
                description: '验证一端呼叫、另一端响铃、接听或拒绝、自动入房与同步挂断。',
                status: '三端人工验收通过',
                onOpen: () => _open(context, const TwoPartyCallPage()),
              ),
            ];

            return Center(
              child: SingleChildScrollView(
                padding: EdgeInsets.all(padding),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 980),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '选择验证模块',
                        style: theme.textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '这些页面只用于清除底层技术风险，不是最终聊天产品界面。',
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 24),
                      if (horizontal)
                        Wrap(
                          spacing: 16,
                          runSpacing: 16,
                          children: [
                            for (final card in cards)
                              SizedBox(
                                width:
                                    (constraints.maxWidth - padding * 2 - 16) /
                                    2,
                                child: card,
                              ),
                          ],
                        )
                      else
                        for (var index = 0; index < cards.length; index++) ...[
                          if (index > 0) const SizedBox(height: 14),
                          cards[index],
                        ],
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  static Future<void> _open(BuildContext context, Widget page) {
    return Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => page));
  }
}

class _ConsoleCard extends StatelessWidget {
  const _ConsoleCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.status,
    required this.onOpen,
  });

  final IconData icon;
  final String title;
  final String description;
  final String status;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(11),
                  child: Icon(
                    icon,
                    size: 28,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                title,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                description,
                style: theme.textTheme.bodyMedium?.copyWith(
                  height: 1.55,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      status,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const Icon(Icons.arrow_forward_rounded),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
