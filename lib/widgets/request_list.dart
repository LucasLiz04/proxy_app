import 'package:flutter/material.dart';
import 'dart:convert';
import '../models/request_model.dart';
import '../services/proxy_service.dart';

class RequestList extends StatelessWidget {
  final ProxyService _proxyService = ProxyService();

  RequestList({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<RequestModel>>(
      valueListenable: _proxyService.requests,
      builder: (context, requests, child) {
        if (requests.isEmpty) {
          return const Center(
            child: Text('No requests yet. Press the + button to add one.'),
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.all(8.0),
          itemCount: requests.length,
          itemBuilder: (context, index) {
            final request = requests[index];
            return Card(
              elevation: 4.0,
              margin: const EdgeInsets.symmetric(vertical: 8.0),
              child: ListTile(
                leading: _buildStatusIcon(request.status),
                title: Text(request.url, style: const TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Status: ${request.status.toString().split('.').last}'
                      '${request.latencyMs != null ? ' • ${request.latencyMs}ms' : ''}'
                      '${request.responseStatus != null ? ' • upstream: ${request.responseStatus}' : ''}',
                    ),
                    if (request.responseBody != null && request.responseBody!.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4.0),
                        child: Text(
                          _truncate(request.responseBody!, 200),
                          style: const TextStyle(fontFamily: 'monospace'),
                        ),
                      ),
                  ],
                ),
                trailing: Text('#${request.id.substring(0, 5)}'),
                onTap: () => _showResponseDialog(context, request),
              ),
            );
          },
        );
      },
    );
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
    } catch (_) {
      // keep original if not JSON
    }

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text('Resposta • upstream: ${req.responseStatus ?? '-'} • ${req.latencyMs ?? '-'}ms'),
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
        );
      },
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
}
