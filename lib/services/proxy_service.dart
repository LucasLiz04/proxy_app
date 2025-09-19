import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/request_model.dart';
import 'proxy_config_service.dart';

abstract class Command {
  Future<void> execute();
}

class RequestCommand implements Command {
  final RequestModel request;

  RequestCommand(this.request);

  @override
  Future<void> execute() async {
    request.status = RequestStatus.processing;
    try {
      // Forward through the proxy server instead of hitting the URL directly
      final proxyBase = ProxyConfigService().baseUrl.value;
      final proxyUri = Uri.parse('$proxyBase/proxy');
      final started = DateTime.now();

      final response = await http.post(
        proxyUri,
        headers: {
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'url': request.url,
          'method': 'GET',
          'headers': {
            'Accept': 'application/json',
          },
        }),
      );

      final elapsed = DateTime.now().difference(started).inMilliseconds;
      request.latencyMs = elapsed;

      // Try to parse proxy JSON: { status, headers, body }
      try {
        final parsed = jsonDecode(response.body) as Map<String, dynamic>;
        request.responseStatus = (parsed['status'] is int)
            ? parsed['status'] as int
            : int.tryParse('${parsed['status']}');
        final respBody = parsed['body'];
        if (respBody is String) {
          request.responseBody = respBody;
        } else if (respBody is Map<String, dynamic>) {
          // For base64 or other structured forms, serialize compactly
          request.responseBody = jsonEncode(respBody);
        } else {
          request.responseBody = response.body;
        }
      } catch (_) {
        // Fallback: keep raw
        request.responseBody = response.body;
      }

      if (response.statusCode >= 200 && response.statusCode < 300) {
        request.status = RequestStatus.completed;
      } else {
        request.status = RequestStatus.failed;
      }
    } catch (e) {
      request.status = RequestStatus.failed;
    }
  }
}

class ProxyService {
  static final ProxyService _instance = ProxyService._internal();
  factory ProxyService() => _instance;
  ProxyService._internal();

  final Queue<Command> _requestQueue = Queue<Command>();
  final ValueNotifier<List<RequestModel>> requests =
      ValueNotifier<List<RequestModel>>([]);
  // Separate notifier to hold server history items
  final ValueNotifier<List<RequestModel>> history =
      ValueNotifier<List<RequestModel>>([]);
  bool _isProcessing = false;

  void addRequest(RequestModel request) {
    // Insert new requests at the beginning so they appear first in the UI
    requests.value.insert(0, request);
    requests.value = List.from(requests.value);
    _requestQueue.add(RequestCommand(request));
    if (!_isProcessing) {
      _processQueue();
    }
  }

  Future<void> _processQueue() async {
    if (_isProcessing || _requestQueue.isEmpty) {
      return;
    }

    _isProcessing = true;
    final command = _requestQueue.removeFirst() as RequestCommand;
    await command.execute();
    final requestIndex = requests.value.indexWhere((req) => req.id == command.request.id);
    if (requestIndex != -1) {
      requests.value[requestIndex] = command.request;
      requests.value = List.from(requests.value);
    }
    _isProcessing = false;

    if (_requestQueue.isNotEmpty) {
      _processQueue();
    }
  }

  // Pull recent history from the proxy server into `history`
  Future<void> syncHistoryFromServer({int? limit}) async {
    final base = ProxyConfigService().baseUrl.value;
    final uri = Uri.parse('$base/history${limit != null ? '?limit=$limit' : ''}');
    final resp = await http.get(uri);
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      final data = (jsonDecode(resp.body) as List).cast<Map<String, dynamic>>();
      final items = data.reversed.map((e) {
        // Convert server history entry to RequestModel
        final id = e['id']?.toString() ?? DateTime.now().toIso8601String();
        final url = e['url']?.toString() ?? '';
        final statusCode = int.tryParse('${e['status']}');
        final latency = int.tryParse('${e['latencyMs']}');
        final body = e['body']?.toString();
        return RequestModel(
          id: id,
          url: url,
          body: const {},
          status: (statusCode != null && statusCode >= 200 && statusCode < 300)
              ? RequestStatus.completed
              : RequestStatus.failed,
          responseStatus: statusCode,
          responseBody: body,
          latencyMs: latency,
        );
      }).toList();
      history.value = items;
    } else {
      throw Exception('Failed to fetch history: ${resp.statusCode}');
    }
  }
}
