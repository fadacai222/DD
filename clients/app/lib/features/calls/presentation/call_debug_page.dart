import 'package:flutter/material.dart';

import 'call_debug_controller.dart';
import 'widgets/call_log_panel.dart';
import 'widgets/call_settings_panel.dart';
import 'widgets/call_video_grid.dart';

class CallDebugPage extends StatefulWidget {
  const CallDebugPage({this.controller, super.key});

  final CallDebugController? controller;

  @override
  State<CallDebugPage> createState() => _CallDebugPageState();
}

class _CallDebugPageState extends State<CallDebugPage> {
  late final CallDebugController _controller;
  late final bool _ownsController;
  late final TextEditingController _apiUrlController;
  late final TextEditingController _roomController;
  late final TextEditingController _identityController;
  late final TextEditingController _nameController;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? CallDebugController();
    final suffix = DateTime.now().millisecondsSinceEpoch.toString().substring(
      7,
    );
    _apiUrlController = TextEditingController(text: 'http://127.0.0.1:18473');
    _roomController = TextEditingController(text: 'call-demo');
    _identityController = TextEditingController(text: 'user-$suffix');
    _nameController = TextEditingController(text: '测试用户 $suffix');
  }

  @override
  void dispose() {
    _apiUrlController.dispose();
    _roomController.dispose();
    _identityController.dispose();
    _nameController.dispose();
    if (_ownsController) {
      _controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 12,
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('音视频通话 PoC'),
            Text(
              'LiveKit room and media verification',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w400),
            ),
          ],
        ),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 18),
            child: Center(child: Text('P0 · v0.3.2')),
          ),
        ],
      ),
      body: SafeArea(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            return LayoutBuilder(
              builder: (context, constraints) {
                final desktop = constraints.maxWidth >= 1000;
                final padding = constraints.maxWidth < 480 ? 12.0 : 18.0;
                if (desktop) {
                  return Padding(
                    padding: EdgeInsets.all(padding),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          width: 410,
                          child: SingleChildScrollView(child: _settingsPanel()),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(
                                child: Card(
                                  child: Padding(
                                    padding: const EdgeInsets.all(12),
                                    child: CallVideoGrid(
                                      controller: _controller,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 14),
                              SizedBox(
                                height: 260,
                                child: CallLogPanel(
                                  logs: _controller.logs,
                                  onClear: _controller.clearLogs,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                }

                return ListView(
                  padding: EdgeInsets.all(padding),
                  children: [
                    _settingsPanel(),
                    const SizedBox(height: 14),
                    Card(
                      child: SizedBox(
                        height: 460,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: CallVideoGrid(controller: _controller),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    CallLogPanel(
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

  Widget _settingsPanel() {
    return CallSettingsPanel(
      controller: _controller,
      apiUrlController: _apiUrlController,
      roomController: _roomController,
      identityController: _identityController,
      nameController: _nameController,
    );
  }
}
