class AgoraConfig {
  // Prefer passing secrets with --dart-define in production.
  static const String appId = String.fromEnvironment(
    'AGORA_APP_ID',
    defaultValue: '315eb44c664e4817a89e21392ca42aea',
  );

  // Keep empty if your Agora project allows tokenless testing.
  static const String token = String.fromEnvironment(
    'AGORA_TEMP_TOKEN',
    defaultValue:
        '007eJxTYMiUtGxr2luyRcQ97bHJYS3rY9Mfuc+btki5kOvVO/dNXMsUGIwNTVOTTEySzcxMUk0sDM0TLSxTjQyNLY2SE02MElMTmULfZDYEMjJ8WGfMxMgAgSA+O4NrRWJuQU4qAwMAajsf6w==',
  );

  static bool get isConfigured => appId.trim().isNotEmpty;
}
