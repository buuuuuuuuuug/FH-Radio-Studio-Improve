import 'package:go_router/go_router.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'unsaved_edits.dart';

import '../screens/custom_pool.dart';
import '../screens/dashboard.dart';
import '../screens/playlist.dart';
import '../screens/project_picker.dart';
import '../screens/replace_editor.dart';
import '../screens/siren_library.dart';
import '../screens/stingers.dart';
import '../screens/voice_replacement.dart';
import '../shell/app_shell.dart';
import '../widgets/audio_editor_dialog.dart';
import '../tweaks/tweaks_panel.dart';

/// 路由 id → path。Sidebar/Tabs 用这里。
class RmRoutes {
  RmRoutes._();
  static const boot = '/boot';
  static const dashboard = '/dashboard';
  static const pool = '/pool';
  static const siren = '/siren';
  static const playlist = '/playlist';
  static const stingers = '/stingers';
  static const voices = '/voices';
  static const settings = '/settings';
  static String editor(String trackId, {bool fromPlaylist = false}) =>
      '/editor/${Uri.encodeComponent(trackId)}${fromPlaylist ? '?from=playlist' : ''}';
  static const editorPath = '/editor/:trackId';
}

final GoRouter appRouter = GoRouter(
  initialLocation: RmRoutes.boot,
  routes: [
    GoRoute(path: '/', redirect: (_, _) => RmRoutes.boot),
    GoRoute(
      path: RmRoutes.boot,
      builder: (_, state) => ProjectPickerScreen(
        autoOpen: state.uri.queryParameters['manual'] != '1',
      ),
    ),
    ShellRoute(
      builder: (context, state, child) => AppShell(child: child),
      routes: [
        GoRoute(
          path: RmRoutes.settings,
          pageBuilder: (_, _) => const NoTransitionPage(child: TweaksPanel()),
        ),
        GoRoute(
          path: RmRoutes.dashboard,
          pageBuilder: (_, _) =>
              const NoTransitionPage(child: DashboardScreen()),
        ),
        GoRoute(
          path: RmRoutes.pool,
          pageBuilder: (_, _) =>
              const NoTransitionPage(child: CustomPoolScreen()),
        ),
        GoRoute(
          path: RmRoutes.siren,
          pageBuilder: (_, _) =>
              const NoTransitionPage(child: SirenLibraryScreen()),
        ),
        GoRoute(
          path: RmRoutes.playlist,
          pageBuilder: (_, _) =>
              const NoTransitionPage(child: PlaylistScreen()),
        ),
        GoRoute(
          path: RmRoutes.voices,
          pageBuilder: (_, _) => const NoTransitionPage(
            child: AudioEditorHost(
              key: ValueKey('voice-editor-host'),
              child: VoiceReplacementScreen(),
            ),
          ),
        ),
        GoRoute(
          path: RmRoutes.stingers,
          pageBuilder: (_, _) => const NoTransitionPage(
            child: AudioEditorHost(
              key: ValueKey('stinger-editor-host'),
              child: StingersScreen(),
            ),
          ),
        ),
        GoRoute(
          path: RmRoutes.editorPath,
          onExit: (context, state) => ProviderScope.containerOf(
            context,
          ).read(unsavedEditsProvider).confirm(context, key: 'editor'),
          pageBuilder: (_, state) => NoTransitionPage(
            child: ReplaceEditorScreen(
              trackId: state.pathParameters['trackId']!,
              returnToPlaylist: state.uri.queryParameters['from'] == 'playlist',
            ),
          ),
        ),
      ],
    ),
  ],
);
