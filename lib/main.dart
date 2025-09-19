// Lucas Liz e Joao Pedro Montera

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:io' show Platform;
import 'package:proxy_app/models/request_model.dart';
import 'package:proxy_app/services/cpf_service.dart';
import 'package:proxy_app/services/proxy_service.dart';
import 'package:proxy_app/services/proxy_config_service.dart';
import 'package:proxy_app/widgets/request_list.dart';
import 'package:proxy_app/widgets/report_view.dart';
import 'package:proxy_app/widgets/history_list.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ProxyConfigService().loadFromStorage();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Proxy App',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: const MyHomePage(),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  late final TextEditingController _cpfController;
  late final TextEditingController _proxyController;
  final ProxyService proxyService = ProxyService();
  final CpfService cpfService = CpfService();
  final ProxyConfigService proxyConfig = ProxyConfigService();
  bool _isProxyValid = true;

  @override
  void initState() {
    super.initState();
    _cpfController = TextEditingController(text: cpfService.cpf.value);
    _proxyController = TextEditingController(text: proxyConfig.baseUrl.value);
    cpfService.cpf.addListener(_onCpfChanged);
    proxyConfig.baseUrl.addListener(_onProxyChanged);
    _isProxyValid = _validateProxyUrl(_proxyController.text);
  }

  @override
  void dispose() {
    _cpfController.dispose();
    _proxyController.dispose();
    cpfService.cpf.removeListener(_onCpfChanged);
    proxyConfig.baseUrl.removeListener(_onProxyChanged);
    super.dispose();
  }

  void _onCpfChanged() {
    if (_cpfController.text != cpfService.cpf.value) {
      _cpfController.text = cpfService.cpf.value;
    }
  }

  void _onProxyChanged() {
    if (_proxyController.text != proxyConfig.baseUrl.value) {
      _proxyController.text = proxyConfig.baseUrl.value;
    }
    final valid = _validateProxyUrl(_proxyController.text);
    if (valid != _isProxyValid) {
      setState(() => _isProxyValid = valid);
    }
  }

  bool _validateProxyUrl(String value) {
    final v = value.trim();
    if (v.isEmpty) return false;
    final uri = Uri.tryParse(v);
    if (uri == null) return false;
    if (!(uri.scheme == 'http' || uri.scheme == 'https')) return false;
    if (uri.host.isEmpty) return false;
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Proxy App'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Requests', icon: Icon(Icons.list)),
              Tab(text: 'Report', icon: Icon(Icons.pie_chart)),
              Tab(text: 'History', icon: Icon(Icons.history)),
            ],
          ),
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: TextField(
                controller: _cpfController,
                decoration: const InputDecoration(
                  labelText: 'CPF',
                  border: OutlineInputBorder(),
                ),
                onChanged: (value) => cpfService.updateCpf(value),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0),
              child: TextField(
                controller: _proxyController,
                decoration: InputDecoration(
                  labelText: 'Proxy URL (ex: ${_recommendedProxyExample()})',
                  border: const OutlineInputBorder(),
                  errorText: _isProxyValid ? null : 'URL inválida: informe http(s)://host[:porta]',
                ),
                onChanged: (value) {
                  final valid = _validateProxyUrl(value);
                  if (valid != _isProxyValid) {
                    setState(() => _isProxyValid = valid);
                  }
                  proxyConfig.updateBaseUrl(value);
                },
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: TabBarView(
                children: [
                  RequestList(),
                  ReportView(),
                  HistoryList(),
                ],
              ),
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton(
          onPressed: () {
            if (!_isProxyValid) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Proxy URL inválida. Corrija antes de continuar.')),
              );
              return;
            }
            proxyService.addRequest(
              RequestModel(
                id: DateTime.now().toString(),
                url: 'https://score.hsborges.dev/api/score?cpf=${cpfService.cpf.value}',
                body: {},
              ),
            );
          },
          child: const Icon(Icons.add),
        ),
      ),
    );
  }

  String _recommendedProxyExample() {
    const port = 8080;
    if (kIsWeb) return 'http://localhost:$port';
    try {
      if (Platform.isAndroid) return 'http://10.0.2.2:$port';
      if (Platform.isIOS) return 'http://localhost:$port';
      if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
        return 'http://127.0.0.1:$port';
      }
    } catch (_) {}
    return 'http://localhost:$port';
  }
}
