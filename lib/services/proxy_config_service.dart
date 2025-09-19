import 'package:flutter/foundation.dart';
import 'dart:io' show Platform;
import 'package:shared_preferences/shared_preferences.dart';

class ProxyConfigService {
  static final ProxyConfigService _instance = ProxyConfigService._internal();
  factory ProxyConfigService() => _instance;
  ProxyConfigService._internal();

  final ValueNotifier<String> baseUrl = ValueNotifier<String>(
    'http://localhost:8080',
  );

  static const _kProxyBaseUrl = 'proxy_base_url';

  Future<void> loadFromStorage() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_kProxyBaseUrl);
    if (saved != null && saved.trim().isNotEmpty) {
      baseUrl.value = saved;
    } else {
      baseUrl.value = _detectDefaultBaseUrl();
    }
  }

  void updateBaseUrl(String url) {
    final normalized = url.trim();
    baseUrl.value = normalized;
    SharedPreferences.getInstance().then((prefs) {
      prefs.setString(_kProxyBaseUrl, normalized);
    });
  }

  String _detectDefaultBaseUrl() {
    const port = 8080;
    if (kIsWeb) {
      return 'http://localhost:$port';
    }
    if (Platform.isAndroid) return 'http://10.0.2.2:$port';
    if (Platform.isIOS) return 'http://localhost:$port';
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      return 'http://127.0.0.1:$port';
    }
    return 'http://localhost:$port';
  }
}
