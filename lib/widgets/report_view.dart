
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../models/request_model.dart';
import '../services/proxy_service.dart';

class ReportView extends StatelessWidget {
  final ProxyService _proxyService = ProxyService();

  ReportView({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<RequestModel>>(
      valueListenable: _proxyService.requests,
      builder: (context, requests, child) {
        return PieChart(
          PieChartData(
            sections: _generateChartData(requests),
            sectionsSpace: 2,
            centerSpaceRadius: 40,
          ),
        );
      },
    );
  }

  List<PieChartSectionData> _generateChartData(List<RequestModel> requests) {
    final statusCounts = {
      RequestStatus.pending: 0,
      RequestStatus.processing: 0,
      RequestStatus.completed: 0,
      RequestStatus.failed: 0,
    };

    for (final request in requests) {
      statusCounts[request.status] = statusCounts[request.status]! + 1;
    }

    return statusCounts.entries.map((entry) {
      final status = entry.key;
      final count = entry.value;

      switch (status) {
        case RequestStatus.pending:
          return PieChartSectionData(
            color: Colors.orange,
            value: count.toDouble(),
            title: 'Pending ($count)',
            radius: 50,
          );
        case RequestStatus.processing:
          return PieChartSectionData(
            color: Colors.blue,
            value: count.toDouble(),
            title: 'Processing ($count)',
            radius: 50,
          );
        case RequestStatus.completed:
          return PieChartSectionData(
            color: Colors.green,
            value: count.toDouble(),
            title: 'Completed ($count)',
            radius: 50,
          );
        case RequestStatus.failed:
          return PieChartSectionData(
            color: Colors.red,
            value: count.toDouble(),
            title: 'Failed ($count)',
            radius: 50,
          );
      }
    }).toList();
  }
}
