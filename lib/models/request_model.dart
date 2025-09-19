
class RequestModel {
  final String id;
  final String url;
  final Map<String, String> body;
  RequestStatus status;

  // Response details
  int? responseStatus;
  String? responseBody;
  int? latencyMs;

  RequestModel({
    required this.id,
    required this.url,
    required this.body,
    this.status = RequestStatus.pending,
    this.responseStatus,
    this.responseBody,
    this.latencyMs,
  });
}

enum RequestStatus {
  pending,
  processing,
  completed,
  failed,
}
