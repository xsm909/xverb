import 'dart:async';
import 'dart:convert';

/// Handles a request or notification arriving from the other side.
typedef RpcHandler = Future<Object?> Function(Map<String, dynamic> params);

/// An error returned by the peer.
class RpcException implements Exception {
  RpcException(this.code, this.message, {this.data});

  final int code;
  final String message;
  final Object? data;

  @override
  String toString() => 'RPC error $code: $message';
}

/// A bidirectional JSON-RPC 2.0 channel over newline-delimited JSON.
///
/// One JSON object per line keeps the framing trivial on the Python side —
/// `json.dumps` never emits a raw newline, so a line is always a whole message.
class JsonRpcChannel {
  JsonRpcChannel({
    required Stream<String> incoming,
    required this.send,
    this.onError,
  }) {
    _subscription = incoming.listen(
      _handleLine,
      onDone: _handleDone,
      onError: (Object e) => onError?.call(e),
    );
  }

  /// Writes one framed message to the peer.
  final void Function(String line) send;

  /// Reports protocol-level problems that are not tied to a single call.
  final void Function(Object error)? onError;

  final Map<int, Completer<Object?>> _pending = {};
  final Map<String, RpcHandler> _handlers = {};
  late final StreamSubscription<String> _subscription;

  int _nextId = 1;
  bool _closed = false;

  /// Registers a method the peer may call on us, e.g. `host.log`.
  void on(String method, RpcHandler handler) => _handlers[method] = handler;

  /// Calls [method] on the peer and waits for its result.
  Future<Object?> call(
    String method, {
    Map<String, dynamic>? params,
    Duration? timeout,
  }) {
    if (_closed) {
      return Future.error(RpcException(-32000, 'Channel is closed'));
    }

    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;

    _write({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': ?params,
    });

    if (timeout == null) return completer.future;
    return completer.future.timeout(timeout, onTimeout: () {
      _pending.remove(id);
      throw RpcException(-32001, 'Timed out waiting for "$method"');
    });
  }

  /// Fire-and-forget message; no reply is expected.
  void notify(String method, {Map<String, dynamic>? params}) {
    if (_closed) return;
    _write({
      'jsonrpc': '2.0',
      'method': method,
      'params': ?params,
    });
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _subscription.cancel();
    _failPending(RpcException(-32000, 'Channel closed'));
  }

  void _write(Map<String, dynamic> message) => send(jsonEncode(message));

  void _handleLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return;

    Map<String, dynamic> message;
    try {
      message = jsonDecode(trimmed) as Map<String, dynamic>;
    } on Object {
      // Plugins that print to stdout instead of using host.log end up here.
      onError?.call(RpcException(-32700, 'Malformed message: $trimmed'));
      return;
    }

    final id = message['id'];
    final method = message['method'] as String?;

    if (method != null) {
      _dispatch(id, method, message['params']);
      return;
    }

    if (id is! int) return;
    final completer = _pending.remove(id);
    if (completer == null) return;

    final error = message['error'];
    if (error is Map) {
      completer.completeError(RpcException(
        (error['code'] as num?)?.toInt() ?? -32603,
        error['message'] as String? ?? 'Unknown error',
        data: error['data'],
      ));
    } else {
      completer.complete(message['result']);
    }
  }

  Future<void> _dispatch(Object? id, String method, Object? rawParams) async {
    final params = rawParams is Map
        ? Map<String, dynamic>.from(rawParams)
        : <String, dynamic>{};
    final handler = _handlers[method];

    if (handler == null) {
      if (id != null) {
        _write({
          'jsonrpc': '2.0',
          'id': id,
          'error': {'code': -32601, 'message': 'Unknown method "$method"'},
        });
      }
      return;
    }

    try {
      final result = await handler(params);
      if (id != null) {
        _write({'jsonrpc': '2.0', 'id': id, 'result': result});
      }
    } on Object catch (e) {
      if (id != null) {
        _write({
          'jsonrpc': '2.0',
          'id': id,
          'error': {'code': -32603, 'message': e.toString()},
        });
      }
    }
  }

  void _handleDone() {
    _closed = true;
    _failPending(RpcException(-32000, 'Plugin process exited'));
  }

  void _failPending(Object error) {
    final pending = List.of(_pending.values);
    _pending.clear();
    for (final completer in pending) {
      if (!completer.isCompleted) completer.completeError(error);
    }
  }
}
