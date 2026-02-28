/// DTOs for the signal-cli-rest-api JSON interface.
library;

class SignalAbout {
  const SignalAbout({required this.versions, this.build});
  factory SignalAbout.fromJson(Map<String, dynamic> json) => SignalAbout(
        versions: (json['versions'] as List<dynamic>).cast<String>(),
        build: json['build'] as int?,
      );
  final List<String> versions;
  final int? build;
}

class SendMessageResponse {
  const SendMessageResponse({required this.timestamp});
  factory SendMessageResponse.fromJson(Map<String, dynamic> json) =>
      SendMessageResponse(timestamp: json['timestamp']?.toString() ?? '');
  final String timestamp;
}

class SignalDataMessage {
  const SignalDataMessage({this.message, this.timestamp, this.groupId});
  factory SignalDataMessage.fromJson(Map<String, dynamic> json) {
    String? groupId;
    final groupInfo = json['groupInfo'] as Map<String, dynamic>?;
    if (groupInfo != null) groupId = groupInfo['groupId'] as String?;
    return SignalDataMessage(
      message: json['message'] as String?,
      timestamp: json['timestamp'] as int?,
      groupId: groupId,
    );
  }
  final String? message;
  final int? timestamp;
  final String? groupId;
  bool get isGroup => groupId != null;
}

class SignalEnvelope {
  const SignalEnvelope({
    required this.source,
    required this.sourceUuid,
    required this.timestamp,
    this.dataMessage,
  });
  factory SignalEnvelope.fromJson(Map<String, dynamic> json) {
    final envelope = json['envelope'] as Map<String, dynamic>;
    return SignalEnvelope.fromEnvelopeJson(envelope);
  }
  factory SignalEnvelope.fromEnvelopeJson(Map<String, dynamic> json) {
    final dm = json['dataMessage'] as Map<String, dynamic>?;
    return SignalEnvelope(
      source: json['source'] as String,
      sourceUuid: json['sourceUuid'] as String,
      timestamp: json['timestamp'] as int,
      dataMessage: dm != null ? SignalDataMessage.fromJson(dm) : null,
    );
  }
  final String source;
  final String sourceUuid;
  final int timestamp;
  final SignalDataMessage? dataMessage;
  String get chatId => dataMessage?.groupId ?? source;
  bool get hasTextMessage =>
      dataMessage != null &&
      dataMessage!.message != null &&
      dataMessage!.message!.isNotEmpty;

  /// Whether this message came from a group chat.
  bool get isGroupMessage => dataMessage?.isGroup ?? false;
}

/// A Signal group returned by `GET /v1/groups/{number}`.
class SignalGroup {
  const SignalGroup({
    required this.id,
    required this.name,
    this.members = const [],
  });

  factory SignalGroup.fromJson(Map<String, dynamic> json) => SignalGroup(
        id: json['id'] as String? ?? json['internal_id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        members: (json['members'] as List<dynamic>?)?.cast<String>() ??
            const <String>[],
      );

  final String id;
  final String name;
  final List<String> members;
}
