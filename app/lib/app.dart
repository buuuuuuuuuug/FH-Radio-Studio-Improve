import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/fh_radio_studio_cli.dart';
import 'core/windows_close_guard.dart';
import 'state/app_state.dart';
import 'state/studio_state.dart';
import 'state/router.dart';
import 'state/unsaved_edits.dart';
import 'state/playlist_plan_state.dart';
import 'theme/app_theme.dart';

class FhRadioStudioApp extends ConsumerStatefulWidget {
  const FhRadioStudioApp({super.key});

  @override
  ConsumerState<FhRadioStudioApp> createState() => _FhRadioStudioAppState();
}

class _FhRadioStudioAppState extends ConsumerState<FhRadioStudioApp>
    with WidgetsBindingObserver {
  WindowsCloseGuard? _closeGuard;
  bool _closeRequested = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _closeGuard = WindowsCloseGuard.install(_requestNativeClose);
      if (Platform.environment['FH_RADIO_STUDIO_UI_TEST_PROJECT'] == null) {
        ref.read(studioProvider.notifier).startupFullCheckOnce();
      }
    });
  }

  @override
  Future<ui.AppExitResponse> didRequestAppExit() async {
    final context = appRouter.routerDelegate.navigatorKey.currentContext;
    if (context != null &&
        !await ref.read(unsavedEditsProvider).confirm(context, exiting: true)) {
      return ui.AppExitResponse.cancel;
    }
    await FhRadioStudioCli.killActiveProcesses();
    return ui.AppExitResponse.exit;
  }

  Future<void> _requestNativeClose() async {
    if (!mounted || _closeRequested) return;
    _closeRequested = true;
    try {
      final context = appRouter.routerDelegate.navigatorKey.currentContext;
      if (context != null &&
          !await ref
              .read(unsavedEditsProvider)
              .confirm(context, exiting: true)) {
        return;
      }
      await FhRadioStudioCli.killActiveProcesses();
      _closeGuard?.closeApproved();
    } finally {
      _closeRequested = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      unawaited(FhRadioStudioCli.killActiveProcesses());
    }
  }

  @override
  void dispose() {
    _closeGuard?.dispose();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(FhRadioStudioCli.killActiveProcesses());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(playlistPlanProvider.select((_) => true));
    final accent = ref.watch(accentProvider);
    final customAccent = ref.watch(customAccentProvider);
    final mode = ref.watch(themeModeProvider);

    return MaterialApp.router(
      title: 'FH Audio Studio',
      debugShowCheckedModeBanner: false,
      themeMode: mode,
      themeAnimationDuration: Duration.zero,
      theme: buildAppTheme(
        brightness: Brightness.light,
        accent: accent,
        customAccent: customAccent,
      ),
      darkTheme: buildAppTheme(
        brightness: Brightness.dark,
        accent: accent,
        customAccent: customAccent,
      ),
      routerConfig: appRouter,
      builder: (context, child) {
        // 防止系统字体缩放破坏密集 UI
        return MediaQuery.withClampedTextScaling(
          minScaleFactor: 1,
          maxScaleFactor: 1,
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
  }
}
