import 'package:flutter/material.dart';

import '../../../core/network/api_client.dart';

typedef InstanceLoader = Future<ApiEnvelope<InstanceInfo>> Function(Uri origin);

class InstanceDiscoveryPage extends StatefulWidget {
  const InstanceDiscoveryPage({this.loader, super.key});

  final InstanceLoader? loader;

  @override
  State<InstanceDiscoveryPage> createState() => _InstanceDiscoveryPageState();
}

class _InstanceDiscoveryPageState extends State<InstanceDiscoveryPage> {
  late final TextEditingController _originController;
  ApiEnvelope<InstanceInfo>? _result;
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _originController = TextEditingController(text: 'http://127.0.0.1:18473');
  }

  @override
  void dispose() {
    _originController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final origin = Uri.tryParse(_originController.text.trim());
    if (origin == null) {
      setState(() => _error = '服务地址格式无效。');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await (widget.loader ?? _defaultLoader)(origin);
      if (!mounted) return;
      setState(() => _result = response);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _result = null;
        _error = _safeError(error);
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<ApiEnvelope<InstanceInfo>> _defaultLoader(Uri origin) async {
    final client = ApiClient(origin: origin);
    try {
      return await client.getInstance();
    } finally {
      client.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final result = _result;
    return Scaffold(
      appBar: AppBar(
        title: const Text('实例发现'),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 18),
            child: Center(child: Text('P1 · API v1')),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '正式实例发现合同',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '读取 /api/v1/instance，验证 API、Realtime、LiveKit 和 requestId。',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    key: const ValueKey('instanceOriginField'),
                    controller: _originController,
                    enabled: !_loading,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                      labelText: '实例地址',
                      hintText: 'http://127.0.0.1:18473',
                      prefixIcon: Icon(Icons.dns_outlined),
                    ),
                  ),
                  const SizedBox(height: 14),
                  FilledButton.icon(
                    key: const ValueKey('loadInstanceButton'),
                    onPressed: _loading ? null : _load,
                    icon: const Icon(Icons.travel_explore_rounded),
                    label: Text(_loading ? '正在读取…' : '读取实例配置'),
                  ),
                  if (_loading) ...[
                    const SizedBox(height: 14),
                    const LinearProgressIndicator(),
                  ],
                ],
              ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 14),
            Card(
              color: theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Text(
                  _error!,
                  style: TextStyle(color: theme.colorScheme.onErrorContainer),
                ),
              ),
            ),
          ],
          if (result != null) ...[
            const SizedBox(height: 14),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _row('实例', result.data.name),
                    _row('API 版本', result.data.apiVersion),
                    _row('API', result.data.apiBaseUrl.toString()),
                    _row('Realtime', result.data.realtimeUrl.toString()),
                    _row('LiveKit', result.data.liveKitUrl.toString()),
                    _row('通话', result.data.features.calls ? '启用' : '关闭'),
                    _row(
                      '注册策略',
                      _registrationModeLabel(
                        result.data.features.registrationMode,
                      ),
                    ),
                    _row('Request ID', result.requestId),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 92, child: Text(label)),
          Expanded(
            child: SelectableText(
              value,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  static String _registrationModeLabel(String mode) => switch (mode) {
    'open' => '开放注册',
    'invite' => '邀请码注册',
    'approval' => '审批注册',
    'closed' => '关闭注册',
    _ => mode,
  };

  static String _safeError(Object error) {
    final normalized = error.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    return normalized.length <= 300
        ? normalized
        : '${normalized.substring(0, 297)}…';
  }
}
