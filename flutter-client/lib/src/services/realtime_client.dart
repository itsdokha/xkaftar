import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

class RealtimeClient {
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;

  void connect({
    required String url,
    required void Function(Map<String, dynamic> event) onEvent,
    required void Function(String status) onStatus,
    required void Function(String error) onError,
    void Function()? onUnauthorized,
  }) {
    disconnect();
    onStatus('connecting');
    try {
      final channel = WebSocketChannel.connect(Uri.parse(url));
      _channel = channel;
      unawaited(
        channel.ready.then((_) {
          if (_channel == channel) {
            onStatus('connected');
          }
        }).catchError((error) {
          if (_channel == channel) {
            onStatus('error');
            onError(error.toString());
            disconnect();
          }
        }),
      );
      _subscription = channel.stream.listen(
        (message) {
          if (message is! String) {
            return;
          }
          if (message.trim().isEmpty) {
            return;
          }
          try {
            final decoded = jsonDecode(message);
            if (decoded is Map<String, dynamic>) {
              onEvent(decoded);
            }
          } catch (_) {}
        },
        onDone: () {
          if (_channel == channel && channel.closeCode == 4401) {
            onUnauthorized?.call();
          }
          onStatus('disconnected');
        },
        onError: (error) {
          onStatus('error');
          onError(error.toString());
        },
        cancelOnError: true,
      );
    } catch (error) {
      onStatus('error');
      onError(error.toString());
    }
  }

  void send(Map<String, dynamic> payload) {
    _channel?.sink.add(jsonEncode(payload));
  }

  void disconnect() {
    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close();
    _channel = null;
  }
}
