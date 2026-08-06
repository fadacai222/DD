import 'package:flutter/material.dart';

import 'realtime_debug_controller.dart';
import 'widgets/event_log_panel.dart';
import 'widgets/realtime_settings_panel.dart';

class RealtimeDebugPage extends StatefulWidget {
  const RealtimeDebugPage({this.controller, super.key});

  final RealtimeDebugController? controller;

  @override
  State<RealtimeDebugPage> createState() => _RealtimeDebugPageState();
}

class _RealtimeDebugPageState extends State<RealtimeDebugPage> {
  late final RealtimeDebugController _controller;
  late final TextEditingController _serverUrlController;
  late final bool _ownsController;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? RealtimeDebugController();
    _serverUrlController = TextEditingController(
      text: 'http://127.0.0.1:18473',
    );
  }

  @override
  void dispose() {
    _serverUrlController.dispose();
    if (_ownsController) {
      _controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('OpenIMX'),
            Text(
              'Realtime transport verification',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w400),
            ),
          ],
        ),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 18),
            child: Center(child: Text('P0 · v0.1.0')),
          ),
        ],
      ),
      body: SafeArea(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            return LayoutBuilder(
              builder: (context, constraints) {
                final isDesktopLayout = constraints.maxWidth >= 960;
                final contentPadding = constraints.maxWidth < 480 ? 12.0 : 20.0;

                if (isDesktopLayout) {
                  return Padding(
                    padding: EdgeInsets.all(contentPadding),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          width: 420,
                          child: SingleChildScrollView(
                            child: RealtimeSettingsPanel(
                              controller: _controller,
                              serverUrlController: _serverUrlController,
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: EventLogPanel(
                            logs: _controller.logs,
                            onClear: _controller.clearLogs,
                          ),
                        ),
                      ],
                    ),
                  );
                }

                return ListView(
                  padding: EdgeInsets.all(contentPadding),
                  children: [
                    RealtimeSettingsPanel(
                      controller: _controller,
                      serverUrlController: _serverUrlController,
                    ),
                    const SizedBox(height: 14),
                    EventLogPanel(
                      logs: _controller.logs,
                      onClear: _controller.clearLogs,
                      compact: true,
                    ),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }
}
