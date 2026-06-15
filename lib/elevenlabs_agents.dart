/// Flutter SDK for ElevenLabs Agent Platform
///
/// Provides conversational AI capabilities using the ElevenLabs Agent Platform
/// with WebRTC-based real-time audio communication via LiveKit.
library;

// Main client
export 'src/client/conversation_client.dart';

// Models
export 'src/models/conversation_status.dart';
export 'src/models/conversation_config.dart';
export 'src/models/callbacks.dart';
export 'src/models/events.dart';

// Tools
export 'src/tools/client_tools.dart';

// Text-to-speech providers (standalone, independent of ConversationClient)
export 'src/tts/tts_provider.dart';
export 'src/tts/tts_models.dart';
export 'src/tts/sixtydb_tts_provider.dart';

// Version
export 'version.dart';
