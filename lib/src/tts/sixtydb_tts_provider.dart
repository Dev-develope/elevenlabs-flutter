import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'tts_models.dart';
import 'tts_provider.dart';

/// Which network transport [SixtyDbTtsProvider.synthesizeStream] uses.
enum SixtyDbStreamTransport {
  /// `POST /tts-stream`, newline-delimited JSON (NDJSON) chunks. Simple and
  /// requires no persistent connection.
  http,

  /// `wss://.../ws/tts`, the bidirectional WebSocket protocol. Best suited to
  /// feeding text incrementally (e.g. token-by-token from an LLM).
  webSocket,
}

/// Audio settings for the 60db WebSocket transport.
///
/// The WebSocket API emits raw audio frames whose format is fixed by these
/// values rather than by [TtsVoiceSettings.outputFormat]. See
/// <https://docs.60db.ai/websocket-api/tts>.
class SixtyDbWebSocketAudioConfig {
  /// One of `LINEAR16`, `MULAW`, `OGG_OPUS`.
  final String encoding;

  /// Sample rate in Hz. Valid values depend on [encoding]
  /// (LINEAR16: 8000/16000/24000/48000, MULAW: 8000, OGG_OPUS: 24000).
  final int sampleRateHertz;

  const SixtyDbWebSocketAudioConfig({
    this.encoding = 'LINEAR16',
    this.sampleRateHertz = 24000,
  });

  Map<String, dynamic> toJson() => {
        'encoding': encoding,
        'sample_rate_hertz': sampleRateHertz,
      };
}

/// [TtsProvider] backed by the [60db](https://docs.60db.ai) text-to-speech API.
///
/// Supports all three 60db transports:
///
/// * [synthesize] → `POST /tts-synthesize` (one-shot, JSON response).
/// * [synthesizeStream] → `POST /tts-stream` (NDJSON) **or** the `/ws/tts`
///   WebSocket, selected by [streamTransport].
///
/// The API key is supplied at construction and sent as a bearer token (HTTP) or
/// `apiKey` query parameter (WebSocket); it is never logged.
class SixtyDbTtsProvider implements TtsProvider {
  /// 60db default voice (see the WebSocket API docs).
  static const String defaultVoice = 'fbb75ed2-975a-40c7-9e06-38e30524a9a1';

  /// Default REST base URL.
  static const String defaultBaseUrl = 'https://api.60db.ai';

  /// API key (`sk_live_...`). Sent as `Authorization: Bearer` on HTTP requests
  /// and as the `apiKey` query parameter on WebSocket connections.
  final String apiKey;

  /// REST base URL, without trailing slash.
  final String baseUrl;

  /// Voice used when a request does not specify one.
  final String defaultVoiceId;

  /// Transport used by [synthesizeStream].
  final SixtyDbStreamTransport streamTransport;

  /// Audio configuration for the WebSocket transport.
  final SixtyDbWebSocketAudioConfig webSocketAudioConfig;

  final http.Client _client;
  final bool _ownsClient;
  final String? _webSocketUrlOverride;
  int _contextCounter = 0;
  bool _disposed = false;

  /// Creates a 60db TTS provider.
  ///
  /// * [apiKey] — required 60db API key.
  /// * [baseUrl] — override the REST base URL (defaults to [defaultBaseUrl]).
  /// * [webSocketUrl] — override the WebSocket URL (defaults to the `wss`
  ///   form of [baseUrl] with `/ws/tts`).
  /// * [defaultVoiceId] — voice used when a request omits one.
  /// * [streamTransport] — transport for [synthesizeStream] (defaults to HTTP
  ///   NDJSON).
  /// * [httpClient] — inject a custom/mock [http.Client]; if omitted one is
  ///   created and owned (and closed by [dispose]).
  SixtyDbTtsProvider({
    required this.apiKey,
    String? baseUrl,
    String? webSocketUrl,
    String? defaultVoiceId,
    this.streamTransport = SixtyDbStreamTransport.http,
    this.webSocketAudioConfig = const SixtyDbWebSocketAudioConfig(),
    http.Client? httpClient,
  })  : assert(apiKey != '', 'apiKey must not be empty'),
        baseUrl = _stripTrailingSlash(baseUrl ?? defaultBaseUrl),
        defaultVoiceId = defaultVoiceId ?? defaultVoice,
        _webSocketUrlOverride = webSocketUrl,
        _client = httpClient ?? http.Client(),
        _ownsClient = httpClient == null;

  @override
  Future<TtsAudio> synthesize(String text, {TtsVoiceSettings? voice}) async {
    _ensureUsable(text);

    final uri = Uri.parse('$baseUrl/tts-synthesize');
    final http.Response response;
    try {
      response = await _client.post(
        uri,
        headers: _jsonHeaders,
        body: jsonEncode(_requestBody(text, voice, includeFormat: true)),
      );
    } catch (e) {
      throw TtsException('Network error calling /tts-synthesize', cause: e);
    }

    if (response.statusCode != 200) {
      throw TtsException(
        'Synthesis request failed',
        statusCode: response.statusCode,
        cause: response.body,
      );
    }

    final Map<String, dynamic> body;
    try {
      body = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (e) {
      throw TtsException('Malformed /tts-synthesize response', cause: e);
    }

    if (body['success'] == false) {
      throw TtsException(
        (body['message'] as String?) ?? 'Synthesis was not successful',
      );
    }

    final audioB64 = body['audio_base64'] as String?;
    if (audioB64 == null || audioB64.isEmpty) {
      throw TtsException('Response did not contain audio data');
    }

    final requestedFormat = voice?.outputFormat ?? TtsAudioFormat.mp3;
    return TtsAudio(
      bytes: _decodeBase64(audioB64),
      format: _formatFromWire(
        body['output_format'] as String?,
        requestedFormat,
      ),
      sampleRate: (body['sample_rate'] as num?)?.toInt(),
      durationSeconds: (body['duration_seconds'] as num?)?.toDouble(),
      encoding: body['encoding'] as String?,
    );
  }

  @override
  Stream<Uint8List> synthesizeStream(String text, {TtsVoiceSettings? voice}) {
    _ensureUsable(text);
    switch (streamTransport) {
      case SixtyDbStreamTransport.http:
        return _streamHttp(text, voice);
      case SixtyDbStreamTransport.webSocket:
        return _streamWebSocket(text, voice);
    }
  }

  /// NDJSON streaming over `POST /tts-stream`.
  Stream<Uint8List> _streamHttp(String text, TtsVoiceSettings? voice) async* {
    final request = http.Request('POST', Uri.parse('$baseUrl/tts-stream'))
      ..headers.addAll(_jsonHeaders)
      ..body = jsonEncode(_requestBody(text, voice, includeFormat: false));

    final http.StreamedResponse response;
    try {
      response = await _client.send(request);
    } catch (e) {
      throw TtsException('Network error calling /tts-stream', cause: e);
    }

    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString();
      throw TtsException(
        'Streaming request failed',
        statusCode: response.statusCode,
        cause: body,
      );
    }

    final lines =
        response.stream.transform(utf8.decoder).transform(const LineSplitter());

    await for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      final Map<String, dynamic> message;
      try {
        message = jsonDecode(trimmed) as Map<String, dynamic>;
      } catch (_) {
        // Skip any keep-alive or non-JSON framing lines defensively.
        continue;
      }

      final error = _extractError(message);
      if (error != null) {
        throw TtsException(error);
      }

      final audio = _extractStreamAudio(message);
      if (audio != null) {
        yield _decodeBase64(audio);
      }

      if (_isComplete(message)) {
        return;
      }
    }
  }

  /// Bidirectional streaming over the `/ws/tts` WebSocket.
  Stream<Uint8List> _streamWebSocket(
    String text,
    TtsVoiceSettings? voice,
  ) async* {
    final contextId = 'ctx-${DateTime.now().microsecondsSinceEpoch}-'
        '${_contextCounter++}';
    final channel = WebSocketChannel.connect(_webSocketUri);

    try {
      await channel.ready;

      channel.sink.add(jsonEncode({
        'create_context': {
          'context_id': contextId,
          'voice_id': voice?.voiceId ?? defaultVoiceId,
          'audio_config': webSocketAudioConfig.toJson(),
          if (voice?.speed != null) 'speed': voice!.speed,
          if (voice?.stability != null) 'stability': voice!.stability,
          if (voice?.similarity != null) 'similarity': voice!.similarity,
        },
      }));
      channel.sink.add(jsonEncode({
        'send_text': {'context_id': contextId, 'text': text},
      }));
      channel.sink.add(jsonEncode({
        'flush_context': {'context_id': contextId},
      }));

      await for (final raw in channel.stream) {
        if (raw is! String) continue;

        final Map<String, dynamic> message;
        try {
          message = jsonDecode(raw) as Map<String, dynamic>;
        } catch (_) {
          continue;
        }

        final error = _extractError(message);
        if (error != null) {
          throw TtsException(error);
        }

        final audio = _extractWebSocketAudio(message);
        if (audio != null) {
          yield _decodeBase64(audio);
        }

        // A flush completes the current synthesis; a closed context (or a
        // closed socket) ends the stream.
        if (message.containsKey('flush_completed') ||
            message.containsKey('context_closed')) {
          break;
        }
      }
    } catch (e) {
      if (e is TtsException) rethrow;
      throw TtsException('WebSocket streaming failed', cause: e);
    } finally {
      try {
        channel.sink.add(jsonEncode({
          'close_context': {'context_id': contextId},
        }));
      } catch (_) {
        // Socket may already be closed; ignore.
      }
      await channel.sink.close();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_ownsClient) {
      _client.close();
    }
  }

  // --- helpers -------------------------------------------------------------

  Map<String, String> get _jsonHeaders => {
        'Authorization': 'Bearer $apiKey',
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      };

  Uri get _webSocketUri {
    final base = _webSocketUrlOverride ?? _deriveWebSocketUrl(baseUrl);
    return Uri.parse(base).replace(queryParameters: {'apiKey': apiKey});
  }

  Map<String, dynamic> _requestBody(
    String text,
    TtsVoiceSettings? voice, {
    required bool includeFormat,
  }) {
    return {
      'text': text,
      'voice_id': voice?.voiceId ?? defaultVoiceId,
      if (voice?.enhance != null) 'enhance': voice!.enhance,
      if (voice?.speed != null) 'speed': voice!.speed,
      if (voice?.stability != null) 'stability': voice!.stability,
      if (voice?.similarity != null) 'similarity': voice!.similarity,
      if (includeFormat)
        'output_format':
            (voice?.outputFormat ?? TtsAudioFormat.mp3).wireValue,
    };
  }

  void _ensureUsable(String text) {
    if (_disposed) {
      throw StateError('SixtyDbTtsProvider has been disposed');
    }
    if (text.trim().isEmpty) {
      throw ArgumentError.value(text, 'text', 'must not be empty');
    }
  }

  Uint8List _decodeBase64(String value) {
    try {
      return base64Decode(value);
    } catch (e) {
      throw TtsException('Failed to decode audio payload', cause: e);
    }
  }

  /// NDJSON chunk shapes vary; accept the documented form and a couple of
  /// defensive variants.
  static String? _extractStreamAudio(Map<String, dynamic> m) {
    final direct = m['audioContent'] ?? m['audio_base64'] ?? m['audio'];
    if (direct is String) return direct;
    final chunk = m['chunk'];
    if (chunk is String) return chunk;
    if (chunk is Map) {
      final c = chunk['audioContent'] ?? chunk['audio_base64'] ?? chunk['audio'];
      if (c is String) return c;
    }
    return null;
  }

  static String? _extractWebSocketAudio(Map<String, dynamic> m) {
    final chunk = m['audio_chunk'];
    if (chunk is Map) {
      final c = chunk['audioContent'] ?? chunk['audio'] ?? chunk['audio_base64'];
      if (c is String) return c;
    }
    return null;
  }

  static bool _isComplete(Map<String, dynamic> m) {
    if (m.containsKey('complete')) return true;
    if (m['type'] == 'complete') return true;
    if (m['done'] == true) return true;
    return false;
  }

  static String? _extractError(Map<String, dynamic> m) {
    final err = m['error'];
    if (err == null) return null;
    if (err is String) return err;
    if (err is Map) {
      return (err['message'] as String?) ?? err.toString();
    }
    return err.toString();
  }

  static TtsAudioFormat _formatFromWire(String? wire, TtsAudioFormat fallback) {
    switch (wire?.toLowerCase()) {
      case 'mp3':
        return TtsAudioFormat.mp3;
      case 'wav':
        return TtsAudioFormat.wav;
      case 'ogg':
        return TtsAudioFormat.ogg;
      case 'flac':
        return TtsAudioFormat.flac;
      case 'pcm16':
      case 'linear16':
      case 'pcm_s16le':
        return TtsAudioFormat.pcm16;
      case 'mulaw':
      case 'ulaw':
        return TtsAudioFormat.mulaw;
      case 'ogg_opus':
        return TtsAudioFormat.oggOpus;
      default:
        return fallback;
    }
  }

  static String _stripTrailingSlash(String url) =>
      url.endsWith('/') ? url.substring(0, url.length - 1) : url;

  static String _deriveWebSocketUrl(String baseUrl) {
    final ws = baseUrl
        .replaceFirst(RegExp(r'^https://'), 'wss://')
        .replaceFirst(RegExp(r'^http://'), 'ws://');
    return '$ws/ws/tts';
  }
}
