// Lightweight proxy/web service using dart:io + http
// Now with: in-memory queue + rate limiter, /proxy/score, /metrics, /health

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ffi' as ffi;

import 'package:http/http.dart' as http;
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:sqlite3/open.dart' as sqlite_open;

class ProxyConfig {
  final Set<String> allowedHosts;
  final Map<String, String> injectHeaders;
  final String? overrideCpfParamValue; // If set, replaces cpf query param
  final Duration timeout;
  final double ratePerSec; // max requests per second to upstream
  final int maxQueue;
  final Duration requestTtl;
  final String overflowPolicy; // drop_oldest | drop_new | reject
  final int historyMax;
  final String dbPath;

  ProxyConfig({
    required this.allowedHosts,
    required this.injectHeaders,
    required this.overrideCpfParamValue,
    required this.timeout,
    required this.ratePerSec,
    required this.maxQueue,
    required this.requestTtl,
    required this.overflowPolicy,
    required this.historyMax,
    required this.dbPath,
  });

  factory ProxyConfig.fromEnv() {
    final allowed =
        (Platform.environment['ALLOWED_HOSTS'] ?? 'score.hsborges.dev')
            .split(',')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toSet();
    final clientId = Platform.environment['CLIENT_ID'] ?? '2';
    final overrideCpf = Platform.environment['OVERRIDE_CPF'];
    final timeoutMs =
        int.tryParse(Platform.environment['PROXY_TIMEOUT_MS'] ?? '') ?? 30000;
    final rate =
        double.tryParse(Platform.environment['RATE_PER_SEC'] ?? '') ?? 1.0;
    final maxQ = int.tryParse(Platform.environment['MAX_QUEUE'] ?? '') ?? 100;
    final ttlMs =
        int.tryParse(Platform.environment['REQUEST_TTL_MS'] ?? '') ?? 30000;
    final overflow = (Platform.environment['OVERFLOW_POLICY'] ?? 'reject')
        .toLowerCase();
    final histMax =
        int.tryParse(Platform.environment['HISTORY_MAX'] ?? '') ?? 200;
    final dbPath = Platform.environment['DB_PATH'] ?? 'proxy_history.db';
    return ProxyConfig(
      allowedHosts: allowed,
      injectHeaders: {'client-id': clientId},
      overrideCpfParamValue: overrideCpf?.trim().isNotEmpty == true
          ? overrideCpf
          : null,
      timeout: Duration(milliseconds: timeoutMs),
      ratePerSec: rate <= 0 ? 1.0 : rate,
      maxQueue: maxQ <= 0 ? 1 : maxQ,
      requestTtl: Duration(milliseconds: ttlMs <= 0 ? 1 : ttlMs),
      overflowPolicy:
          (overflow == 'drop_oldest' ||
              overflow == 'drop_new' ||
              overflow == 'reject')
          ? overflow
          : 'reject',
      historyMax: histMax <= 0 ? 1 : histMax,
      dbPath: dbPath,
    );
  }
}

class _Job {
  final HttpRequest req;
  final String method;
  final Uri url;
  final Map<String, String> headers;
  final dynamic body; // String or Map/List
  final DateTime enqueuedAt;
  final int priority; // reserved for future
  int attempts;

  _Job({
    required this.req,
    required this.method,
    required this.url,
    required this.headers,
    required this.body,
    required this.enqueuedAt,
    this.priority = 0,
    this.attempts = 0,
  });
}

class _Metrics {
  int enqueuedTotal = 0;
  int forwardedTotal = 0;
  int droppedTtlTotal = 0;
  int droppedOverflowTotal = 0;
  int upstreamErrorsTotal = 0;
  final Map<int, int> latencyBuckets = {
    100: 0,
    300: 0,
    500: 0,
    1000: 0,
    2000: 0,
    3000: 0,
    5000: 0,
    999999999: 0, // +Inf
  };

  void observeLatency(Duration d) {
    final ms = d.inMilliseconds;
    final keys = latencyBuckets.keys.toList()..sort();
    for (final k in keys) {
      if (ms <= k) {
        latencyBuckets[k] = (latencyBuckets[k] ?? 0) + 1;
        return;
      }
    }
    latencyBuckets[999999999] = (latencyBuckets[999999999] ?? 0) + 1;
  }

  String renderPrometheus(int queueSize) {
    final b = StringBuffer();
    b.writeln('# HELP proxy_queue_size Current queue size');
    b.writeln('# TYPE proxy_queue_size gauge');
    b.writeln('proxy_queue_size $queueSize');

    b.writeln('# HELP proxy_requests_enqueued_total Total enqueued');
    b.writeln('# TYPE proxy_requests_enqueued_total counter');
    b.writeln('proxy_requests_enqueued_total $enqueuedTotal');

    b.writeln(
      '# HELP proxy_requests_forwarded_total Total forwarded to upstream',
    );
    b.writeln('# TYPE proxy_requests_forwarded_total counter');
    b.writeln('proxy_requests_forwarded_total $forwardedTotal');

    b.writeln(
      '# HELP proxy_requests_dropped_ttl_total Dropped due to TTL expiration',
    );
    b.writeln('# TYPE proxy_requests_dropped_ttl_total counter');
    b.writeln('proxy_requests_dropped_ttl_total $droppedTtlTotal');

    b.writeln(
      '# HELP proxy_requests_dropped_overflow_total Dropped due to queue overflow',
    );
    b.writeln('# TYPE proxy_requests_dropped_overflow_total counter');
    b.writeln('proxy_requests_dropped_overflow_total $droppedOverflowTotal');

    b.writeln('# HELP proxy_upstream_errors_total Upstream error responses');
    b.writeln('# TYPE proxy_upstream_errors_total counter');
    b.writeln('proxy_upstream_errors_total $upstreamErrorsTotal');

    b.writeln('# HELP proxy_upstream_latency_ms Histogram of upstream latency');
    b.writeln('# TYPE proxy_upstream_latency_ms histogram');
    int cumulative = 0;
    final sortedKeys = latencyBuckets.keys.toList()..sort();
    for (final k in sortedKeys) {
      cumulative += latencyBuckets[k] ?? 0;
      final label = k == 999999999 ? '+Inf' : k.toString();
      b.writeln('proxy_upstream_latency_ms_bucket{le="$label"} $cumulative');
    }
    final totalObs = latencyBuckets.values.fold<int>(0, (a, b) => a + b);
    b.writeln('proxy_upstream_latency_ms_count $totalObs');
    b.writeln('proxy_upstream_latency_ms_sum 0');
    return b.toString();
  }
}

void main(List<String> args) async {
  _configureSqliteDynamicLibrary();
  final port = int.tryParse(Platform.environment['PORT'] ?? '') ?? 8080;
  final config = ProxyConfig.fromEnv();

  // Bind server (prefer IPv6 dual-stack, fallback to IPv4-only)
  final server = await _bindHttpServer(port);
  stdout.writeln('Allowed hosts: ${config.allowedHosts.join(', ')}');
  stdout.writeln(
    'Rate: ${config.ratePerSec} req/s; MaxQueue: ${config.maxQueue}; TTL: ${config.requestTtl.inMilliseconds}ms',
  );

  final queue = <_Job>[];
  final metrics = _Metrics();
  final periodMs = (1000 / config.ratePerSec).round().clamp(1, 60000);
  final baseSpacingMs = periodMs; // default gap between upstream calls
  DateTime nextAllowedAt = DateTime.now();

  // Initialize SQLite DB early so helpers can use it
  final db = _initDb(config.dbPath);

  // In-memory history of recent processed requests
  final history = <Map<String, dynamic>>[];
  int histSeq = 0;
  void pushHistory(Map<String, dynamic> item) {
    history.add(item);
    if (history.length > config.historyMax) {
      history.removeAt(0);
    }
    _dbInsertHistory(db, item);
  }

  // DB initialized above

  Timer.periodic(Duration(milliseconds: periodMs), (timer) async {
    if (queue.isEmpty) return;
    if (DateTime.now().isBefore(nextAllowedAt)) return;
    final job = queue.removeAt(0);
    // TTL check
    if (DateTime.now().difference(job.enqueuedAt) > config.requestTtl) {
      metrics.droppedTtlTotal++;
      _writeCors(job.req);
      job.req.response.statusCode = HttpStatus.gatewayTimeout;
      job.req.response.headers.contentType = ContentType.json;
      job.req.response.write(jsonEncode({'error': 'TTL expired'}));
      await job.req.response.close();
      return;
    }

    final started = DateTime.now();
    final client = http.Client();
    try {
      final forward = http.Request(job.method, job.url);
      forward.headers.addAll(job.headers);
      if (job.body != null) {
        if (job.body is String) {
          forward.body = job.body as String;
        } else if (job.body is Map || job.body is List) {
          forward.headers['content-type'] ??= 'application/json';
          forward.body = jsonEncode(job.body);
        }
      }
      final streamed = await client.send(forward).timeout(config.timeout);
      final respBodyBytes = await streamed.stream.toBytes();
      final respHeaders = <String, String>{}..addAll(streamed.headers);

      metrics.forwardedTotal++;
      metrics.observeLatency(DateTime.now().difference(started));

      final retryAfter = _parseRetryAfter(respHeaders, streamed.statusCode);
      if (streamed.statusCode == 429 && retryAfter != null) {
        // Re-enqueue the same job for a later attempt instead of returning 429 to the client
        job.attempts += 1;
        if (DateTime.now().difference(job.enqueuedAt) > config.requestTtl) {
          metrics.droppedTtlTotal++;
          _writeCors(job.req);
          job.req.response.statusCode = HttpStatus.gatewayTimeout;
          job.req.response.headers.contentType = ContentType.json;
          job.req.response.write(jsonEncode({'error': 'TTL expired'}));
          await job.req.response.close();
          // Log TTL expiration to history
          final completedAt = DateTime.now();
          pushHistory({
            'id': (++histSeq).toString(),
            'method': job.method,
            'url': job.url.toString(),
            'enqueuedAt': job.enqueuedAt.toIso8601String(),
            'startedAt': started.toIso8601String(),
            'completedAt': completedAt.toIso8601String(),
            'status': HttpStatus.gatewayTimeout,
            'latencyMs': completedAt.difference(started).inMilliseconds,
            'body': jsonEncode({'error': 'TTL expired'}),
          });
        } else {
          // pace next attempt
          nextAllowedAt = DateTime.now().add(retryAfter);
          // Put back at the front of the queue
          queue.insert(0, job);
        }
      } else {
        _writeCors(job.req);
        job.req.response.statusCode = streamed.statusCode;
        job.req.response.headers.contentType = ContentType.json;
        job.req.response.write(
          jsonEncode({
            'status': streamed.statusCode,
            'headers': respHeaders,
            'body': _decodeBody(respHeaders, respBodyBytes),
          }),
        );
        await job.req.response.close();

        // Adaptive pacing for next request
        if (retryAfter != null) {
          nextAllowedAt = DateTime.now().add(retryAfter);
        } else {
          nextAllowedAt = DateTime.now().add(
            Duration(milliseconds: baseSpacingMs + 50),
          );
        }

        // Push to history
        final completedAt = DateTime.now();
        final bodyDecoded = _decodeBody(respHeaders, respBodyBytes);
        pushHistory({
          'id': (++histSeq).toString(),
          'method': job.method,
          'url': job.url.toString(),
          'enqueuedAt': job.enqueuedAt.toIso8601String(),
          'startedAt': started.toIso8601String(),
          'completedAt': completedAt.toIso8601String(),
          'status': streamed.statusCode,
          'latencyMs': completedAt.difference(started).inMilliseconds,
          'body': bodyDecoded is String ? bodyDecoded : jsonEncode(bodyDecoded),
        });
      }
    } catch (e) {
      metrics.upstreamErrorsTotal++;
      _serverError(job.req, 'Upstream error: $e');
      // After an error, still respect base pacing to avoid rapid retries
      nextAllowedAt = DateTime.now().add(
        Duration(milliseconds: baseSpacingMs + 50),
      );
    } finally {
      client.close();
    }
  });

  await for (final req in server) {
    // CORS preflight
    if (req.method == 'OPTIONS') {
      _writeCors(req);
      req.response.statusCode = HttpStatus.noContent;
      await req.response.close();
      continue;
    }

    try {
      // Health endpoints
      if ((req.uri.path == '/healthz' || req.uri.path == '/health') &&
          req.method == 'GET') {
        _writeCors(req);
        req.response.statusCode = HttpStatus.ok;
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode({
            'status': 'ok',
            'queue_size': queue.length,
            'rate_per_sec': config.ratePerSec,
          }),
        );
        await req.response.close();
        continue;
      }

      // Metrics endpoint
      if (req.uri.path == '/metrics' && req.method == 'GET') {
        _writeCors(req);
        req.response.statusCode = HttpStatus.ok;
        req.response.headers.contentType = ContentType(
          'text',
          'plain',
          charset: 'utf-8',
        );
        req.response.write(metrics.renderPrometheus(queue.length));
        await req.response.close();
        continue;
      }

      // History endpoint (recent processed requests)
      if (req.uri.path == '/history' && req.method == 'GET') {
        _writeCors(req);
        final limit =
            int.tryParse(req.uri.queryParameters['limit'] ?? '') ??
            config.historyMax;
        final offset =
            int.tryParse(req.uri.queryParameters['offset'] ?? '') ?? 0;
        // Prefer DB persistence; fall back to in-memory if needed
        try {
          final rows = _dbQueryHistory(db, limit, offset);
          req.response.statusCode = HttpStatus.ok;
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode(rows));
        } catch (e) {
          final start = (history.length - offset - limit).clamp(
            0,
            history.length,
          );
          final end = (history.length - offset).clamp(0, history.length);
          final slice = history.isEmpty
              ? <Map<String, dynamic>>[]
              : List<Map<String, dynamic>>.from(history.sublist(start, end));
          req.response.statusCode = HttpStatus.ok;
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode(slice));
        }
        await req.response.close();
        continue;
      }

      // DELETE /history: clear history storage (DB and memory)
      if (req.uri.path == '/history' && req.method == 'DELETE') {
        _writeCors(req);
        try {
          final deleted = _dbDeleteHistory(db);
          history.clear();
          req.response.statusCode = HttpStatus.ok;
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({'status': 'ok', 'deleted': deleted}));
        } catch (e) {
          history.clear();
          req.response.statusCode = HttpStatus.ok;
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({'status': 'ok', 'deleted': null}));
        }
        await req.response.close();
        continue;
      }

      // POST /proxy (generic)
      if (req.uri.path == '/proxy' && req.method == 'POST') {
        final bodyStr = await utf8.decoder.bind(req).join();
        final data = (jsonDecode(bodyStr) as Map).cast<String, dynamic>();
        final urlStr = (data['url'] ?? '').toString();
        final method = (data['method'] ?? 'GET').toString().toUpperCase();
        final headers =
            (data['headers'] as Map?)?.map(
              (k, v) => MapEntry(k.toString(), v.toString()),
            ) ??
            <String, String>{};
        final dynamic rawBody = data['body'];

        if (urlStr.isEmpty) {
          return _badRequest(req, 'Missing url');
        }

        final url = _applyUrlFilters(Uri.parse(urlStr), config);
        if (!_isAllowed(url, config)) {
          return _forbidden(req, 'Host not allowed: ${url.host}');
        }

        final mergedHeaders = <String, String>{}
          ..addAll(headers)
          ..addAll(config.injectHeaders);

        // Enqueue with overflow policy
        if (queue.length >= config.maxQueue) {
          if (config.overflowPolicy == 'drop_oldest' && queue.isNotEmpty) {
            final dropped = queue.removeAt(0);
            metrics.droppedOverflowTotal++;
            _writeCors(dropped.req);
            dropped.req.response.statusCode = HttpStatus.serviceUnavailable;
            dropped.req.response.headers.contentType = ContentType.json;
            dropped.req.response.write(
              jsonEncode({'error': 'Dropped due to overflow'}),
            );
            await dropped.req.response.close();
          } else {
            metrics.droppedOverflowTotal++;
            return _tooMany(req, 'Queue is full');
          }
        }

        queue.add(
          _Job(
            req: req,
            method: method,
            url: url,
            headers: mergedHeaders,
            body: rawBody,
            enqueuedAt: DateTime.now(),
          ),
        );
        metrics.enqueuedTotal++;
        // Scheduler will respond later
        continue;
      }

      // GET /proxy?url=encoded
      if (req.uri.path == '/proxy' && req.method == 'GET') {
        final urlStr = req.uri.queryParameters['url'];
        if (urlStr == null || urlStr.isEmpty) {
          return _badRequest(req, 'Missing url param');
        }
        final url = _applyUrlFilters(Uri.parse(urlStr), config);
        if (!_isAllowed(url, config)) {
          return _forbidden(req, 'Host not allowed: ${url.host}');
        }

        if (queue.length >= config.maxQueue) {
          if (config.overflowPolicy == 'drop_oldest' && queue.isNotEmpty) {
            final dropped = queue.removeAt(0);
            metrics.droppedOverflowTotal++;
            _writeCors(dropped.req);
            dropped.req.response.statusCode = HttpStatus.serviceUnavailable;
            dropped.req.response.headers.contentType = ContentType.json;
            dropped.req.response.write(
              jsonEncode({'error': 'Dropped due to overflow'}),
            );
            await dropped.req.response.close();
          } else {
            metrics.droppedOverflowTotal++;
            return _tooMany(req, 'Queue is full');
          }
        }
        queue.add(
          _Job(
            req: req,
            method: 'GET',
            url: url,
            headers: config.injectHeaders,
            body: null,
            enqueuedAt: DateTime.now(),
          ),
        );
        metrics.enqueuedTotal++;
        continue;
      }

      // GET /proxy/score?cpf=...
      if (req.uri.path == '/proxy/score' && req.method == 'GET') {
        final cpf = req.uri.queryParameters['cpf'];
        if (cpf == null || cpf.isEmpty) {
          return _badRequest(req, 'Missing cpf param');
        }
        final target = Uri.parse(
          'https://score.hsborges.dev/api/score?cpf=$cpf',
        );
        final url = _applyUrlFilters(target, config);
        if (!_isAllowed(url, config)) {
          return _forbidden(req, 'Host not allowed: ${url.host}');
        }
        if (queue.length >= config.maxQueue) {
          if (config.overflowPolicy == 'drop_oldest' && queue.isNotEmpty) {
            final dropped = queue.removeAt(0);
            metrics.droppedOverflowTotal++;
            _writeCors(dropped.req);
            dropped.req.response.statusCode = HttpStatus.serviceUnavailable;
            dropped.req.response.headers.contentType = ContentType.json;
            dropped.req.response.write(
              jsonEncode({'error': 'Dropped due to overflow'}),
            );
            await dropped.req.response.close();
          } else {
            metrics.droppedOverflowTotal++;
            return _tooMany(req, 'Queue is full');
          }
        }
        queue.add(
          _Job(
            req: req,
            method: 'GET',
            url: url,
            headers: config.injectHeaders,
            body: null,
            enqueuedAt: DateTime.now(),
          ),
        );
        metrics.enqueuedTotal++;
        continue;
      }

      // Not found
      _writeCors(req);
      req.response.statusCode = HttpStatus.notFound;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({'error': 'Not found'}));
      await req.response.close();
    } catch (e) {
      _serverError(req, 'Unhandled error: $e');
    }
  }
}

bool _isAllowed(Uri url, ProxyConfig config) {
  return config.allowedHosts.contains(url.host);
}

Uri _applyUrlFilters(Uri url, ProxyConfig config) {
  if (config.overrideCpfParamValue == null) return url;
  final qp = Map<String, String>.from(url.queryParameters);
  if (qp.containsKey('cpf')) {
    qp['cpf'] = config.overrideCpfParamValue!;
    return url.replace(queryParameters: qp);
  }
  return url;
}

dynamic _decodeBody(Map<String, String> headers, List<int> bytes) {
  final contentType = headers.entries
      .firstWhere(
        (e) => e.key.toLowerCase() == 'content-type',
        orElse: () => const MapEntry('', ''),
      )
      .value;
  final isText =
      contentType.contains('application/json') ||
      contentType.contains('text/') ||
      contentType.contains('application/xml') ||
      contentType.contains('application/xhtml+xml');
  if (isText) {
    return utf8.decode(bytes);
  }
  // Base64 for non-text bodies
  return {'base64': base64Encode(bytes)};
}

void _writeCors(HttpRequest req) {
  req.response.headers.set('Access-Control-Allow-Origin', '*');
  req.response.headers.set(
    'Access-Control-Allow-Methods',
    'GET,POST,PUT,PATCH,DELETE,OPTIONS',
  );
  req.response.headers.set(
    'Access-Control-Allow-Headers',
    'Content-Type, Authorization, X-Requested-With, client-id',
  );
}

void _badRequest(HttpRequest req, String message) async {
  _writeCors(req);
  req.response.statusCode = HttpStatus.badRequest;
  req.response.headers.contentType = ContentType.json;
  req.response.write(jsonEncode({'error': message}));
  await req.response.close();
}

void _forbidden(HttpRequest req, String message) async {
  _writeCors(req);
  req.response.statusCode = HttpStatus.forbidden;
  req.response.headers.contentType = ContentType.json;
  req.response.write(jsonEncode({'error': message}));
  await req.response.close();
}

void _serverError(HttpRequest req, String message) async {
  _writeCors(req);
  req.response.statusCode = HttpStatus.internalServerError;
  req.response.headers.contentType = ContentType.json;
  req.response.write(jsonEncode({'error': message}));
  await req.response.close();
}

void _tooMany(HttpRequest req, String message) async {
  _writeCors(req);
  req.response.statusCode = HttpStatus.tooManyRequests;
  req.response.headers.contentType = ContentType.json;
  req.response.write(jsonEncode({'error': message}));
  await req.response.close();
}

Duration? _parseRetryAfter(Map<String, String> headers, int statusCode) {
  // Normalize keys
  String? getHeader(String name) {
    final lower = name.toLowerCase();
    for (final e in headers.entries) {
      if (e.key.toLowerCase() == lower) return e.value;
    }
    return null;
  }

  // Prefer explicit provider hint
  final resetIn = getHeader('x-ratelimit-reset-in');
  if (resetIn != null) {
    // Some providers send milliseconds as integer string (e.g., 1004)
    final ms = int.tryParse(resetIn.trim());
    if (ms != null && ms >= 0) return Duration(milliseconds: ms + 5);
  }

  // Standard Retry-After: seconds (float) or HTTP-date
  final ra = getHeader('retry-after');
  if (ra != null) {
    final v = ra.trim();
    final asDouble = double.tryParse(v);
    if (asDouble != null) {
      final ms = (asDouble * 1000).ceil();
      return Duration(milliseconds: ms + 5);
    }
    // HTTP-date fallback
    try {
      final dt = HttpDate.parse(v);
      final now = DateTime.now().toUtc();
      final diff = dt.difference(now);
      if (diff.isNegative) return Duration(milliseconds: 0);
      return diff + const Duration(milliseconds: 5);
    } catch (_) {}
  }

  // If we got 429 but no headers, wait a conservative extra second
  if (statusCode == 429) {
    return const Duration(milliseconds: 1100);
  }

  return null;
}

sqlite.Database _initDb(String path) {
  final db = sqlite.sqlite3.open(path);
  db.execute('''
    CREATE TABLE IF NOT EXISTS history (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      method TEXT NOT NULL,
      url TEXT NOT NULL,
      enqueuedAt TEXT,
      startedAt TEXT,
      completedAt TEXT,
      status INTEGER,
      latencyMs INTEGER,
      body TEXT
    );
  ''');
  return db;
}

void _dbInsertHistory(sqlite.Database db, Map<String, dynamic> item) {
  final stmt = db.prepare('''
    INSERT INTO history (method, url, enqueuedAt, startedAt, completedAt, status, latencyMs, body)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
  ''');
  try {
    stmt.execute([
      item['method'] ?? '',
      item['url'] ?? '',
      item['enqueuedAt'] ?? '',
      item['startedAt'] ?? '',
      item['completedAt'] ?? '',
      item['status'] ?? 0,
      item['latencyMs'] ?? 0,
      item['body'] is String ? item['body'] : jsonEncode(item['body'] ?? {}),
    ]);
  } finally {
    stmt.dispose();
  }
}

List<Map<String, dynamic>> _dbQueryHistory(
  sqlite.Database db,
  int limit,
  int offset,
) {
  final result = db.select(
    '''
    SELECT id, method, url, enqueuedAt, startedAt, completedAt, status, latencyMs, body
    FROM history
    ORDER BY id DESC
    LIMIT ? OFFSET ?
  ''',
    [limit, offset],
  );
  return result
      .map(
        (row) => {
          'id': row['id'].toString(),
          'method': row['method'],
          'url': row['url'],
          'enqueuedAt': row['enqueuedAt'],
          'startedAt': row['startedAt'],
          'completedAt': row['completedAt'],
          'status': row['status'],
          'latencyMs': row['latencyMs'],
          'body': row['body'],
        },
      )
      .toList();
}

void _configureSqliteDynamicLibrary() {
  if (!Platform.isLinux) return;
  sqlite_open.open.overrideFor(sqlite_open.OperatingSystem.linux, () {
    final candidates = <String>[
      'libsqlite3.so',
      'libsqlite3.so.0',
      '/usr/lib/x86_64-linux-gnu/libsqlite3.so.0',
      '/usr/lib/libsqlite3.so.0',
      '/lib/x86_64-linux-gnu/libsqlite3.so.0',
      '/lib/libsqlite3.so.0',
    ];
    for (final path in candidates) {
      try {
        return ffi.DynamicLibrary.open(path);
      } catch (_) {}
    }
    throw Exception(
      'Could not locate libsqlite3. Install libsqlite3 (e.g., apt install libsqlite3-0).',
    );
  });
}

Future<HttpServer> _bindHttpServer(int port) async {
  // Helper to attempt a bind with logging
  Future<HttpServer?> _tryBind(InternetAddress addr, int p, {bool v6Only = false}) async {
    try {
      final s = await HttpServer.bind(addr, p, v6Only: v6Only);
      final host = addr == InternetAddress.anyIPv6 ? '[::]' : '0.0.0.0';
      stdout.writeln('Proxy server listening on $host:${s.port} (${addr == InternetAddress.anyIPv6 ? 'IPv4/IPv6' : 'IPv4 only'})');
      return s;
    } catch (e) {
      stdout.writeln('Bind failed on ${addr.address}:$p ($e)');
      return null;
    }
  }

  // Try requested port on IPv6 dual-stack then IPv4
  final s1 = await _tryBind(InternetAddress.anyIPv6, port, v6Only: false);
  if (s1 != null) return s1;
  final s2 = await _tryBind(InternetAddress.anyIPv4, port);
  if (s2 != null) return s2;

  // Try fallback ports on IPv4
  final fallbacks = <int>{8081, 9090, 3000, 0};
  fallbacks.remove(port);
  for (final fp in fallbacks) {
    final s = await _tryBind(InternetAddress.anyIPv4, fp);
    if (s != null) return s;
  }
  throw Exception('Unable to bind HTTP server on port $port or fallbacks.');
}

int _dbDeleteHistory(sqlite.Database db) {
  // sqlite library exposes total changes via 'changes' pragma; simpler approach is to count before delete
  final count =
      db.select('SELECT COUNT(*) as c FROM history').first['c'] as int;
  db.execute('DELETE FROM history');
  return count;
}
