import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/request_model.dart';
import '../services/proxy_service.dart';

class HistoryList extends StatefulWidget {
  const HistoryList({super.key});

  @override
  State<HistoryList> createState() => _HistoryListState();
}

class _HistoryListState extends State<HistoryList> {
  final ProxyService _proxyService = ProxyService();
  bool _loading = false;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _refresh();
    _startAutoSync();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    try {
      await _proxyService.syncHistoryFromServer();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _startAutoSync() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (!mounted || _loading) return;
      try {
        await _proxyService.syncHistoryFromServer();
      } catch (_) {
        // ignore poll errors
      }
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton.icon(
              onPressed: _loading ? null : _refresh,
              icon: _loading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync),
              label: const Text('Sincronizar'),
            ),
          ],
        ),
        Expanded(
          child: ValueListenableBuilder<List<RequestModel>>(
            valueListenable: _proxyService.history,
            builder: (context, items, child) {
              if (items.isEmpty) {
                return const Center(child: Text('Sem histórico ainda.'));
              }
              return RefreshIndicator(
                onRefresh: _refresh,
                child: ListView.builder(
                  padding: const EdgeInsets.all(8.0),
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final request = items[index];
                    return Card(
                      elevation: 3.0,
                      margin: const EdgeInsets.symmetric(vertical: 8.0),
                      child: ListTile(
                        leading: _buildStatusIcon(request.status),
                        title: Text(
                          request.url,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'Status: ${request.status.toString().split('.').last}'
                              '${request.latencyMs != null ? ' • ${request.latencyMs}ms' : ''}'
                              '${request.responseStatus != null ? ' • upstream: ${request.responseStatus}' : ''}',
                            ),
                            if (request.responseBody != null &&
                                request.responseBody!.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 4.0),
                                child: Text(
                                  _truncate(request.responseBody!, 200),
                                  style: const TextStyle(
                                    fontFamily: 'monospace',
                                  ),
                                ),
                              ),
                          ],
                        ),
                        trailing: Text(
                          '#${request.id.substring(0, request.id.length.clamp(0, 5))}',
                        ),
                        onTap: () => _showResponseDialog(context, request),
                      ),
                    );
                  },
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildStatusIcon(RequestStatus status) {
    switch (status) {
      case RequestStatus.pending:
        return const Icon(Icons.pending, color: Colors.orange);
      case RequestStatus.processing:
        return const SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2.0),
        );
      case RequestStatus.completed:
        return const Icon(Icons.check_circle, color: Colors.green);
      case RequestStatus.failed:
        return const Icon(Icons.error, color: Colors.red);
    }
  }

  String _truncate(String s, int max) {
    if (s.length <= max) return s;
    return s.substring(0, max) + '…';
  }

  void _showResponseDialog(BuildContext context, RequestModel req) {
    final body = req.responseBody ?? '';
    String pretty = body;
    try {
      final decoded = jsonDecode(body);
      pretty = const JsonEncoder.withIndent('  ').convert(decoded);
    } catch (_) {}

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          'Histórico • upstream: ${req.responseStatus ?? '-'} • ${req.latencyMs ?? '-'}ms',
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  req.url,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                SelectableText(
                  pretty.isEmpty ? '(sem corpo)' : pretty,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Fechar'),
          ),
        ],
      ),
    );
  }
}
