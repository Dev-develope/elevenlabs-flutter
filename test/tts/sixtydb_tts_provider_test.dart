import 'dart:convert';
import 'dart:typed_data';

import 'package:elevenlabs_agents/elevenlabs_agents.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Base64 of the bytes [1, 2, 3, 4].
final _audioBytes = Uint8List.fromList([1, 2, 3, 4]);
final _audioB64 = base64Encode(_audioBytes);

void main() {
  group('SixtyDbTtsProvider.synthesize', () {
    test('sends a well-formed request and decodes the response', () async {
      late http.Request captured;

      final client = MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'success': true,
            'audio_base64': _audioB64,
            'sample_rate': 24000,
            'duration_seconds': 1.5,
            'encoding': 'mp3',
            'output_format': 'mp3',
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final provider = SixtyDbTtsProvider(apiKey: 'sk_test', httpClient: client);
      final audio = await provider.synthesize(
        'Hello world',
        voice: const TtsVoiceSettings(voiceId: 'voice-1', speed: 1.2),
      );

      // Request shape
      expect(captured.method, 'POST');
      expect(captured.url.toString(), 'https://api.60db.ai/tts-synthesize');
      expect(captured.headers['Authorization'], 'Bearer sk_test');
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['text'], 'Hello world');
      expect(body['voice_id'], 'voice-1');
      expect(body['speed'], 1.2);
      expect(body['output_format'], 'mp3');

      // Response decoding
      expect(audio.bytes, _audioBytes);
      expect(audio.format, TtsAudioFormat.mp3);
      expect(audio.sampleRate, 24000);
      expect(audio.durationSeconds, 1.5);

      provider.dispose();
    });

    test('falls back to the default voice when none is given', () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({'success': true, 'audio_base64': _audioB64}),
          200,
        );
      });

      final provider = SixtyDbTtsProvider(apiKey: 'sk_test', httpClient: client);
      await provider.synthesize('Hi');

      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['voice_id'], SixtyDbTtsProvider.defaultVoice);
      provider.dispose();
    });

    test('honors a custom output format', () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'success': true,
            'audio_base64': _audioB64,
            'output_format': 'wav',
          }),
          200,
        );
      });

      final provider = SixtyDbTtsProvider(apiKey: 'sk_test', httpClient: client);
      final audio = await provider.synthesize(
        'Hi',
        voice: const TtsVoiceSettings(outputFormat: TtsAudioFormat.wav),
      );

      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['output_format'], 'wav');
      expect(audio.format, TtsAudioFormat.wav);
      provider.dispose();
    });

    test('throws TtsException with status code on HTTP error', () async {
      final client = MockClient(
        (request) async => http.Response('nope', 401),
      );
      final provider = SixtyDbTtsProvider(apiKey: 'sk_test', httpClient: client);

      await expectLater(
        provider.synthesize('Hi'),
        throwsA(isA<TtsException>()
            .having((e) => e.statusCode, 'statusCode', 401)),
      );
      provider.dispose();
    });

    test('throws TtsException when success is false', () async {
      final client = MockClient(
        (request) async => http.Response(
          jsonEncode({'success': false, 'message': 'bad voice'}),
          200,
        ),
      );
      final provider = SixtyDbTtsProvider(apiKey: 'sk_test', httpClient: client);

      await expectLater(
        provider.synthesize('Hi'),
        throwsA(isA<TtsException>()
            .having((e) => e.message, 'message', contains('bad voice'))),
      );
      provider.dispose();
    });

    test('rejects empty text', () async {
      final provider = SixtyDbTtsProvider(apiKey: 'sk_test');
      expect(() => provider.synthesize('   '), throwsArgumentError);
      provider.dispose();
    });

    test('throws StateError after dispose', () async {
      final provider = SixtyDbTtsProvider(apiKey: 'sk_test');
      provider.dispose();
      expect(() => provider.synthesize('Hi'), throwsStateError);
    });
  });

  group('SixtyDbTtsProvider.synthesizeStream (HTTP NDJSON)', () {
    test('yields decoded audio chunks and stops on complete', () async {
      final chunkB64 = base64Encode(Uint8List.fromList([10, 20]));
      final lines = [
        jsonEncode({
          'chunk': {'audioContent': chunkB64}
        }),
        jsonEncode({
          'chunk': {'audioContent': chunkB64}
        }),
        jsonEncode({'complete': true}),
        // Anything after complete must be ignored.
        jsonEncode({
          'chunk': {'audioContent': _audioB64}
        }),
      ];

      final client = MockClient.streaming((request, bodyStream) async {
        final stream = Stream.fromIterable(
          lines.map((l) => utf8.encode('$l\n')),
        );
        return http.StreamedResponse(stream, 200);
      });

      final provider = SixtyDbTtsProvider(apiKey: 'sk_test', httpClient: client);
      final chunks = await provider.synthesizeStream('Hi').toList();

      expect(chunks, hasLength(2));
      expect(chunks[0], Uint8List.fromList([10, 20]));
      provider.dispose();
    });

    test('surfaces an error line as a stream error', () async {
      final client = MockClient.streaming((request, bodyStream) async {
        final stream = Stream.fromIterable([
          utf8.encode('${jsonEncode({'error': 'synthesis failed'})}\n'),
        ]);
        return http.StreamedResponse(stream, 200);
      });

      final provider = SixtyDbTtsProvider(apiKey: 'sk_test', httpClient: client);

      await expectLater(
        provider.synthesizeStream('Hi'),
        emitsError(isA<TtsException>()
            .having((e) => e.message, 'message', contains('synthesis failed'))),
      );
      provider.dispose();
    });

    test('throws on non-200 streaming response', () async {
      final client = MockClient.streaming((request, bodyStream) async {
        return http.StreamedResponse(
          Stream.fromIterable([utf8.encode('boom')]),
          500,
        );
      });
      final provider = SixtyDbTtsProvider(apiKey: 'sk_test', httpClient: client);

      await expectLater(
        provider.synthesizeStream('Hi'),
        emitsError(isA<TtsException>()
            .having((e) => e.statusCode, 'statusCode', 500)),
      );
      provider.dispose();
    });
  });

  group('TtsAudioFormat', () {
    test('exposes the expected wire values', () {
      expect(TtsAudioFormat.mp3.wireValue, 'mp3');
      expect(TtsAudioFormat.oggOpus.wireValue, 'ogg_opus');
      expect(TtsAudioFormat.pcm16.wireValue, 'pcm16');
    });
  });

  group('TtsVoiceSettings.copyWith', () {
    test('replaces only the provided fields', () {
      const original = TtsVoiceSettings(voiceId: 'a', speed: 1.0);
      final updated = original.copyWith(speed: 1.5);
      expect(updated.voiceId, 'a');
      expect(updated.speed, 1.5);
    });
  });
}
