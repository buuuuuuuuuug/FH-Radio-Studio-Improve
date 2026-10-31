import 'widgets/feature_tour.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/fh_radio_studio_cli.dart';
import 'state/app_state.dart';
import 'core/studio_audio_players.dart';
import 'core/studio_http_proxy.dart';

Future<void> main({
  bool localSmoke = false,
  SharedPreferences? localPreferences,
}) async {
  WidgetsFlutterBinding.ensureInitialized();
  await StudioHttpProxy.install();
  MediaKit.ensureInitialized();
  // Isolate preferences from the user's existing modified Studio installation.
  final uiTest =
      Platform.environment['FH_RADIO_STUDIO_UI_TEST_PROJECT'] ??
      localDevelopmentConfig()['project_root'] as String?;
  if (localPreferences == null) {
    SharedPreferences.setPrefix(
      uiTest == null ? 'fh_loop_lab.' : 'fh_loop_lab_ui_test.',
    );
  }
  final prefs = localPreferences ?? await SharedPreferences.getInstance();
  if (uiTest != null) await prefs.setString('rm.studio.projectDir', uiTest);

  runApp(
    ProviderScope(
      overrides: [
        automaticFeatureToursProvider.overrideWithValue(!localSmoke),
        sharedPreferencesProvider.overrideWithValue(prefs),
      ],
      child: const FhRadioStudioApp(),
    ),
  );
  StudioAudioPlayers.warmUp();
}
