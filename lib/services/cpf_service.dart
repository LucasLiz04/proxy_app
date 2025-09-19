
import 'package:flutter/foundation.dart';

class CpfService {
  static final CpfService _instance = CpfService._internal();
  factory CpfService() => _instance;
  CpfService._internal();

  final ValueNotifier<String> cpf = ValueNotifier<String>('06556619132');

  void updateCpf(String newCpf) {
    cpf.value = newCpf;
  }
}
