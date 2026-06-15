import 'dart:typed_data';

import 'tts_models.dart';

/// A provider-agnostic text-to-speech backend.
///
/// Implementations turn text into audio. This abstraction is deliberately
/// separate from [ConversationClient] (which drives a real-time LiveKit/WebRTC
/// conversation): a [TtsProvider] is a standalone "text in, audio out" service.
///
/// Two synthesis styles are supported:
///
/// * [synthesize] — one-shot: returns the complete audio once it is ready.
/// * [synthesizeStream] — incremental: yields audio chunks as they arrive, for
///   lower time-to-first-byte and playback while synthesis continues.
///
/// Concrete providers (e.g. [SixtyDbTtsProvider]) decide which network
/// transport backs each method.
abstract class TtsProvider {
  /// Synthesizes [text] in full and returns the decoded audio.
  ///
  /// Throws [TtsException] on failure.
  Future<TtsAudio> synthesize(String text, {TtsVoiceSettings? voice});

  /// Synthesizes [text], yielding decoded audio byte chunks as they arrive.
  ///
  /// Chunks for most formats can be concatenated directly to reconstruct the
  /// full clip. The stream completes when synthesis finishes and emits a
  /// [TtsException] as a stream error on failure.
  Stream<Uint8List> synthesizeStream(String text, {TtsVoiceSettings? voice});

  /// Releases any resources held by the provider (e.g. HTTP clients).
  ///
  /// Safe to call multiple times.
  void dispose();
}
