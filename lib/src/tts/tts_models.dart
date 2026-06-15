import 'dart:typed_data';

/// Audio container/encoding requested from a [TtsProvider].
///
/// Not every value is supported by every provider or every transport; see the
/// individual provider documentation for the supported subset.
enum TtsAudioFormat {
  mp3('mp3'),
  wav('wav'),
  ogg('ogg'),
  flac('flac'),

  /// 16-bit signed little-endian PCM, mono. Used by the 60db WebSocket
  /// transport (`LINEAR16`).
  pcm16('pcm16'),

  /// G.711 mu-law, 8-bit, 8 kHz mono. Used by the 60db WebSocket transport
  /// (`MULAW`) for telephony.
  mulaw('mulaw'),

  /// Ogg Opus compressed. Used by the 60db WebSocket transport (`OGG_OPUS`).
  oggOpus('ogg_opus');

  const TtsAudioFormat(this.wireValue);

  /// The string the provider expects on the wire.
  final String wireValue;
}

/// Provider-agnostic voice and expressiveness settings for a synthesis request.
///
/// Values are intentionally normalized to the ranges documented by 60db so the
/// same settings object can be reused across providers. Fields left `null` fall
/// back to the provider's own defaults.
class TtsVoiceSettings {
  /// Identifier of the voice to synthesize with. When `null` the provider's
  /// default voice is used.
  final String? voiceId;

  /// Playback speed multiplier. Range `0.5`–`2.0` (default `1.0`).
  final double? speed;

  /// Expressiveness. Range `0`–`100`; lower is more expressive, higher is more
  /// consistent (default `50`).
  final double? stability;

  /// How closely the output matches the source voice. Range `0`–`100`
  /// (default `75`).
  final double? similarity;

  /// Whether the provider should apply its audio-quality enhancement pass.
  final bool? enhance;

  /// Desired output format. Defaults to [TtsAudioFormat.mp3] for HTTP transports
  /// and is ignored where the transport fixes the format.
  final TtsAudioFormat? outputFormat;

  const TtsVoiceSettings({
    this.voiceId,
    this.speed,
    this.stability,
    this.similarity,
    this.enhance,
    this.outputFormat,
  });

  /// Returns a copy with the given fields replaced.
  TtsVoiceSettings copyWith({
    String? voiceId,
    double? speed,
    double? stability,
    double? similarity,
    bool? enhance,
    TtsAudioFormat? outputFormat,
  }) {
    return TtsVoiceSettings(
      voiceId: voiceId ?? this.voiceId,
      speed: speed ?? this.speed,
      stability: stability ?? this.stability,
      similarity: similarity ?? this.similarity,
      enhance: enhance ?? this.enhance,
      outputFormat: outputFormat ?? this.outputFormat,
    );
  }
}

/// The result of a non-streaming synthesis call.
class TtsAudio {
  /// Decoded audio bytes (already base64-decoded), ready to write to a file or
  /// hand to an audio player.
  final Uint8List bytes;

  /// Sample rate in Hz, if reported by the provider.
  final int? sampleRate;

  /// Duration of the audio in seconds, if reported by the provider.
  final double? durationSeconds;

  /// Provider-reported encoding string (e.g. `mp3`, `pcm_s16le`), if any.
  final String? encoding;

  /// The format of [bytes].
  final TtsAudioFormat format;

  const TtsAudio({
    required this.bytes,
    required this.format,
    this.sampleRate,
    this.durationSeconds,
    this.encoding,
  });
}

/// Thrown when a [TtsProvider] fails to synthesize audio.
class TtsException implements Exception {
  /// Human-readable description of what went wrong.
  final String message;

  /// HTTP status code, when the failure originated from an HTTP response.
  final int? statusCode;

  /// The underlying error/exception, when one was caught.
  final Object? cause;

  const TtsException(this.message, {this.statusCode, this.cause});

  @override
  String toString() {
    final code = statusCode != null ? ' (HTTP $statusCode)' : '';
    final because = cause != null ? ': $cause' : '';
    return 'TtsException$code: $message$because';
  }
}
