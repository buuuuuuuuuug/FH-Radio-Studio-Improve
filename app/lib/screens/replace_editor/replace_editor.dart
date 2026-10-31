import '../../widgets/editor_columns.dart';
import '../../widgets/editor_controls.dart';
import '../../core/waveform_zoom.dart';
import '../../core/demo_song.dart';
import '../../widgets/feature_tour.dart';
import 'waveform_overview.dart';
import '../../core/playback_window.dart';
import '../../widgets/quick_assign_dialog.dart';
import '../../state/editor_shortcuts.dart';
import '../../state/editor_navigation.dart';
import '../../widgets/editor_song_navigation.dart';
import '../../state/audition_preferences.dart';
import '../../widgets/audition_settings_button.dart';
import '../../core/seam_audition_player.dart';
import 'package:go_router/go_router.dart';
import '../../core/delayed_repeat.dart';
import 'editor_timecode.dart';
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import '../../state/layout_options.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import '../../core/system_audio_output.dart';
import '../../core/studio_audio_players.dart';
import '../../core/track_timing_config.dart';
import '../../domain/replacement_models.dart';
import '../../state/audio_analysis_state.dart';
import '../../state/studio_state.dart';
import '../../state/track_timing_state.dart';
import '../../state/editor_options.dart';
import '../../state/router.dart';
import '../../theme/app_theme.dart';
import '../../theme/text_styles.dart';
import '../../theme/tokens.dart';
import '../../widgets/rm_banner.dart';
import '../../widgets/song_metadata_button.dart';
import '../../widgets/bpm_edit_button.dart';
import '../../widgets/rm_button.dart';
import '../../widgets/rm_icon.dart';
import '../../widgets/rm_chip.dart';
import 'ai_pending_overlay.dart';
import 'breadcrumb.dart';
import 'group_colors.dart';
import 'manual_focus_waveform.dart';
import '../../widgets/time_input_field.dart';
import 'progress_strip.dart';
import 'replace_state.dart';
import 'side_panel.dart';
import 'time_group_card.dart';
import 'transport_bar.dart';
import 'waveform_card.dart';

@visibleForTesting
const double pointPreviewDurationSec = 6;

@visibleForTesting
const double loopSeamPreviewLeadInSec = 2;

@visibleForTesting
const double previewSeekPositionToleranceSec = 0.35;

@visibleForTesting
const Duration previewSeekPositionHold = Duration(seconds: 2);

@visibleForTesting
String previewMpvTimestampForTesting(double seconds) {
  return _mpvTimestamp(seconds);
}

@visibleForTesting
({double start, double end}) pointPreviewWindowForTesting({
  required double timeSec,
  required double durationSec,
  double previewDuration = pointPreviewDurationSec,
}) {
  final duration = math.max(0, durationSec);
  final start = timeSec.clamp(0, duration).toDouble();
  final end = math
      .min(start + previewDuration.clamp(1, 30), duration)
      .toDouble();
  return (start: start, end: end);
}

@visibleForTesting
double loopPreviewAuditionStartForTesting({
  required double startSec,
  required double endSec,
}) {
  return (endSec - loopSeamPreviewLeadInSec).clamp(startSec, endSec).toDouble();
}

@visibleForTesting
bool isStalePreviewStartupPositionForTesting({
  required double positionSec,
  required double targetSec,
}) {
  return _isStalePreviewStartupPosition(positionSec, targetSec);
}

bool _isStalePreviewStartupPosition(double positionSec, double targetSec) {
  if (!positionSec.isFinite || !targetSec.isFinite) return false;
  return (positionSec - targetSec).abs() > previewSeekPositionToleranceSec;
}

String _mpvTimestamp(double seconds) {
  final safeSeconds = seconds.isFinite ? seconds : 0.0;
  return safeSeconds.toStringAsFixed(6);
}

class ReplaceEditorScreen extends ConsumerStatefulWidget {
  const ReplaceEditorScreen({
    super.key,
    required this.trackId,
    this.enableAudio = true,
    this.returnToPlaylist = false,
  });
  final String trackId;
  final bool enableAudio;
  final bool returnToPlaylist;

  @override
  ConsumerState<ReplaceEditorScreen> createState() =>
      _ReplaceEditorScreenState();
}

class _ReplaceEditorScreenState extends ConsumerState<ReplaceEditorScreen> {
  final ScrollController _pageScrollController = ScrollController();
  final GlobalKey _editorViewportKey = GlobalKey(
    debugLabel: 'replace-editor-viewport',
  );
  final GlobalKey _scrollContentKey = GlobalKey(
    debugLabel: 'replace-editor-scroll-content',
  );
  final FocusNode _hotkeysFocus = FocusNode(
    debugLabel: 'replace-editor-hotkeys',
  );
  Player? _player;
  SystemAudioOutputFollower? _audioOutputFollower;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<bool>? _completedSub;
  StreamSubscription<String>? _errorSub;
  String? _loadedSource;
  Future<void>? _loadAudioFuture;
  int _loadVersion = 0;
  int _playbackVersion = 0;
  bool _pausedByUser = false;
  bool _rangeSeeking = false;
  int? _positionHoldCommand;
  double? _positionHoldTargetSec;
  Timer? _positionHoldTimer;
  String? _analysisStartedFor;
  _PreviewRange? _previewRange;
  SeamAuditionPlayer? _seamAudition;
  bool _sideDrawerOpen = false;
  bool _savePromptOpen = false;
  bool _lastObservedAllConfirmed = false;
  double _sidePanelExtraScroll = 0;
  _TransportDockMetrics? _transportDockMetrics;
  _ManualRefineSession? _manualSession;
  bool _manualDraftChanged = false;
  _ManualRefineSession? _manualInitial;
  final _manualUndo = <_ManualRefineSession>[];
  final _manualRedo = <_ManualRefineSession>[];
  int _manualSuggestionCursor = -1;
  ReplaceEditorNotifier? _manualNotifier;
  bool _playbackInManual = false;
  ({double playhead, bool playing, PlaybackMode mode})? _manualPlayback;
  bool _manualSnapToBeat = true;
  bool _pendingSnapToggle = false;
  bool _altHeld = false;
  bool _freeHeld = false;
  bool _shiftHeld = false;
  bool _ctrlHeld = false;
  final _keyRepeat = DelayedRepeat();
  LogicalKeyboardKey? _repeatKey;
  final _blockedRepeatKeys = <LogicalKeyboardKey>{};

  @override
  void initState() {
    super.initState();
    if (widget.enableAudio) {
      final player = _audioPlayer;
      _positionSub = player.stream.position.listen(_handlePosition);
      _playingSub = player.stream.playing.listen((playing) {
        if (!mounted) return;
        final n = ref.read(replaceEditorProvider(widget.trackId).notifier);
        _setPlayback(
          n,
          _currentPlaybackMode,
          playing: playing && !player.state.completed,
        );
      });
      _completedSub = player.stream.completed.listen((completed) {
        if (!mounted || !completed || _seamAudition?.active == true) return;
        final n = ref.read(replaceEditorProvider(widget.trackId).notifier);
        _previewRange = null;
        _rangeSeeking = false;
        _pausedByUser = false;
        _clearPreviewPositionHold();
        unawaited(_clearNativePreviewBounds(player));
        _setPlayback(n, PlaybackMode.idle, playing: false);
      });
      _errorSub = player.stream.error.listen((message) {
        if (!mounted) return;
        final n = ref.read(replaceEditorProvider(widget.trackId).notifier);
        _clearLocalPlaybackState();
        _setPlayback(n, PlaybackMode.idle, playing: false);
        n.setError('内置播放器错误：$message');
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _hotkeysFocus.requestFocus();
      _startInitialAnalysis();
      unawaited(_warmUpAudio());
    });
  }

  @override
  void didUpdateWidget(covariant ReplaceEditorScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.trackId == widget.trackId) return;
    _clearManualHooks();
    _manualSession = null;
    _manualDraftChanged = false;
    _analysisStartedFor = null;
    _clearLocalPlaybackState();
    if (_pageScrollController.hasClients) _pageScrollController.jumpTo(0);
    _lastObservedAllConfirmed = false;
    final player = _player;
    if (player != null) {
      unawaited(player.stop());
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(replaceEditorProvider(widget.trackId).notifier)
          .setPlayback(PlaybackMode.idle, playing: false);
      _startInitialAnalysis();
      unawaited(_warmUpAudio());
    });
  }

  @override
  void dispose() {
    _keyRepeat.stop();
    unawaited(_seamAudition?.cancel());
    _clearManualHooks();
    _loadVersion++;
    _playbackVersion++;
    _positionSub?.cancel();
    _playingSub?.cancel();
    _completedSub?.cancel();
    _errorSub?.cancel();
    _audioOutputFollower?.dispose();
    final player = _player;
    if (player != null) {
      unawaited(player.pause());
    }
    _clearPreviewPositionHold();
    _pageScrollController.dispose();
    _hotkeysFocus.dispose();
    super.dispose();
  }

  Player get _audioPlayer {
    if (!widget.enableAudio) {
      throw StateError('Audio playback is disabled for this editor instance.');
    }
    final player = _player;
    if (player != null) return player;
    final next = StudioAudioPlayers.editor;
    _audioOutputFollower = followSystemAudioOutput(next);
    return _player = next;
  }

  /// 跟随 modifier 键的按下状态，避免快速按放时读到滞后的硬件状态。
  void _syncModifierHeld(KeyEvent event) {
    if (_manualSession == null) return;
    final altHeld = _modifierHeldForEvent(
      event,
      isModifierKey: _isAltKey,
      isPressed: () => HardwareKeyboard.instance.isAltPressed,
    );
    final shiftHeld = _modifierHeldForEvent(
      event,
      isModifierKey: _isShiftKey,
      isPressed: () => HardwareKeyboard.instance.isShiftPressed,
    );
    final ctrlHeld = _modifierHeldForEvent(
      event,
      isModifierKey: _isControlKey,
      isPressed: () => HardwareKeyboard.instance.isControlPressed,
    );
    final chord = ref.read(editorShortcutsProvider)[EditorAction.freePlace]!;
    final keyboard = HardwareKeyboard.instance;
    final pressed = {...keyboard.logicalKeysPressed};
    if (event is KeyUpEvent) {
      pressed.remove(event.logicalKey);
    }
    if (event is KeyDownEvent) {
      pressed.add(event.logicalKey);
    }
    final freeHeld =
        pressed.contains(chord.key) &&
        chord.ctrl == ctrlHeld &&
        chord.shift == shiftHeld &&
        chord.alt == altHeld &&
        chord.meta == keyboard.isMetaPressed;
    if (freeHeld != _freeHeld ||
        altHeld != _altHeld ||
        shiftHeld != _shiftHeld ||
        ctrlHeld != _ctrlHeld) {
      setState(() {
        _freeHeld = freeHeld;
        _altHeld = altHeld;
        _shiftHeld = shiftHeld;
        _ctrlHeld = ctrlHeld;
      });
    }
  }

  bool _modifierHeldForEvent(
    KeyEvent event, {
    required bool Function(LogicalKeyboardKey key) isModifierKey,
    required bool Function() isPressed,
  }) {
    if (!isModifierKey(event.logicalKey)) {
      return isPressed();
    }
    if (event is KeyUpEvent) {
      return HardwareKeyboard.instance.logicalKeysPressed.any(
        (key) => isModifierKey(key) && key != event.logicalKey,
      );
    }
    return true;
  }

  bool _isAltKey(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.altLeft || key == LogicalKeyboardKey.altRight;

  bool _isShiftKey(LogicalKeyboardKey key) {
    return key == LogicalKeyboardKey.shiftLeft ||
        key == LogicalKeyboardKey.shiftRight;
  }

  bool _isControlKey(LogicalKeyboardKey key) {
    return key == LogicalKeyboardKey.controlLeft ||
        key == LogicalKeyboardKey.controlRight;
  }

  void _returnToList() {
    if (widget.returnToPlaylist && context.canPop()) {
      context.pop();
    } else {
      context.go(widget.returnToPlaylist ? RmRoutes.playlist : RmRoutes.pool);
    }
  }

  // A modifier-only shortcut commits on release. Using a nudge key first
  // consumes that prefix instead, so Alt+Shift+arrow keeps its existing meaning.
  bool _handleModifierShortcut(KeyEvent event) {
    final chord = ref.read(editorShortcutsProvider)[EditorAction.toggleSnap]!;
    if (_manualSession == null || !modifierKey(chord.key)) {
      _pendingSnapToggle = false;
      return false;
    }
    if (event is KeyDownEvent && !modifierKey(event.logicalKey)) {
      _pendingSnapToggle = false;
      return false;
    }
    if (event is KeyUpEvent &&
        _pendingSnapToggle &&
        modifierKey(event.logicalKey)) {
      _pendingSnapToggle = false;
      TimeInputValidation.flush();
      if (TimeInputValidation.invalid.isEmpty) {
        setState(() => _manualSnapToBeat = !_manualSnapToBeat);
      }
      return true;
    }
    final h = HardwareKeyboard.instance;
    if (event is KeyDownEvent &&
        chord.matches(
          event,
          ctrl: h.isControlPressed,
          shift: h.isShiftPressed,
          alt: h.isAltPressed,
          meta: h.isMetaPressed,
        )) {
      _pendingSnapToggle = true;
      return true;
    }
    return false;
  }

  void _onKey(KeyEvent e) {
    if (e is! KeyDownEvent || _blockedRepeatKeys.contains(e.logicalKey)) return;
    final bindings = ref.read(editorShortcutsProvider);
    final manual = _manualSession != null;
    final h = HardwareKeyboard.instance;
    final shift = manual ? _shiftHeld : h.isShiftPressed;
    final ctrl = h.isControlPressed;
    final alt = manual ? _altHeld : h.isAltPressed;
    EditorAction? actionFor() {
      for (final entry in [
        ...bindings.entries.where((e) => loopNudgeActions.contains(e.key)),
        ...bindings.entries.where((e) => !loopNudgeActions.contains(e.key)),
      ]) {
        if (entry.value.matches(
          e,
          ctrl: ctrl,
          shift: shift,
          alt: alt,
          meta: h.isMetaPressed,
        )) {
          return entry.key;
        }
      }
      return null;
    }

    final action = actionFor();
    final moveLoop = action != null && loopNudgeActions.contains(action);
    if (moveLoop && (!manual || !_manualSession!.kind.isLoop)) return;
    if (manual &&
        (action == EditorAction.suggestionPrevious ||
            action == EditorAction.suggestionNext ||
            action == EditorAction.restoreSaved)) {
      TimeInputValidation.flush();
      if (TimeInputValidation.invalid.isNotEmpty) return;
      _keyRepeat.stop();
      _repeatKey = null;
      _hotkeysFocus.requestFocus();
      if (action == EditorAction.restoreSaved) {
        _restoreSavedManual();
      } else {
        _cycleManualSuggestion(
          action == EditorAction.suggestionPrevious ? -1 : 1,
        );
      }
      return;
    }
    if (manual &&
        (action == EditorAction.undo || action == EditorAction.redo)) {
      TimeInputValidation.flush();
      if (action == EditorAction.redo) {
        _redoManualDraft();
      } else {
        _undoManualDraft();
      }
      return;
    }
    if (manual &&
        (action == EditorAction.markPlayback ||
            action == EditorAction.toggleSnap)) {
      TimeInputValidation.flush();
      if (TimeInputValidation.invalid.isNotEmpty) return;
      if (action == EditorAction.markPlayback) {
        _markManualPlayback();
      } else {
        setState(() => _manualSnapToBeat = !_manualSnapToBeat);
      }
      return;
    }
    if (action == EditorAction.save && !manual) {
      TimeInputValidation.flush();
      if (TimeInputValidation.invalid.isNotEmpty) return;
      final n = ref.read(replaceEditorProvider(widget.trackId).notifier);
      final state = ref.read(replaceEditorProvider(widget.trackId));
      if (state.allConfirmed ||
          (state.dirty && (state.bpmManual || state.track.freeRoamOnly))) {
        _saveConfig(context, n, title: state.track.title);
      } else {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('请先确认 TD、PD、TL、PL 后再保存。')));
      }
      return;
    }
    if (e.logicalKey != LogicalKeyboardKey.escape &&
        FocusManager.instance.primaryFocus?.context
                ?.findAncestorStateOfType<EditableTextState>() !=
            null) {
      return;
    }
    final n = ref.read(replaceEditorProvider(widget.trackId).notifier);
    final state = ref.read(replaceEditorProvider(widget.trackId));
    if (e.logicalKey == LogicalKeyboardKey.escape) {
      if (manual) {
        _cancelManualRefine();
      } else {
        _returnToList();
      }
      return;
    }
    if (action == null) return;
    if (action == EditorAction.assign && !manual) {
      unawaited(showQuickAssign(context, state.track));
      return;
    }
    final manualGroup = switch (action) {
      EditorAction.manualTd => GroupKind.td,
      EditorAction.manualPd => GroupKind.pd,
      EditorAction.manualTl => GroupKind.tl,
      EditorAction.manualPl => GroupKind.pl,
      _ => null,
    };
    if (!manual && manualGroup != null) {
      _openManualGroup(manualGroup);
      return;
    }
    if (nudgeActions.contains(action) || moveLoop) {
      final beat = state.ai.bpm > 0 ? 60 / state.ai.bpm : .5;
      final delta = switch (baseNudgeAction(action)) {
        EditorAction.beatBack => -beat,
        EditorAction.beatForward => beat,
        EditorAction.tenBack => -.010,
        EditorAction.tenForward => .010,
        EditorAction.oneBack => -.001,
        _ => .001,
      };
      if (manual) {
        _nudgeManualDraft(delta, moveLoop: moveLoop);
        _startKeyRepeat(e.logicalKey, delta, moveLoop: moveLoop);
      } else {
        unawaited(_seekTo(state, n, state.playhead + delta));
      }
    } else if (action == EditorAction.play) {
      unawaited(
        _togglePlayback(
          manual ? _manualPreviewState(state, _manualSession!) : state,
          n,
        ),
      );
    } else if (action == EditorAction.confirm) {
      if (manual) {
        _confirmManualRefine(n);
      } else {
        n.confirmActive();
        _scheduleSavePromptIfNeeded(
          ref.read(replaceEditorProvider(widget.trackId)),
        );
      }
    } else if (action == EditorAction.undo) {
      n.undo();
    } else if (action == EditorAction.redo) {
      n.redo();
    } else if (!manual &&
        (action == EditorAction.previous || action == EditorAction.next)) {
      unawaited(
        openAdjacentEditorSong(
          context,
          trackId: widget.trackId,
          step: action == EditorAction.previous ? -1 : 1,
          returnToPlaylist: widget.returnToPlaylist,
        ),
      );
    }
  }

  // A held arrow belongs to the modifier combination that started it.
  // Changing that combination blocks it until the arrow is physically released.
  void _handleHeldKeyTransition(KeyEvent event) {
    final key = event.logicalKey;
    if (event is KeyUpEvent) _blockedRepeatKeys.remove(key);
    final combination = ref
        .read(editorShortcutsProvider)[EditorAction.loopBeatBack]
        ?.extraKey;
    final modifier = modifierKey(key) || key == combination;
    if (_repeatKey != null &&
        (key == _repeatKey && event is KeyUpEvent ||
            modifier && (event is KeyUpEvent || event is KeyDownEvent))) {
      if (modifier) _blockedRepeatKeys.add(_repeatKey!);
      _keyRepeat.stop();
      _repeatKey = null;
    }
  }

  void _startKeyRepeat(
    LogicalKeyboardKey key,
    double step, {
    bool moveLoop = false,
  }) {
    _repeatKey = key;
    _keyRepeat.start(() {
      if (!mounted ||
          _manualSession == null ||
          TimeInputValidation.focused.isNotEmpty) {
        _keyRepeat.stop();
        return;
      }
      _nudgeManualDraft(step, moveLoop: moveLoop);
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AuditionPreferences>(auditionPreferencesProvider, (_, next) {
      if (widget.enableAudio &&
          _player != null &&
          Platform.environment['FH_RADIO_STUDIO_PREVIEW_DIAGNOSTICS'] != '1') {
        unawaited(_player!.setVolume(next.volume));
      }
    });

    final s = ref.watch(replaceEditorProvider(widget.trackId));
    final n = ref.read(replaceEditorProvider(widget.trackId).notifier);
    final cli = ref.watch(studioProvider);
    final analysis = _activeAnalysisFor(s, ref.watch(audioAnalysisProvider));
    ref.listen<ReplaceEditorState>(replaceEditorProvider(widget.trackId), (
      previous,
      next,
    ) {
      final wasAllConfirmed =
          previous?.allConfirmed ?? _lastObservedAllConfirmed;
      _lastObservedAllConfirmed = next.allConfirmed;
      if (wasAllConfirmed || !next.allConfirmed) {
        return;
      }
      _scheduleSavePromptIfNeeded(next);
    });
    _lastObservedAllConfirmed = s.allConfirmed;

    return Focus(
      focusNode: _hotkeysFocus,
      autofocus: true,
      onFocusChange: (focused) {
        if (!focused) {
          _keyRepeat.stop();
          _pendingSnapToggle = false;
          if (_freeHeld) setState(() => _freeHeld = false);
        }
      },
      onKeyEvent: (_, e) {
        _handleHeldKeyTransition(e);
        _syncModifierHeld(e);
        if (_handleModifierShortcut(e)) return KeyEventResult.handled;
        if (_manualSession != null &&
            _freeHeld &&
            e.logicalKey ==
                ref
                    .read(editorShortcutsProvider)[EditorAction.freePlace]!
                    .key) {
          return KeyEventResult.handled;
        }

        if (TimeInputValidation.focused.isNotEmpty) {
          final h = HardwareKeyboard.instance;
          final keys = ref.read(editorShortcutsProvider);
          final manualAction =
              [
                EditorAction.undo,
                EditorAction.redo,
                EditorAction.suggestionPrevious,
                EditorAction.suggestionNext,
                EditorAction.restoreSaved,
                EditorAction.markPlayback,
                EditorAction.toggleSnap,
              ].any(
                (action) => keys[action]!.matches(
                  e,
                  ctrl: h.isControlPressed,
                  shift: h.isShiftPressed,
                  alt: h.isAltPressed,
                  meta: h.isMetaPressed,
                ),
              );
          final saveAction =
              _manualSession == null &&
              keys[EditorAction.save]!.matches(
                e,
                ctrl: h.isControlPressed,
                shift: h.isShiftPressed,
                alt: h.isAltPressed,
                meta: h.isMetaPressed,
              );
          if (((_manualSession != null && manualAction) || saveAction) &&
              e is KeyDownEvent) {
            _syncModifierHeld(e);
            _onKey(e);
            return KeyEventResult.handled;
          }
          if (e.logicalKey != LogicalKeyboardKey.escape) {
            return KeyEventResult.ignored;
          }
          TimeInputValidation.flush();
        }
        _syncModifierHeld(e);
        _onKey(e);
        return KeyEventResult.handled;
      },
      child: LayoutBuilder(
        builder: (context, viewport) {
          final metrics = _layoutMetrics(viewport.maxWidth);
          final pinSidebar = _canPinSidebar(metrics);
          return Stack(
            key: _editorViewportKey,
            children: [
              _scrollingEditorContent(
                context,
                s,
                n,
                analysis,
                cli: cli,
                metrics: metrics,
                reserveSidebar: pinSidebar,
                viewportHeight: viewport.maxHeight,
              ),
              _TransportFloatingOverlay(
                scrollController: _pageScrollController,
                metrics: _transportDockMetrics,
                pinGap: _EditorLayoutMetrics.verticalGap,
                child: _transportBar(s, n, floating: true),
              ),
              if (!pinSidebar)
                _collapsedSidePanel(
                  context,
                  s,
                  n,
                  analysis,
                  viewport: viewport,
                ),
              Positioned.fill(
                child: _manualRefineOverlay(context, s, n, viewport: viewport),
              ),
            ],
          );
        },
      ),
    ).withFeatureTour(
      TourPage.song,
      enabled: !s.analyzing && !cli.busy && _manualSession == null,
      onReveal: (target) {
        final open = target == 'side';
        if (_sideDrawerOpen != open) setState(() => _sideDrawerOpen = open);
      },
      onComplete: () {
        setState(() => _sideDrawerOpen = false);
        if (DemoSong.matches(cli.projectDir, s.track.source) &&
            !ref.read(featureToursProvider).seen(TourPage.refine)) {
          _openManualGroup(GroupKind.tl);
        }
      },
    );
  }

  AudioAnalysisState? _activeAnalysisFor(
    ReplaceEditorState s,
    AudioAnalysisState analysis,
  ) {
    final path = s.track.source.trim();
    if (path.isEmpty || analysis.path != path) return null;
    return analysis;
  }

  _EditorLayoutMetrics _layoutMetrics(double maxWidth) {
    final pageWidth = math.min(
      maxWidth,
      ref.watch(layoutOptionsProvider).pageWidth(RmTokens.pageWide),
    );
    final horizontalPadding = maxWidth < 900 ? 24.0 : 40.0;
    final innerWidth = math.max(0.0, pageWidth - horizontalPadding * 2);
    final sideWidth = innerWidth >= 1180 ? 340.0 : 312.0;
    return _EditorLayoutMetrics(
      pageWidth: pageWidth,
      horizontalPadding: horizontalPadding,
      innerWidth: innerWidth,
      sideWidth: sideWidth,
    );
  }

  bool _canPinSidebar(_EditorLayoutMetrics metrics) {
    const minMainWidth = 620.0;
    return metrics.innerWidth >=
        minMainWidth + _EditorLayoutMetrics.sideGap + metrics.sideWidth;
  }

  Widget _scrollingEditorContent(
    BuildContext context,
    ReplaceEditorState s,
    ReplaceEditorNotifier n,
    AudioAnalysisState? analysis, {
    required StudioState cli,
    required _EditorLayoutMetrics metrics,
    required bool reserveSidebar,
    required double viewportHeight,
  }) {
    final mainColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, c) {
            final breadcrumb = EditorBreadcrumb(
              trackTitle: s.track.title,
              onBack: _returnToList,
              backLabel: widget.returnToPlaylist
                  ? '播放列表 · Esc 返回'
                  : '自建歌曲 · Esc 返回',
              assignedTo: s.track.assignedTo,
              slot: s.track.slot,
            );
            final navigation = EditorSongNavigation(
              trackId: widget.trackId,
              returnToPlaylist: widget.returnToPlaylist,
            );
            if (c.maxWidth < 620) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  breadcrumb,
                  Align(alignment: Alignment.centerRight, child: navigation),
                  const SizedBox(height: 12),
                ],
              );
            }
            return Row(
              children: [
                Expanded(child: breadcrumb),
                const SizedBox(width: 12),
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: navigation,
                ),
              ],
            );
          },
        ).tourAnchor('save-start'),
        KeyedSubtree(
          key: const ValueKey('editor-header'),
          child: _pageHead(
            context,
            s,
            n,
            showSidePanelButton: !reserveSidebar,
          ).tourAnchor('save'),
        ),
        const SizedBox(height: 8),
        if (s.track.freeRoamOnly)
          const RmBanner(
            kind: RmBannerKind.info,
            title: '仅用于漫游，无需确认比赛时间点。',
            body: '构建时自动补全有效默认点位，也可按需手动编辑。加入比赛清单后，需要完成四组配置。',
          ),
        if (s.analyzing || s.error != null || s.saved || s.dirty) ...[
          const SizedBox(height: 8),
          KeyedSubtree(
            key: const ValueKey('editor-status-banner'),
            child: _statusBanner(context, s, analysis),
          ),
        ],
        const SizedBox(height: 14),
        ProgressStrip(
          state: s,
          onSelect: n.setActiveGroup,
          onManualRefine: _openManualGroup,
          onQuickConfirm: _quickConfirmGroup,
          onPreview: (kind) => unawaited(
            _previewCandidate(s, n, kind, switch (kind) {
              GroupKind.td => s.td,
              GroupKind.tl => s.tl,
              GroupKind.pd => s.pd,
              GroupKind.pl => s.pl,
            }),
          ),
        ).tourAnchor('groups'),
        const SizedBox(height: _EditorLayoutMetrics.verticalGap),
        _editorBody(
          context,
          s,
          n,
          analysis,
          reserveSidebar: reserveSidebar,
          sideWidth: metrics.sideWidth,
          viewportHeight: viewportHeight,
        ),
      ],
    );

    return SingleChildScrollView(
      controller: _pageScrollController,
      child: Center(
        child: SizedBox(
          width: metrics.pageWidth,
          key: _scrollContentKey,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              metrics.horizontalPadding,
              36,
              metrics.horizontalPadding,
              96,
            ),
            child: mainColumn,
          ),
        ),
      ),
    );
  }

  Widget _pageHead(
    BuildContext context,
    ReplaceEditorState s,
    ReplaceEditorNotifier n, {
    required bool showSidePanelButton,
  }) {
    final rm = context.rm;
    final t = s.track;
    final title = Column(
      key: const ValueKey('editor-heading'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          t.title,
          key: const ValueKey('editor-title'),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: RmText.pageH1(color: rm.fg),
        ),
        if (t.artist.trim().isNotEmpty) ...[
          const SizedBox(height: 4),
          Tooltip(
            message: t.artist,
            child: Text(
              t.artist,
              key: const ValueKey('editor-artist'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: RmText.body(color: rm.fg3),
            ),
          ),
        ],
      ],
    );
    final actions = Wrap(
      alignment: WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 8,
      children: [
        BpmEditButton(
          bpm: s.ai.bpm,
          manual: s.bpmManual,
          enabled:
              !s.analyzing &&
              !ref.watch(studioProvider).busy &&
              !ref.watch(studioProvider).customSongEditingLocked,
          onApply: n.setBpm,
        ),
        SongMetadataButton(
          title: t.title,
          artist: t.artist,
          enabled:
              t.id.startsWith('real:') &&
              !ref.watch(studioProvider).busy &&
              !ref.watch(studioProvider).customSongEditingLocked,
          onSave: (title, artist) => ref
              .read(studioProvider.notifier)
              .editTrackMetadata(t.source, title, artist),
        ),
        RmChip(
          key: const ValueKey('editor-assignment-status'),
          label: t.assignedTo == null
              ? '未分配'
              : '分配至 ${t.assignedTo} · slot ${t.slot}',
          variant: RmChipVariant.muted,
          showDot: true,
        ),
        if (showSidePanelButton)
          _SideRailButton(
            open: _sideDrawerOpen,
            onTap: () => setState(() => _sideDrawerOpen = true),
          ),
        RmButton(
          key: const ValueKey('editor-quick-assign'),
          label: '分配电台',
          tooltip:
              '分配电台 · ${ref.watch(editorShortcutsProvider)[EditorAction.assign]!.label}',
          onPressed: () => showQuickAssign(context, s.track),
        ),
        RmButton(
          key: const ValueKey('editor-save'),
          onPressed:
              s.allConfirmed ||
                  (s.dirty && (s.bpmManual || s.track.freeRoamOnly))
              ? () => _saveConfig(context, n, title: s.track.title)
              : null,
          variant: RmButtonVariant.primary,
          leading: const RmIcon('check', size: 12),
          label: '保存',
          tooltip:
              '保存 · ${ref.watch(editorShortcutsProvider)[EditorAction.save]!.label}',
        ),
      ],
    );
    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth < 480) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [title, const SizedBox(height: 10), actions],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(child: title),
            const SizedBox(width: 16),
            SizedBox(width: math.min(560.0, c.maxWidth * .54), child: actions),
          ],
        );
      },
    );
  }

  Widget _statusBanner(
    BuildContext context,
    ReplaceEditorState s,
    AudioAnalysisState? analysis,
  ) {
    if (s.error != null) {
      return RmBanner(
        kind: RmBannerKind.danger,
        title: '音频分析失败。',
        body: s.error!,
      );
    }
    if (s.analyzing) {
      final active = analysis?.activeProgressStep;
      return RmBanner(
        kind: RmBannerKind.info,
        title: '正在分析真实音频。',
        body: active == null
            ? '完成后会刷新波形、时长、BPM 和 6 个候选时间点。'
            : '当前：${active.label} · ${analysis!.progressPercent}%。完成后会刷新候选时间点。',
      );
    }
    if (s.dirty) {
      return const RmBanner(
        kind: RmBannerKind.warn,
        title: '有未保存的时间点修改。',
        body: '保存后 Dashboard 构建包会使用这些时间点。',
      );
    }
    return const RmBanner(
      kind: RmBannerKind.info,
      title: '此曲配置已保存。',
      body: '构建电台包时会通过 timing manifest 注入这些 marker。',
    );
  }

  Widget _collapsedSidePanel(
    BuildContext context,
    ReplaceEditorState s,
    ReplaceEditorNotifier n,
    AudioAnalysisState? analysis, {
    required BoxConstraints viewport,
  }) {
    final drawerWidth = math.min(
      360.0,
      math.max(280.0, viewport.maxWidth - 32),
    );

    return Stack(
      children: [
        if (_sideDrawerOpen)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _sideDrawerOpen = false),
              child: const SizedBox.expand(),
            ),
          ),
        if (_sideDrawerOpen)
          Positioned(
            top: 24,
            right: 16,
            bottom: 24,
            width: drawerWidth,
            child: _FloatingSideDrawer(
              state: s,
              analysis: analysis,
              onClose: () => setState(() => _sideDrawerOpen = false),
              onAnalyze: () => unawaited(n.analyze(force: true)),
            ),
          ),
      ],
    );
  }

  String _manualShortcutHint() {
    final keys = ref.watch(editorShortcutsProvider);
    return '${keys[EditorAction.beatBack]!.label}/${keys[EditorAction.beatForward]!.label} 1拍 · '
        '${keys[EditorAction.tenForward]!.label} 10ms · ${keys[EditorAction.oneForward]!.label} 1ms · '
        '${loopCombinationLabel(keys)} 两端同时移动（配合原微调键） · ${keys[EditorAction.freePlace]!.label} 按住自由放置 · '
        '${keys[EditorAction.toggleSnap]!.label} 切换磁吸/自由放置 · '
        '${keys[EditorAction.markPlayback]!.label} 取当前播放位置 · '
        '${keys[EditorAction.suggestionPrevious]!.label}/${keys[EditorAction.suggestionNext]!.label} 切换建议 · '
        '${keys[EditorAction.restoreSaved]!.label} 已保存配置 · ${keys[EditorAction.undo]!.label} 撤销 · ${keys[EditorAction.redo]!.label} 重做 · Esc 返回';
  }

  Widget _manualRefineOverlay(
    BuildContext context,
    ReplaceEditorState s,
    ReplaceEditorNotifier n, {
    required BoxConstraints viewport,
  }) {
    final session = _manualSession;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) {
        final scale = Tween<double>(begin: 0.982, end: 1).animate(animation);
        return FadeTransition(
          opacity: animation,
          child: ScaleTransition(scale: scale, child: child),
        );
      },
      child: session == null
          ? const SizedBox.shrink(key: ValueKey('manual-refine-empty'))
          : _ManualRefineOverlay(
              key: ValueKey('manual-refine-${session.kind.code}'),
              state: _manualPreviewState(s, session),
              session: session,
              viewport: viewport,
              preferredWidth: ref
                  .watch(layoutOptionsProvider)
                  .manualRefineWidth,
              aiCandidates: _manualSuggestions(s, session.kind),
              seamless:
                  ref.read(editorOptionsProvider).slmEnabled &&
                  session.kind.isLoop,
              snapActive: _manualSnapToBeat && !_freeHeld,
              onToggleSnap: () =>
                  setState(() => _manualSnapToBeat = !_manualSnapToBeat),
              onMarkPlayback: _markManualPlayback,
              onPlace: (seconds, {required isMove}) =>
                  _placeManualDraft(seconds, isMove: isMove),
              onSeek: (seconds) => unawaited(_seekTo(s, n, seconds)),
              onApplyCandidate: _applyAiCandidateToManual,
              onPickTarget: _setManualFineTarget,
              onNudge: _nudgeManualDraftTarget,
              onAudition: () => _previewManualAudition(n),
              onCancel: _cancelManualRefine,
              onTourComplete: () {
                if (DemoSong.matches(
                  ref.read(studioProvider).projectDir,
                  s.track.source,
                )) {
                  _cancelManualRefine();
                  context.go(RmRoutes.pool);
                }
              },
              onUndo: _manualUndo.isEmpty ? null : _undoManualDraft,
              onRedo: _manualRedo.isEmpty ? null : _redoManualDraft,
              shortcutHint: _manualShortcutHint(),
              onConfirm: () => _confirmManualRefine(n),
              onTogglePlay: () => unawaited(
                _togglePlayback(
                  _manualPreviewState(
                    ref.read(replaceEditorProvider(widget.trackId)),
                    _manualSession!,
                  ),
                  n,
                ),
              ),
              onRewind: () => unawaited(_seekTo(s, n, 0)),
              onSkipFwd: () => unawaited(_seekTo(s, n, s.ai.durationSec)),
            ),
    );
  }

  ReplaceEditorState _manualPreviewState(
    ReplaceEditorState state,
    _ManualRefineSession session,
  ) {
    final playback = _manualPlayback;
    final playhead = (playback?.playhead ?? session.focusTime)
        .clamp(0, state.ai.durationSec)
        .toDouble();
    state = state.copyWith(
      playhead: playhead,
      playing: playback?.playing ?? false,
      playbackMode: playback?.mode ?? PlaybackMode.idle,
    );
    if (session.kind.isLoop) {
      final candidate = LoopCandidate(
        start: session.start,
        end: session.end,
        score: 1,
        bars: _barsForManual(session.start, session.end, state.ai.bpm),
        why: '人工选点',
      );
      return switch (session.kind) {
        GroupKind.tl => state.copyWith(
          tlManual: candidate,
          tlIdx: state.ai.tl.length,
          tlConfirmed: false,
          activeGroup: session.kind,
          playhead: playhead,
        ),
        GroupKind.pl => state.copyWith(
          plManual: candidate,
          plIdx: state.ai.pl.length,
          plConfirmed: false,
          activeGroup: session.kind,
          playhead: playhead,
        ),
        GroupKind.td || GroupKind.pd => state,
      };
    }
    final candidate = PointCandidate(
      t: session.pointTime,
      score: 1,
      why: '人工选点',
    );
    return switch (session.kind) {
      GroupKind.td => state.copyWith(
        tdManual: candidate,
        tdIdx: state.ai.td.length,
        tdConfirmed: false,
        activeGroup: session.kind,
        playhead: playhead,
      ),
      GroupKind.pd => state.copyWith(
        pdManual: candidate,
        pdIdx: state.ai.pd.length,
        pdConfirmed: false,
        activeGroup: session.kind,
        playhead: playhead,
      ),
      GroupKind.tl || GroupKind.pl => state,
    };
  }

  List<dynamic> _aiCandidatesFor(ReplaceEditorState state, GroupKind kind) {
    return switch (kind) {
      GroupKind.td => state.ai.td,
      GroupKind.pd => state.ai.pd,
      GroupKind.tl => state.ai.tl,
      GroupKind.pl => state.ai.pl,
    };
  }

  List<dynamic> _manualSuggestions(ReplaceEditorState state, GroupKind kind) {
    final options = ref.read(editorOptionsProvider);
    if (options.manualOnly && !(options.slmEnabled && kind.isLoop)) {
      return const [];
    }
    return _aiCandidatesFor(state, kind);
  }

  void _cycleManualSuggestion(int step) {
    final session = _manualSession;
    if (session == null) return;
    final state = ref.read(replaceEditorProvider(widget.trackId));
    final candidates = _manualSuggestions(state, session.kind);
    if (candidates.isEmpty) return;
    final matched = candidates.indexWhere(session.matches);
    final index = matched >= 0 ? matched : _manualSuggestionCursor;
    final next = index < 0
        ? (step < 0 ? candidates.length - 1 : 0)
        : (index + step) % candidates.length;
    _applyAiCandidateToManual(candidates[next]);
  }

  void _restoreSavedManual() {
    final session = _manualSession;
    if (session == null) return;
    final state = ref.read(replaceEditorProvider(widget.trackId));
    final config = ref
        .read(trackTimingProvider.notifier)
        .configForPath(state.track.source);
    final markers = config?.markersSec ?? const <String, double>{};
    final keys = switch (session.kind) {
      GroupKind.td => ['TrackDrop'],
      GroupKind.pd => ['PostDrop'],
      GroupKind.tl => ['TrackLoopStart', 'TrackLoopEnd'],
      GroupKind.pl => ['PostRaceLoopStart', 'PostRaceLoopEnd'],
    };
    final times = keys.map((k) => markers[k]).toList();
    if (times.any(
          (t) => t == null || !t.isFinite || t < 0 || t > state.ai.durationSec,
        ) ||
        session.kind.isLoop && times[1]! <= times[0]!) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('当前时间组没有可用的已保存配置。')));
      return;
    }
    _applyAiCandidateToManual(
      session.kind.isLoop
          ? LoopCandidate(
              start: times[0]!,
              end: times[1]!,
              score: 1,
              bars: _barsForManual(times[0]!, times[1]!, state.ai.bpm),
              why: '已保存配置',
            )
          : PointCandidate(t: times[0]!, score: 1, why: '已保存配置'),
      audition: false,
    );
  }

  void _quickConfirmGroup(GroupKind kind) {
    TimeInputValidation.flush();
    if (_manualSession != null || TimeInputValidation.invalid.isNotEmpty) {
      return;
    }
    final notifier = ref.read(replaceEditorProvider(widget.trackId).notifier);
    if (ref.read(replaceEditorProvider(widget.trackId)).confirmedOf(kind)) {
      return;
    }
    notifier.setConfirmed(kind, true);
    _scheduleSavePromptIfNeeded(
      ref.read(replaceEditorProvider(widget.trackId)),
    );
  }

  void _openManualGroup(GroupKind kind) {
    TimeInputValidation.flush();
    if (_manualSession != null || TimeInputValidation.invalid.isNotEmpty) {
      return;
    }
    final notifier = ref.read(replaceEditorProvider(widget.trackId).notifier);

    notifier.setActiveGroup(kind);
    _openManualRefine(
      ref.read(replaceEditorProvider(widget.trackId)),
      notifier,
      kind,
    );
  }

  void _markManualPlayback() {
    TimeInputValidation.flush();
    final session = _manualSession;
    final playback = _manualPlayback;
    if (session == null ||
        playback == null ||
        TimeInputValidation.invalid.isNotEmpty) {
      return;
    }
    final duration = ref
        .read(replaceEditorProvider(widget.trackId))
        .ai
        .durationSec;
    _updateManualDraft(session.placeAt(playback.playhead, duration: duration));
    _hotkeysFocus.requestFocus();
  }

  void _openManualRefine(
    ReplaceEditorState state,
    ReplaceEditorNotifier notifier,
    GroupKind kind,
  ) {
    _hotkeysFocus.requestFocus();
    _clearLocalPlaybackState();
    if (_player != null) unawaited(_player!.pause());
    notifier.setPlayback(PlaybackMode.idle, playing: false);
    _playbackInManual = true;
    final session = _ManualRefineSession.fromState(state, kind);
    _manualNotifier = notifier;
    notifier.pendingManualDirty = () => mounted && _manualDraftChanged;
    notifier.commitManualDraft = () => _commitManualDraftBeforeSave(notifier);
    notifier.discardManualDraft = _cancelManualRefine;
    setState(() {
      _manualDraftChanged = false;
      _manualInitial = session;
      _manualSuggestionCursor = -1;
      _manualUndo.clear();
      _manualRedo.clear();
      _manualSession = session;
      _manualSnapToBeat = true;
      _manualPlayback = (
        playhead: session.focusTime,
        playing: false,
        mode: PlaybackMode.idle,
      );
      _freeHeld = false;
      _altHeld = HardwareKeyboard.instance.isAltPressed;
      _shiftHeld = HardwareKeyboard.instance.isShiftPressed;
      _ctrlHeld = HardwareKeyboard.instance.isControlPressed;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _manualSession != session) return;
      unawaited(
        _seekTo(
          ref.read(replaceEditorProvider(widget.trackId)),
          notifier,
          session.focusTime,
        ),
      );
    });
  }

  bool _sameManual(_ManualRefineSession a, _ManualRefineSession b) =>
      a.kind == b.kind &&
      (a.kind.isLoop
          ? a.start == b.start && a.end == b.end
          : a.pointTime == b.pointTime);
  void _updateManualDraft(
    _ManualRefineSession updated, {
    bool coalesce = false,
  }) {
    final current = _manualSession;
    if (current == null || _sameManual(current, updated)) return;
    if (!coalesce || _manualUndo.isEmpty) {
      _manualUndo.add(current);
      if (_manualUndo.length > 200) _manualUndo.removeAt(0);
    }
    _manualRedo.clear();
    setState(() {
      _manualSession = updated;
      _manualDraftChanged =
          _manualInitial == null || !_sameManual(updated, _manualInitial!);
    });
  }

  void _undoManualDraft() => _restoreManualHistory(false);
  void _redoManualDraft() => _restoreManualHistory(true);
  void _restoreManualHistory(bool redo) {
    _keyRepeat.stop();
    _repeatKey = null;
    final from = redo ? _manualRedo : _manualUndo,
        to = redo ? _manualUndo : _manualRedo;
    if (_manualSession == null || from.isEmpty) return;
    to.add(_manualSession!);
    final restored = from.removeLast();
    _hotkeysFocus.requestFocus();
    setState(() {
      _manualSession = restored;
      _manualDraftChanged =
          _manualInitial == null || !_sameManual(restored, _manualInitial!);
    });
    final state = ref.read(replaceEditorProvider(widget.trackId));
    unawaited(
      _seekTo(
        state,
        ref.read(replaceEditorProvider(widget.trackId).notifier),
        restored.focusTime,
      ),
    );
  }

  void _cancelManualRefine() {
    _keyRepeat.stop();
    if (_manualSession == null) return;
    final notifier = ref.read(replaceEditorProvider(widget.trackId).notifier);
    _pauseManualRefinePlayback(notifier);
    setState(() {
      _manualSession = null;
      _manualDraftChanged = false;
    });
  }

  void _clearManualHooks() {
    final notifier = _manualNotifier;
    if (notifier != null) {
      notifier.pendingManualDirty = null;
      notifier.commitManualDraft = null;
      notifier.discardManualDraft = null;
    }
    _manualNotifier = null;
  }

  void _commitManualDraftBeforeSave(ReplaceEditorNotifier notifier) {
    final session = _manualSession;
    if (!mounted || session == null || !_manualDraftChanged) return;
    final wasOpen = _savePromptOpen;
    _savePromptOpen = true;
    try {
      if (session.kind.isLoop) {
        notifier.applyManualLoop(session.kind, session.start, session.end);
      } else {
        notifier.applyManualPoint(session.kind, session.pointTime);
      }
      _pauseManualRefinePlayback(notifier);
      setState(() {
        _manualSession = null;
        _manualDraftChanged = false;
      });
    } finally {
      _savePromptOpen = wasOpen;
    }
  }

  void _pauseManualRefinePlayback(ReplaceEditorNotifier notifier) {
    final player = _player;
    if (player?.state.playing == true) {
      _pausedByUser = true;
      unawaited(player!.pause());
    }
    _setPlayback(notifier, PlaybackMode.idle, playing: false);
    _clearLocalPlaybackState();
  }

  void _previewManualAudition(ReplaceEditorNotifier notifier) {
    TimeInputValidation.flush();
    final session = _manualSession;
    if (session == null) return;
    final state = _manualPreviewState(
      ref.read(replaceEditorProvider(widget.trackId)),
      session,
    );
    if (session.kind.isLoop) {
      if (widget.enableAudio) {
        unawaited(
          _playLoopPreview(state, notifier, session.start, session.end),
        );
      } else {
        final auditionStart = loopPreviewAuditionStartForTesting(
          startSec: session.start,
          endSec: session.end,
        );
        _setPlayhead(notifier, auditionStart);
        _setPlayback(notifier, PlaybackMode.loopPreview, playing: true);
      }
    } else {
      if (widget.enableAudio) {
        unawaited(
          _playPointPreview(state, notifier, session.pointTime, session.kind),
        );
      } else {
        final window = pointPreviewWindowForTesting(
          timeSec: session.pointTime,
          previewDuration: _pointDuration(session.kind),
          durationSec: _previewDuration(
            state,
            session.pointTime + _pointDuration(session.kind),
          ),
        );
        _setPlayhead(notifier, window.start);
        _setPlayback(notifier, PlaybackMode.pointPreview, playing: true);
      }
    }
  }

  void _confirmManualRefine(ReplaceEditorNotifier notifier) {
    _keyRepeat.stop();
    TimeInputValidation.flush();
    if (TimeInputValidation.invalid.isNotEmpty) return;
    final session = _manualSession;
    if (session == null) return;
    if (!_manualDraftChanged &&
        ref
            .read(replaceEditorProvider(widget.trackId))
            .confirmedOf(session.kind)) {
      _cancelManualRefine();
      return;
    }
    if (session.kind.isLoop) {
      notifier.applyManualLoop(session.kind, session.start, session.end);
    } else {
      notifier.applyManualPoint(session.kind, session.pointTime);
    }
    _pauseManualRefinePlayback(notifier);
    setState(() {
      _manualSession = null;
      _manualDraftChanged = false;
    });
    _scheduleSavePromptIfNeeded(
      ref.read(replaceEditorProvider(widget.trackId)),
    );
  }

  void _placeManualDraft(
    double seconds, {
    bool snap = true,
    bool isMove = false,
  }) {
    final session = _manualSession;
    if (session == null) return;
    final state = ref.read(replaceEditorProvider(widget.trackId));
    // 默认磁吸到最近的拍；按住自由放置键时放弃磁吸，自由放置。
    final bypassSnap = _freeHeld || !_manualSnapToBeat;
    final target = (snap && !bypassSnap)
        ? _snapToBeat(seconds, state.ai.beats)
        : seconds;
    final next = target.clamp(0, state.ai.durationSec).toDouble();
    // 循环组按下时挑离指针更近的端点（A / B），拖动时沿用当前端点。
    var working = session;
    if (session.kind.isLoop && !isMove) {
      final nearEnd =
          (seconds - session.end).abs() < (seconds - session.start).abs();
      working = session.copyWith(
        activeTarget: nearEnd ? FineTarget.loopEnd : FineTarget.loopStart,
      );
    }
    final updated = working.placeAt(next, duration: state.ai.durationSec);
    _updateManualDraft(updated, coalesce: isMove);
    unawaited(
      _seekTo(
        state,
        ref.read(replaceEditorProvider(widget.trackId).notifier),
        updated.focusTime,
      ),
    );
  }

  /// 返回离 [seconds] 最近的拍点；没有拍点数据时原样返回。
  static double _snapToBeat(double seconds, List<double> beats) {
    if (beats.isEmpty) return seconds;
    var best = beats.first;
    var bestDist = (best - seconds).abs();
    for (final beat in beats) {
      final dist = (beat - seconds).abs();
      if (dist < bestDist) {
        best = beat;
        bestDist = dist;
      }
    }
    return best;
  }

  void _applyAiCandidateToManual(dynamic candidate, {bool audition = true}) {
    final session = _manualSession;
    if (session == null) return;
    final state = ref.read(replaceEditorProvider(widget.trackId));
    final notifier = ref.read(replaceEditorProvider(widget.trackId).notifier);
    final updated = session.fromCandidate(
      candidate,
      duration: state.ai.durationSec,
    );
    _manualSuggestionCursor = _manualSuggestions(
      state,
      session.kind,
    ).indexWhere(updated.matches);
    _updateManualDraft(updated, coalesce: _repeatKey != null);
    if (!audition) {
      _pauseManualRefinePlayback(notifier);
      unawaited(_seekTo(state, notifier, updated.focusTime));
      return;
    }
    if (updated.kind.isLoop) {
      if (widget.enableAudio) {
        unawaited(
          _playLoopPreview(state, notifier, updated.start, updated.end),
        );
      } else {
        final auditionStart = loopPreviewAuditionStartForTesting(
          startSec: updated.start,
          endSec: updated.end,
        );
        _setPlayhead(notifier, auditionStart);
        _setPlayback(notifier, PlaybackMode.loopPreview, playing: true);
      }
      return;
    }
    if (widget.enableAudio) {
      unawaited(
        _playPointPreview(state, notifier, updated.pointTime, updated.kind),
      );
    } else {
      final window = pointPreviewWindowForTesting(
        timeSec: updated.pointTime,
        previewDuration: _pointDuration(updated.kind),
        durationSec: _previewDuration(
          state,
          updated.pointTime + _pointDuration(updated.kind),
        ),
      );
      _setPlayhead(notifier, window.start);
      _setPlayback(notifier, PlaybackMode.pointPreview, playing: true);
    }
  }

  void _setManualFineTarget(FineTarget target) {
    final session = _manualSession;
    if (session == null) return;
    setState(() => _manualSession = session.copyWith(activeTarget: target));
  }

  void _nudgeManualDraft(double deltaSec, {bool moveLoop = false}) {
    final session = _manualSession;
    if (session == null) return;
    if (moveLoop && session.kind.isLoop) {
      final state = ref.read(replaceEditorProvider(widget.trackId));
      // Clamp a single shared delta, preserving the exact loop duration at boundaries.
      final delta = deltaSec.clamp(
        -session.start,
        math.max(0.0, state.ai.durationSec - session.end),
      );
      final updated = session.copyWith(
        start: session.start + delta,
        end: session.end + delta,
      );
      _updateManualDraft(updated, coalesce: _repeatKey != null);
      unawaited(
        _seekTo(
          state,
          ref.read(replaceEditorProvider(widget.trackId).notifier),
          updated.focusTime,
        ),
      );
      return;
    }
    _nudgeManualDraftTarget(session.activeTarget, deltaSec);
  }

  void _nudgeManualDraftTarget(FineTarget target, double deltaSec) {
    final session = _manualSession;
    if (session == null) return;
    final state = ref.read(replaceEditorProvider(widget.trackId));
    final updated = session.nudge(
      target,
      deltaSec,
      duration: state.ai.durationSec,
    );
    _updateManualDraft(updated, coalesce: _repeatKey != null);
    unawaited(
      _seekTo(
        state,
        ref.read(replaceEditorProvider(widget.trackId).notifier),
        updated.focusTime,
      ),
    );
  }

  Widget _editorBody(
    BuildContext context,
    ReplaceEditorState s,
    ReplaceEditorNotifier n,
    AudioAnalysisState? analysis, {
    required bool reserveSidebar,
    required double sideWidth,
    required double viewportHeight,
  }) {
    final main = _editorMain(context, s, n);
    if (!reserveSidebar) return main;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: main),
            const SizedBox(width: _EditorLayoutMetrics.sideGap),
            _StickySidePanel(
              width: sideWidth,
              contentKey: _scrollContentKey,
              pinGap: _EditorLayoutMetrics.verticalGap,
              bottomGap: 24,
              viewportHeight: viewportHeight,
              scrollController: _pageScrollController,
              onExtraExtentChanged: _setSidePanelExtraScroll,
              child: EditorSidePanel(
                manualOnly: ProviderScope.containerOf(
                  context,
                ).read(editorOptionsProvider).manualOnly,
                seamless: ProviderScope.containerOf(
                  context,
                ).read(editorOptionsProvider).slmEnabled,
                state: s,
                analysis: analysis,
                onAnalyze: () => unawaited(n.analyze(force: true)),
              ).tourAnchor('side'),
            ),
          ],
        ),
        if (_sidePanelExtraScroll > 0) SizedBox(height: _sidePanelExtraScroll),
      ],
    );
  }

  void _setSidePanelExtraScroll(double value) {
    final oldValue = _sidePanelExtraScroll;
    if ((oldValue - value).abs() < 0.5) return;
    final controller = _pageScrollController;
    final shouldKeepReleasePosition =
        oldValue > 0 &&
        controller.hasClients &&
        controller.position.extentAfter <= math.max(oldValue, value) + 1;
    setState(() => _sidePanelExtraScroll = value);
    if (!shouldKeepReleasePosition) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !controller.hasClients) return;
      final position = controller.position;
      final next = (position.pixels + value - oldValue)
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble();
      if ((next - position.pixels).abs() >= 0.5) {
        controller.jumpTo(next);
      }
    });
  }

  void _setTransportDockMetrics(_TransportDockMetrics? value) {
    final current = _transportDockMetrics;
    if (current == null && value == null) return;
    if (current != null && value != null && current.closeTo(value)) return;
    setState(() => _transportDockMetrics = value);
  }

  Widget _editorMain(
    BuildContext context,
    ReplaceEditorState s,
    ReplaceEditorNotifier n,
  ) {
    final tlLow = s.tl.score < 0.5 || s.ai.tl.every((c) => c.score < 0.5);
    final plLow = s.pl.score < 0.5 || s.ai.pl.every((c) => c.score < 0.5);

    return _StickyTransportLayout(
      scrollController: _pageScrollController,
      viewportKey: _editorViewportKey,
      contentKey: _scrollContentKey,
      onMetricsChanged: _setTransportDockMetrics,
      pinGap: _EditorLayoutMetrics.verticalGap,
      before: WaveformCard(
        state: s,
        aiPending: s.aiPending,
        onSeek: (value) => unawaited(_seekTo(s, n, value)),
        onZoomIn: n.zoomIn,
        onZoomOut: n.zoomOut,
        onWheelZoom: n.zoomByFactor,
        onViewportWidth: (width) => n.waveformViewportWidth = width,
      ).tourAnchor('waveform'),
      transport: _transportBar(s, n, floating: false),
      after: [
        if (ref.watch(editorOptionsProvider).manualOnly)
          RmBanner(
            kind: RmBannerKind.info,
            title: ref.watch(editorOptionsProvider).slmEnabled
                ? '手动精调 + 循环建议'
                : '手动精调模式',
            body: ref.watch(editorOptionsProvider).slmEnabled
                ? '未运行 AI 模型；SeamlessLoopMusic 循环建议在人工精修右侧，试听确认后保存。'
                : '未运行 AI；可直接输入时间或在真实波形上选点。',
          )
        else if (s.aiPending)
          const RmBanner(
            kind: RmBannerKind.info,
            title: 'AI 候选生成中。',
            body: '下方候选和结构信息会先保持遮罩；播放、暂停和基础定位仍可使用。',
          )
        else
          RmBanner(
            kind: RmBannerKind.warn,
            title: 'AI 全局置信度 ${(s.ai.confidence * 100).round()}%。',
            body: 'TL 与 PL 部分候选低于 50%，已用黄色标记。请逐个使用"试听拼接"功能确认循环点无缝，再点击确认。',
          ),
        const SizedBox(height: 14),
        _group(
          s,
          n,
          GroupKind.td,
          s.ai.td,
          false,
          pending: s.aiPending,
        ).tourAnchor('details'),
        const SizedBox(height: 14),
        _group(s, n, GroupKind.tl, s.ai.tl, tlLow, pending: s.aiPending),
        const SizedBox(height: 14),
        _group(s, n, GroupKind.pd, s.ai.pd, false, pending: s.aiPending),
        const SizedBox(height: 14),
        _group(s, n, GroupKind.pl, s.ai.pl, plLow, pending: s.aiPending),
      ],
    );
  }

  Widget _transportBar(
    ReplaceEditorState s,
    ReplaceEditorNotifier n, {
    required bool floating,
  }) {
    return TransportBar(
      key: ValueKey(
        floating
            ? 'editor-transport-bar-floating'
            : 'editor-transport-bar-inline',
      ),
      state: s,
      aiPending: s.aiPending,
      floating: floating,
      onTogglePlay: () => unawaited(_togglePlayback(s, n)),
      onRewind: () => unawaited(_seekTo(s, n, 0)),
      onSkipFwd: () => unawaited(_seekTo(s, n, s.ai.durationSec)),
      trailing: floating
          ? const AuditionSettingsButton()
          : const AuditionSettingsButton().tourAnchor('audition'),
    );
  }

  Widget _group(
    ReplaceEditorState s,
    ReplaceEditorNotifier n,
    GroupKind kind,
    List<dynamic> candidates,
    bool low, {
    required bool pending,
  }) {
    final globalSync = ref.watch(editorOptionsProvider).syncPostLoop;
    final card = TimeGroupCard(
      postLoopSyncNotice: kind != GroupKind.pl
          ? null
          : globalSync
          ? (n.postLoopSyncPaused
                ? '本曲已临时暂停 PL 同步 TL'
                : 'PL 正在自动同步 TL 的时间与确认状态')
          : null,
      postLoopSyncLabel: kind != GroupKind.pl
          ? null
          : globalSync
          ? (n.postLoopSyncPaused ? '恢复自动同步' : '临时取消同步')
          : '一键同步 TL',
      onPostLoopSync: kind != GroupKind.pl
          ? null
          : () {
              if (globalSync) {
                n.setPostLoopSyncPaused(!n.postLoopSyncPaused);
              } else {
                n.syncPostLoopFromTrackLoop();
              }
            },
      hideCandidates: true,
      onManualDoubleTap: () => _openManualGroup(kind),
      manualOnly:
          ref.watch(editorOptionsProvider).manualOnly ||
          (ref.watch(editorOptionsProvider).slmEnabled && kind.isLoop),
      kind: kind,
      candidates: candidates,
      selectedIdx: s.selectedIdxOf(kind),
      confirmed: s.confirmedOf(kind),
      lowConfidence: low,
      onSelect: (i) => n.selectCandidate(kind, i),
      manualCandidate: s.manualCandidateOf(kind),
      manualSelected: s.selectedManualOf(kind),
      onManualRefine: () => _openManualRefine(s, n, kind),
      onConfirm: (i) => _confirmGroup(n, kind, i),
      onCancelConfirm: () => n.setConfirmed(kind, false),
      onPreview: (i) => unawaited(
        _previewCandidate(
          ref.read(replaceEditorProvider(widget.trackId)),
          n,
          kind,
          candidates[i],
        ),
      ),
      onNudge: (target, deltaSec) => n.nudge(kind, target, deltaSec),
      onTimeEdited: (target, seconds) => n.editTime(kind, target, seconds),
      onPreviewCurrent: () => unawaited(
        _previewCandidate(s, n, kind, switch (kind) {
          GroupKind.td => s.td,
          GroupKind.pd => s.pd,
          GroupKind.tl => s.tl,
          GroupKind.pl => s.pl,
        }),
      ),
      bpm: s.ai.bpm,
    );
    return AiPendingGate(
      pending: pending,
      overlayKey: ValueKey('editor-ai-pending-${kind.code.toLowerCase()}'),
      label: '${kind.name} 候选生成中',
      detail: '等待真实时间点与置信度。',
      blockInput: true,
      child: GestureDetector(
        onSecondaryTap: () {
          if (HardwareKeyboard.instance.isControlPressed) {
            _quickConfirmGroup(kind);
          }
        },
        child: card,
      ),
    );
  }

  void _confirmGroup(ReplaceEditorNotifier n, GroupKind kind, int index) {
    n.selectCandidate(kind, index);
    n.setConfirmed(kind, true);
    _scheduleSavePromptIfNeeded(
      ref.read(replaceEditorProvider(widget.trackId)),
    );
  }

  Future<void> _previewCandidate(
    ReplaceEditorState s,
    ReplaceEditorNotifier n,
    GroupKind kind,
    dynamic candidate,
  ) async {
    if (kind.isLoop) {
      final loop = candidate as LoopCandidate;
      await _playLoopPreview(s, n, loop.start, loop.end);
    } else {
      final point = candidate as PointCandidate;
      await _playPointPreview(s, n, point.t, kind);
    }
  }

  Future<void> _ensureAudioLoaded(
    ReplaceEditorState s,
    ReplaceEditorNotifier n, {
    double? initialStartSec,
    bool forceReload = false,
    bool preservePreviewState = false,
  }) async {
    if (!widget.enableAudio) return;
    final source = s.track.source.trim();
    if (source.isEmpty) return;
    if (!forceReload && source == _loadedSource) return;
    final existingLoad = _loadAudioFuture;
    if (existingLoad != null) {
      await existingLoad;
      if (!forceReload && source == _loadedSource) return;
    }
    final loadToken = ++_loadVersion;
    final load = _loadAudio(
      source,
      n,
      loadToken,
      initialStartSec: initialStartSec,
      preservePreviewState: preservePreviewState,
    );
    _loadAudioFuture = load;
    try {
      await load;
    } finally {
      if (identical(_loadAudioFuture, load)) {
        _loadAudioFuture = null;
      }
    }
  }

  Future<void> _loadAudio(
    String source,
    ReplaceEditorNotifier n,
    int loadToken, {
    double? initialStartSec,
    bool preservePreviewState = false,
  }) async {
    final player = _audioPlayer;
    try {
      await player.setVolume(
        Platform.environment['FH_RADIO_STUDIO_PREVIEW_DIAGNOSTICS'] == '1'
            ? 0
            : ref.read(auditionPreferencesProvider).volume,
      );
      _loadedSource = null;
      await _clearNativePreviewBounds(player);
      if (StudioAudioPlayers.editorSource == source) {
        await player.pause();
        await player.seek(_duration(initialStartSec ?? 0));
      } else {
        final media = Media(
          Uri.file(source).toString(),
          start: initialStartSec == null ? null : _duration(initialStartSec),
        );
        await player.open(media, play: false);
        StudioAudioPlayers.editorSource = source;
      }
      if (loadToken != _loadVersion) return;
      _loadedSource = source;
      _pausedByUser = false;
      _rangeSeeking = false;
      if (!preservePreviewState) {
        _previewRange = null;
      }
      n.setError(null);
    } on Object catch (error) {
      if (loadToken != _loadVersion) return;
      _setPlayback(n, PlaybackMode.idle, playing: false);
      n.setError('内置播放器无法打开源音频：$error');
    }
  }

  PlaybackMode get _currentPlaybackMode => _playbackInManual
      ? _manualPlayback?.mode ?? PlaybackMode.idle
      : ref.read(replaceEditorProvider(widget.trackId)).playbackMode;

  void _setPlayhead(ReplaceEditorNotifier notifier, double seconds) {
    if (!_playbackInManual) {
      notifier.setPlayhead(seconds);
      return;
    }
    final playback = _manualPlayback;
    if (!mounted ||
        _manualSession == null ||
        playback == null ||
        playback.playhead == seconds) {
      return;
    }
    setState(
      () => _manualPlayback = (
        playhead: seconds,
        playing: playback.playing,
        mode: playback.mode,
      ),
    );
  }

  void _setPlayback(
    ReplaceEditorNotifier notifier,
    PlaybackMode mode, {
    required bool playing,
  }) {
    if (!_playbackInManual) {
      notifier.setPlayback(mode, playing: playing);
      return;
    }
    final playback = _manualPlayback;
    if (!mounted ||
        _manualSession == null ||
        playback == null ||
        playback.playing == playing && playback.mode == mode) {
      return;
    }
    setState(
      () => _manualPlayback = (
        playhead: playback.playhead,
        playing: playing,
        mode: mode,
      ),
    );
  }

  int _beginPlaybackCommand() {
    _playbackInManual = _manualSession != null;
    return ++_playbackVersion;
  }

  bool _isCurrentPlaybackCommand(int token) {
    return mounted && token == _playbackVersion;
  }

  void _clearLocalPlaybackState() {
    unawaited(_seamAudition?.cancel());
    _seamAudition = null;
    _playbackVersion++;
    _loadVersion++;
    _loadedSource = null;
    _loadAudioFuture = null;
    _pausedByUser = false;
    _rangeSeeking = false;
    _pendingSnapToggle = false;
    _previewRange = null;
    _clearPreviewPositionHold();
    final player = _player;
    if (player != null) {
      unawaited(_clearNativePreviewBounds(player));
    }
  }

  void _startInitialAnalysis() {
    final s = ref.read(replaceEditorProvider(widget.trackId));
    if (!s.track.id.startsWith('real:')) return;
    if (_analysisStartedFor == s.track.id) return;
    _analysisStartedFor = s.track.id;
    final n = ref.read(replaceEditorProvider(widget.trackId).notifier);
    if (s.analyzing && !ref.read(editorOptionsProvider).manualOnly) {
      unawaited(n.analyze());
    } else {
      unawaited(n.loadWaveform());
    }
  }

  Future<void> _warmUpAudio() async {
    if (!widget.enableAudio) return;
    final state = ref.read(replaceEditorProvider(widget.trackId));
    if (state.track.source.trim().isEmpty) return;
    await _ensureAudioLoaded(
      state,
      ref.read(replaceEditorProvider(widget.trackId).notifier),
      preservePreviewState: true,
    );
  }

  Future<void> _togglePlayback(
    ReplaceEditorState s,
    ReplaceEditorNotifier n,
  ) async {
    if (!widget.enableAudio) return;
    final command = _beginPlaybackCommand();
    await _ensureAudioLoaded(s, n);
    if (!_isCurrentPlaybackCommand(command) || _loadedSource == null) return;
    final player = _audioPlayer;
    final activePlayback = player.state.playing && !player.state.completed;
    if (activePlayback) {
      await player.pause();
      if (!_isCurrentPlaybackCommand(command)) return;
      _pausedByUser = true;
      _setPlayback(
        n,
        s.playbackMode == PlaybackMode.idle
            ? PlaybackMode.full
            : s.playbackMode,
        playing: false,
      );
      return;
    }
    if (_pausedByUser) {
      _pausedByUser = false;
      await player.play();
      if (!_isCurrentPlaybackCommand(command)) return;
      _setPlayback(
        n,
        s.playbackMode == PlaybackMode.idle
            ? PlaybackMode.full
            : s.playbackMode,
        playing: true,
      );
      return;
    }
    await _seamAudition?.cancel();
    if (!_isCurrentPlaybackCommand(command)) return;
    _seamAudition = null;
    _previewRange = null;
    _rangeSeeking = false;
    final restartAtEnd = s.playhead >= s.ai.durationSec - 0.05;
    await _clearNativePreviewBounds(player);
    if (!_isCurrentPlaybackCommand(command)) return;
    await _seekPlayerTo(player, restartAtEnd ? 0 : s.playhead, exact: true);
    if (!_isCurrentPlaybackCommand(command)) return;
    await player.play();
    if (!_isCurrentPlaybackCommand(command)) return;
    _setPlayback(n, PlaybackMode.full, playing: true);
  }

  Future<void> _seekTo(
    ReplaceEditorState s,
    ReplaceEditorNotifier n,
    double seconds,
  ) async {
    final command = _beginPlaybackCommand();
    await _seamAudition?.cancel();
    if (!_isCurrentPlaybackCommand(command)) return;
    _seamAudition = null;
    final next = seconds.clamp(0, s.ai.durationSec).toDouble();
    _holdPreviewPosition(command, next);
    _setPlayhead(n, next);
    _previewRange = null;
    _rangeSeeking = false;
    final player = _player;
    final playing = player?.state.playing ?? false;
    _setPlayback(
      n,
      playing ? PlaybackMode.full : PlaybackMode.idle,
      playing: playing,
    );
    if (_loadedSource == null ||
        !_isCurrentPlaybackCommand(command) ||
        player == null) {
      return;
    }
    await _clearNativePreviewBounds(player);
    if (!_isCurrentPlaybackCommand(command)) return;
    await _seekPlayerTo(player, next, exact: true);
  }

  double _pointDuration(GroupKind kind) =>
      ref.read(auditionPreferencesProvider).pointDuration(kind == GroupKind.pd);

  Future<void> _playPointPreview(
    ReplaceEditorState s,
    ReplaceEditorNotifier n,
    double timeSec,
    GroupKind kind,
  ) async {
    if (!widget.enableAudio) return;
    final command = _beginPlaybackCommand();
    await _seamAudition?.cancel();
    if (!_isCurrentPlaybackCommand(command)) return;
    _seamAudition = null;
    final window = pointPreviewWindowForTesting(
      timeSec: timeSec,
      durationSec: _previewDuration(s, timeSec + _pointDuration(kind)),
      previewDuration: _pointDuration(kind),
    );
    final start = window.start;
    final end = window.end;
    _preparePreviewStartup(
      command,
      n,
      range: _PreviewRange(start: start, end: end, loop: false),
      playhead: start,
    );
    await _ensureAudioLoaded(
      s,
      n,
      initialStartSec: start,
      preservePreviewState: true,
    );
    final player = _player;
    if (!_isCurrentPlaybackCommand(command) ||
        _loadedSource == null ||
        player == null) {
      _cancelPreviewStartup(command);
      return;
    }
    if (!await _startPreviewPlayback(command, player, start, stopAtSec: end)) {
      return;
    }
    _setPlayback(n, PlaybackMode.pointPreview, playing: true);
  }

  Future<void> _playLoopPreview(
    ReplaceEditorState s,
    ReplaceEditorNotifier n,
    double startSec,
    double endSec,
  ) async {
    if (!widget.enableAudio) return;
    final command = _beginPlaybackCommand();
    await _seamAudition?.cancel();
    if (!_isCurrentPlaybackCommand(command)) return;
    _seamAudition = null;
    final duration = _previewDuration(s, math.max(startSec, endSec));
    final start = startSec.clamp(0, duration).toDouble();
    if (endSec <= start) return;
    final end = endSec.clamp(start + .1, duration).toDouble();
    final options = ref.read(auditionPreferencesProvider);
    final auditionStart = (end - options.before).clamp(start, end).toDouble();
    _preparePreviewStartup(
      command,
      n,
      range: _PreviewRange(start: start, end: end, loop: true),
      playhead: auditionStart,
    );
    await _ensureAudioLoaded(
      s,
      n,
      initialStartSec: auditionStart,
      preservePreviewState: true,
    );
    final player = _player;
    if (!_isCurrentPlaybackCommand(command) ||
        _loadedSource == null ||
        player == null) {
      _cancelPreviewStartup(command);
      return;
    }
    late final SeamAuditionPlayer audition;
    audition = SeamAuditionPlayer(
      player: player,
      start: start,
      end: end,
      options: options,
      muted: Platform.environment['FH_RADIO_STUDIO_PREVIEW_DIAGNOSTICS'] == '1',
      isCurrent: () => mounted && identical(_seamAudition, audition),
      onDone: () {
        if (!mounted) return;
        _previewRange = null;
        _seamAudition = null;
        _setPlayback(n, PlaybackMode.idle, playing: false);
      },
      onError: (error) {
        if (mounted) n.setError('循环试听失败：$error');
      },
    );
    _seamAudition = audition;
    await audition.start();
    if (!_isCurrentPlaybackCommand(command)) return;
    _setPlayback(n, PlaybackMode.loopPreview, playing: player.state.playing);
  }

  double _previewDuration(ReplaceEditorState s, double minimum) {
    final trackDuration = s.track.durationSec;
    return math.max(math.max(s.ai.durationSec, trackDuration), minimum);
  }

  Future<bool> _startPreviewPlayback(
    int command,
    Player player,
    double seconds, {
    double? stopAtSec,
    ({double start, double end})? loopBounds,
  }) async {
    _holdPreviewPosition(command, seconds);
    await player.pause();
    if (!_isCurrentPlaybackCommand(command)) return false;
    final playerManagedLoop =
        loopBounds != null &&
        await _configureNativeLoopBounds(
          player,
          loopBounds.start,
          loopBounds.end,
        );
    if (!_isCurrentPlaybackCommand(command)) return false;
    if (loopBounds == null) {
      await _clearNativeLoopBounds(player);
      if (!_isCurrentPlaybackCommand(command)) return false;
      await _setNativePreviewEnd(player, stopAtSec);
    } else if (!playerManagedLoop) {
      await _setNativePreviewEnd(player, null);
    }
    if (!_isCurrentPlaybackCommand(command)) return false;
    final range = _previewRange;
    if (range != null && range.loop && playerManagedLoop) {
      _previewRange = range.withPlayerManagedLoop();
    }
    await _seekPlayerTo(player, seconds, exact: true);
    if (!_isCurrentPlaybackCommand(command)) return false;
    await Future<void>.delayed(Duration.zero);
    if (!_isCurrentPlaybackCommand(command)) return false;
    await player.play();
    if (Platform.environment['FH_RADIO_STUDIO_PREVIEW_DIAGNOSTICS'] == '1') {
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 600), () {
          if (_isCurrentPlaybackCommand(command)) {
            debugPrint(
              'EDITOR_PREVIEW expected=$seconds actual=${player.state.position.inMilliseconds / 1000} playing=${player.state.playing}',
            );
          }
        }),
      );
    }
    return _isCurrentPlaybackCommand(command);
  }

  void _handlePosition(Duration position) {
    if (!mounted) return;
    final n = ref.read(replaceEditorProvider(widget.trackId).notifier);
    final seconds = position.inMilliseconds / 1000.0;
    if (_ignoreStalePreviewPosition(seconds)) return;
    final range = _previewRange;
    final player = _player;
    if (_seamAudition?.active == true) {
      _setPlayhead(n, seconds);
      return;
    }
    if (range != null && player?.state.playing != true) {
      _setPlayhead(n, seconds);
      return;
    }
    if (range == null || _rangeSeeking || seconds < range.end) {
      _setPlayhead(n, seconds);
      return;
    }

    if (range.loop && range.playerManagedLoop) {
      _setPlayhead(n, range.start);
      return;
    }

    if (range.loop) {
      _rangeSeeking = true;
      _setPlayhead(n, range.start);
      final command = _playbackVersion;
      _holdPreviewPosition(command, range.start);
      final seek = player == null
          ? null
          : _seekPlayerTo(player, range.start, exact: true);
      if (seek == null) {
        _rangeSeeking = false;
      } else {
        unawaited(
          seek.whenComplete(() {
            if (command == _playbackVersion) {
              _rangeSeeking = false;
            }
          }),
        );
      }
      return;
    }

    _previewRange = null;
    _pausedByUser = false;
    _setPlayhead(n, range.end);
    _setPlayback(n, PlaybackMode.idle, playing: false);
    if (player != null) {
      unawaited(_clearNativePreviewBounds(player));
      unawaited(player.pause());
    }
  }

  void _preparePreviewStartup(
    int command,
    ReplaceEditorNotifier n, {
    required _PreviewRange range,
    required double playhead,
  }) {
    _previewRange = range;
    _rangeSeeking = false;
    _pausedByUser = false;
    _holdPreviewPosition(command, playhead);
    _setPlayhead(n, playhead);
  }

  void _cancelPreviewStartup(int command) {
    _clearPreviewPositionHold(command);
    if (_playbackVersion != command) return;
    _previewRange = null;
    _rangeSeeking = false;
    _pausedByUser = false;
  }

  void _holdPreviewPosition(int command, double targetSec) {
    _positionHoldTimer?.cancel();
    _positionHoldCommand = command;
    _positionHoldTargetSec = targetSec;
    _positionHoldTimer = Timer(previewSeekPositionHold, () {
      if (!mounted) return;
      _clearPreviewPositionHold(command);
    });
  }

  void _clearPreviewPositionHold([int? command]) {
    if (command != null && _positionHoldCommand != command) return;
    _positionHoldTimer?.cancel();
    _positionHoldTimer = null;
    _positionHoldCommand = null;
    _positionHoldTargetSec = null;
  }

  bool _ignoreStalePreviewPosition(double seconds) {
    final command = _positionHoldCommand;
    final target = _positionHoldTargetSec;
    if (command == null || target == null) return false;
    if (command != _playbackVersion) {
      _clearPreviewPositionHold();
      return false;
    }
    if (!_isStalePreviewStartupPosition(seconds, target)) {
      _clearPreviewPositionHold(command);
      return false;
    }
    return true;
  }

  Duration _duration(double seconds) {
    return Duration(milliseconds: (seconds * 1000).round());
  }

  Future<void> _seekPlayerTo(
    Player player,
    double seconds, {
    required bool exact,
  }) async {
    final native = player.platform;
    if (native is NativePlayer) {
      try {
        await (native as dynamic).command([
          'seek',
          _mpvTimestamp(seconds),
          exact ? 'absolute+exact' : 'absolute',
        ]);
        native.state = native.state.copyWith(completed: false);
        return;
      } on Object {
        // Some media_kit platforms expose a NativePlayer stub without raw mpv
        // commands. Fall back to the public API.
      }
    }
    await player.seek(_duration(seconds));
  }

  Future<bool> _configureNativeLoopBounds(
    Player player,
    double startSec,
    double endSec,
  ) async {
    final native = player.platform;
    if (native is! NativePlayer) return false;
    try {
      await (native as dynamic).setProperty('end', 'none');
      await (native as dynamic).setProperty(
        'ab-loop-a',
        _mpvTimestamp(startSec),
      );
      await (native as dynamic).setProperty('ab-loop-b', _mpvTimestamp(endSec));
      return true;
    } on Object {
      try {
        await (native as dynamic).setProperty('ab-loop-a', 'no');
        await (native as dynamic).setProperty('ab-loop-b', 'no');
      } on Object {
        // Keep the original failure path: Dart-side looping will take over.
      }
      return false;
    }
  }

  Future<void> _setNativePreviewEnd(Player player, double? seconds) async {
    final native = player.platform;
    if (native is! NativePlayer) return;
    try {
      await (native as dynamic).setProperty(
        'end',
        seconds == null ? 'none' : _mpvTimestamp(seconds),
      );
    } on Object {
      // Best-effort native preview bound; public media_kit playback still works.
    }
  }

  Future<void> _clearNativeLoopBounds(Player player) async {
    final native = player.platform;
    if (native is! NativePlayer) return;
    try {
      await (native as dynamic).setProperty('ab-loop-a', 'no');
      await (native as dynamic).setProperty('ab-loop-b', 'no');
    } on Object {
      // Best-effort native preview bound reset.
    }
  }

  Future<void> _clearNativePreviewBounds(Player player) async {
    final native = player.platform;
    if (native is! NativePlayer) return;
    try {
      await (native as dynamic).setProperty('end', 'none');
      await (native as dynamic).setProperty('ab-loop-a', 'no');
      await (native as dynamic).setProperty('ab-loop-b', 'no');
    } on Object {
      // Best-effort native preview bound reset.
    }
  }

  bool _saveConfig(
    BuildContext context,
    ReplaceEditorNotifier n, {
    required String title,
  }) {
    try {
      n.saveToProject();
    } on Object catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('保存失败：$error')));
      }
      return false;
    }
    if (!context.mounted) return false;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已保存配置：$title')));
    return true;
  }

  void _scheduleSavePromptIfNeeded(ReplaceEditorState state) {
    if (!state.allConfirmed) return;
    if (_savePromptOpen || _matchesSavedTimingConfig(state)) return;
    _savePromptOpen = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || ModalRoute.of(context)?.isCurrent != true) {
        _savePromptOpen = false;
        return;
      }
      final latest = ref.read(replaceEditorProvider(widget.trackId));
      if (!latest.allConfirmed || _matchesSavedTimingConfig(latest)) {
        _savePromptOpen = false;
        return;
      }
      final save = await _showSaveConfigDialog(context, latest);
      _savePromptOpen = false;
      if (!mounted || (save != 'save' && save != 'assign')) return;
      final current = ref.read(replaceEditorProvider(widget.trackId));
      if (_matchesSavedTimingConfig(current)) return;
      final ok = _saveConfig(
        context,
        ref.read(replaceEditorProvider(widget.trackId).notifier),
        title: current.track.title,
      );
      if (ok && save == 'assign' && mounted) {
        await showQuickAssign(context, current.track);
      }
    });
  }

  bool _matchesSavedTimingConfig(ReplaceEditorState state) {
    final saved = ref
        .read(trackTimingProvider.notifier)
        .configForPath(state.track.source);
    if (saved == null || !saved.allConfirmed) return false;
    if ((saved.bpm - state.ai.bpm).abs() > .001 ||
        saved.bpmManual != state.bpmManual) {
      return false;
    }
    for (final key in trackMarkerKeys) {
      final current = state.markerSeconds[key];
      final stored = saved.markersSec[key];
      if (current == null || stored == null) return false;
      if ((current - stored).abs() > 0.001) return false;
    }
    for (final key in trackGroupKeys) {
      if (state.confirmedGroups[key] != saved.confirmed[key]) return false;
    }
    return true;
  }

  Future<String?> _showSaveConfigDialog(
    BuildContext context,
    ReplaceEditorState state,
  ) {
    final showAssignment = editableAssignmentPlan(
      ref,
    ).assignmentsForPath(state.track.source).isEmpty;
    return showDialog<String>(
      context: context,
      barrierColor: RmTokens.modalBackdrop,
      builder: (context) {
        final rm = context.rm;
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(40),
          child: Container(
            width: 520,
            decoration: BoxDecoration(
              color: rm.panel,
              border: Border.all(color: rm.borderStrong),
              borderRadius: BorderRadius.circular(RmTokens.rXl),
              boxShadow: RmTokens.modal,
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 34,
                        height: 34,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: rm.accent.bg,
                          border: Border.all(color: rm.accent.ring),
                          borderRadius: BorderRadius.circular(RmTokens.rMd),
                        ),
                        child: RmIcon('check', size: 17, color: rm.accent.base),
                      ),
                      const SizedBox(width: 13),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '时间点已全部确认',
                              style: RmText.microLabel(color: rm.accent.base),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '保存这首歌的配置？',
                              style: RmText.modalH2(color: rm.fg),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '${state.track.title} 的 4 组时间点已经确认，当前配置还没有保存到项目，或与已保存配置不同。',
                              style: RmText.sans(
                                13,
                                color: rm.fg3,
                                height: 1.45,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.fromLTRB(24, 14, 24, 22),
                  decoration: BoxDecoration(
                    border: Border(top: BorderSide(color: rm.border)),
                  ),
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      RmButton(
                        onPressed: () => Navigator.of(context).pop('cancel'),
                        label: '暂不保存',
                      ),
                      const SizedBox(width: 10),
                      RmButton(
                        onPressed: () => Navigator.of(context).pop('save'),
                        variant: RmButtonVariant.primary,
                        leading: const RmIcon('check', size: 12),
                        label: '保存配置',
                      ),
                      if (showAssignment)
                        RmButton(
                          label: '保存并分配电台',
                          variant: RmButtonVariant.primary,
                          onPressed: () => Navigator.of(context).pop('assign'),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _EditorLayoutMetrics {
  const _EditorLayoutMetrics({
    required this.pageWidth,
    required this.horizontalPadding,
    required this.innerWidth,
    required this.sideWidth,
  });

  static const sideGap = 14.0;
  static const verticalGap = 14.0;

  final double pageWidth;
  final double horizontalPadding;
  final double innerWidth;
  final double sideWidth;
}

class _StickyTransportLayout extends StatefulWidget {
  const _StickyTransportLayout({
    required this.scrollController,
    required this.viewportKey,
    required this.contentKey,
    required this.onMetricsChanged,
    required this.pinGap,
    required this.before,
    required this.transport,
    required this.after,
  });

  final ScrollController scrollController;
  final GlobalKey viewportKey;
  final GlobalKey contentKey;
  final ValueChanged<_TransportDockMetrics?> onMetricsChanged;
  final double pinGap;
  final Widget before;
  final Widget transport;
  final List<Widget> after;

  @override
  State<_StickyTransportLayout> createState() => _StickyTransportLayoutState();
}

class _StickyTransportLayoutState extends State<_StickyTransportLayout> {
  final _anchorKey = GlobalKey();
  double? _anchorContentTop;
  bool _measureScheduled = false;

  @override
  void initState() {
    super.initState();
    _scheduleMeasure();
  }

  @override
  void didUpdateWidget(covariant _StickyTransportLayout oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scheduleMeasure();
  }

  @override
  void dispose() {
    widget.onMetricsChanged(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _scheduleMeasure();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        widget.before,
        SizedBox(height: widget.pinGap),
        KeyedSubtree(
          key: _anchorKey,
          child: AnimatedBuilder(
            animation: widget.scrollController,
            child: widget.transport,
            builder: (context, child) {
              final pinned = _isPinned();
              return IgnorePointer(
                ignoring: pinned,
                child: Opacity(opacity: pinned ? 0 : 1, child: child),
              );
            },
          ),
        ),
        SizedBox(height: widget.pinGap),
        ...widget.after,
      ],
    );
  }

  bool _isPinned() {
    final anchorTop = _anchorContentTop;
    return anchorTop != null &&
        widget.scrollController.hasClients &&
        widget.scrollController.position.pixels + widget.pinGap >= anchorTop;
  }

  void _scheduleMeasure() {
    if (_measureScheduled) return;
    _measureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measureScheduled = false;
      _measureAnchors();
    });
  }

  void _measureAnchors() {
    if (!mounted) return;
    final contentBox =
        widget.contentKey.currentContext?.findRenderObject() as RenderBox?;
    final viewportBox =
        widget.viewportKey.currentContext?.findRenderObject() as RenderBox?;
    final box = _anchorKey.currentContext?.findRenderObject() as RenderBox?;
    if (contentBox == null ||
        viewportBox == null ||
        box == null ||
        !contentBox.attached ||
        !viewportBox.attached ||
        !box.attached ||
        !contentBox.hasSize ||
        !viewportBox.hasSize ||
        !box.hasSize) {
      widget.onMetricsChanged(null);
      return;
    }

    final anchorGlobal = box.localToGlobal(Offset.zero);
    final anchorTop = contentBox.globalToLocal(anchorGlobal).dy;
    final next = _TransportDockMetrics(
      anchorContentTop: anchorTop,
      viewportLeft: viewportBox.globalToLocal(anchorGlobal).dx,
      width: box.size.width,
    );
    if (_anchorContentTop == null ||
        (_anchorContentTop! - anchorTop).abs() >= 0.5) {
      setState(() => _anchorContentTop = anchorTop);
    }
    widget.onMetricsChanged(next);
  }
}

class _TransportFloatingOverlay extends StatelessWidget {
  const _TransportFloatingOverlay({
    required this.scrollController,
    required this.metrics,
    required this.pinGap,
    required this.child,
  });

  final ScrollController scrollController;
  final _TransportDockMetrics? metrics;
  final double pinGap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: scrollController,
      child: child,
      builder: (context, child) {
        final m = metrics;
        final pinned =
            m != null &&
            scrollController.hasClients &&
            scrollController.position.pixels + pinGap >= m.anchorContentTop;
        if (!pinned) return const SizedBox.shrink();
        return Positioned(
          top: pinGap,
          left: m.viewportLeft,
          width: m.width,
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
  }
}

class _TransportDockMetrics {
  const _TransportDockMetrics({
    required this.anchorContentTop,
    required this.viewportLeft,
    required this.width,
  });

  final double anchorContentTop;
  final double viewportLeft;
  final double width;

  bool closeTo(_TransportDockMetrics other) {
    return (anchorContentTop - other.anchorContentTop).abs() < 0.5 &&
        (viewportLeft - other.viewportLeft).abs() < 0.5 &&
        (width - other.width).abs() < 0.5;
  }
}

class _StickySidePanel extends StatefulWidget {
  const _StickySidePanel({
    required this.width,
    required this.contentKey,
    required this.pinGap,
    required this.bottomGap,
    required this.viewportHeight,
    required this.scrollController,
    required this.onExtraExtentChanged,
    required this.child,
  });

  final double width;
  final GlobalKey contentKey;
  final double pinGap;
  final double bottomGap;
  final double viewportHeight;
  final ScrollController scrollController;
  final ValueChanged<double> onExtraExtentChanged;
  final Widget child;

  @override
  State<_StickySidePanel> createState() => _StickySidePanelState();
}

class _StickySidePanelState extends State<_StickySidePanel> {
  final _anchorKey = GlobalKey();
  final _childKey = GlobalKey();
  double _extraExtent = 0;
  double? _anchorContentTop;
  bool _measureScheduled = false;

  @override
  void initState() {
    super.initState();
    _scheduleMeasure();
  }

  @override
  void didUpdateWidget(covariant _StickySidePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scheduleMeasure();
  }

  @override
  Widget build(BuildContext context) {
    if (_anchorContentTop == null) {
      _scheduleMeasure();
    }
    return SizedBox(
      key: _anchorKey,
      width: widget.width,
      child: AnimatedBuilder(
        animation: widget.scrollController,
        child: KeyedSubtree(key: _childKey, child: widget.child),
        builder: (context, child) {
          final offset = _stickyOffset();
          return Transform.translate(offset: Offset(0, offset), child: child);
        },
      ),
    );
  }

  void _scheduleMeasure() {
    if (_measureScheduled) return;
    _measureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measureScheduled = false;
      _measureLayout();
    });
  }

  void _measureLayout() {
    if (!mounted) return;
    final childBox = _childKey.currentContext?.findRenderObject() as RenderBox?;
    final anchorTop = _topInScrollContent(_anchorKey);
    final availableHeight = math.max(
      0.0,
      widget.viewportHeight - widget.pinGap - widget.bottomGap,
    );
    final nextExtra =
        childBox == null || !childBox.attached || !childBox.hasSize
        ? _extraExtent
        : math.max(0.0, childBox.size.height - availableHeight);
    final extraChanged = (_extraExtent - nextExtra).abs() >= 0.5;
    final anchorChanged =
        anchorTop != null &&
        (_anchorContentTop == null ||
            (_anchorContentTop! - anchorTop).abs() >= 0.5);
    if (!extraChanged && !anchorChanged) return;
    setState(() {
      _extraExtent = nextExtra;
      if (anchorTop != null) _anchorContentTop = anchorTop;
    });
    if (extraChanged) widget.onExtraExtentChanged(nextExtra);
  }

  double _stickyOffset() {
    final anchorTop = _anchorContentTop;
    if (anchorTop == null || !widget.scrollController.hasClients) return 0;
    final pinTop = widget.scrollController.position.pixels + widget.pinGap;
    final release = _releaseDistance();
    return math.max(0.0, pinTop - release - anchorTop);
  }

  double? _topInScrollContent(GlobalKey key) {
    final contentBox =
        widget.contentKey.currentContext?.findRenderObject() as RenderBox?;
    final box = key.currentContext?.findRenderObject() as RenderBox?;
    if (contentBox == null ||
        box == null ||
        !contentBox.attached ||
        !box.attached ||
        !contentBox.hasSize ||
        !box.hasSize) {
      return null;
    }
    return contentBox.globalToLocal(box.localToGlobal(Offset.zero)).dy;
  }

  double _releaseDistance() {
    final controller = widget.scrollController;
    if (!controller.hasClients || _extraExtent <= 0) return 0;
    final extentAfter = controller.position.extentAfter;
    return (_extraExtent - extentAfter).clamp(0.0, _extraExtent).toDouble();
  }
}

class _SideRailButton extends StatelessWidget {
  const _SideRailButton({required this.open, required this.onTap});

  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: rm.panel,
            border: Border.all(color: open ? rm.accent.ring : rm.border),
            borderRadius: BorderRadius.circular(999),
            boxShadow: RmTokens.popover,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: rm.accent.base,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'AI / 快捷键',
                style: RmText.sans(12, weight: FontWeight.w600, color: rm.fg),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FloatingSideDrawer extends StatelessWidget {
  const _FloatingSideDrawer({
    required this.state,
    required this.analysis,
    required this.onClose,
    required this.onAnalyze,
  });

  final ReplaceEditorState state;
  final AudioAnalysisState? analysis;
  final VoidCallback onClose;
  final VoidCallback onAnalyze;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(RmTokens.rLg);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: ClipRRect(
            key: const ValueKey('editor-side-drawer-clip'),
            borderRadius: radius,
            child: SingleChildScrollView(
              child: EditorSidePanel(
                manualOnly: ProviderScope.containerOf(
                  context,
                ).read(editorOptionsProvider).manualOnly,
                seamless: ProviderScope.containerOf(
                  context,
                ).read(editorOptionsProvider).slmEnabled,
                state: state,
                analysis: analysis,
                onAnalyze: onAnalyze,
              ).tourAnchor('side'),
            ),
          ),
        ),
        Positioned(
          top: -8,
          right: -8,
          child: RmButton.icon(
            onPressed: onClose,
            icon: const RmIcon('x', size: 12),
            variant: RmButtonVariant.defaultBtn,
            tooltip: '收起',
          ),
        ),
      ],
    );
  }
}

class _ManualRefineWideBody extends StatelessWidget {
  const _ManualRefineWideBody({
    required this.main,
    required this.aiPanelBuilder,
  });
  final Widget main;
  final Widget Function(double height) aiPanelBuilder;
  @override
  Widget build(BuildContext context) => EditorColumns(
    main: main,
    sideWidth: 300,
    side: LayoutBuilder(
      builder: (context, box) => aiPanelBuilder(box.maxHeight),
    ),
  );
}

class _ManualRefineOverlay extends StatefulWidget {
  const _ManualRefineOverlay({
    super.key,
    required this.state,
    required this.session,
    required this.viewport,
    required this.preferredWidth,
    required this.aiCandidates,
    this.seamless = false,
    required this.snapActive,
    required this.onToggleSnap,
    required this.onMarkPlayback,
    required this.onPlace,
    required this.onSeek,
    required this.onApplyCandidate,
    required this.onPickTarget,
    required this.onNudge,
    required this.onAudition,
    required this.onCancel,
    this.onTourComplete,
    required this.onUndo,
    required this.onRedo,
    required this.shortcutHint,
    required this.onConfirm,
    required this.onTogglePlay,
    required this.onRewind,
    required this.onSkipFwd,
  });

  final ReplaceEditorState state;
  final _ManualRefineSession session;
  final BoxConstraints viewport;
  final double preferredWidth;
  final List<dynamic> aiCandidates;
  final bool seamless;

  /// 磁吸到拍是否生效（按住自由放置快捷键时为 false）。
  final bool snapActive;
  final VoidCallback onToggleSnap, onMarkPlayback;
  final void Function(double seconds, {required bool isMove}) onPlace;
  final ValueChanged<double> onSeek;
  final ValueChanged<dynamic> onApplyCandidate;
  final ValueChanged<FineTarget> onPickTarget;
  final void Function(FineTarget target, double deltaSec) onNudge;
  final VoidCallback onAudition;
  final VoidCallback onCancel;
  final VoidCallback? onTourComplete;
  final VoidCallback? onUndo, onRedo;
  final String shortcutHint;
  final VoidCallback onConfirm;
  final VoidCallback onTogglePlay;
  final VoidCallback onRewind;
  final VoidCallback onSkipFwd;

  @override
  State<_ManualRefineOverlay> createState() => _ManualRefineOverlayState();
}

class _ManualRefineOverlayState extends State<_ManualRefineOverlay> {
  ReplaceEditorState get state => widget.state;
  _ManualRefineSession get session => widget.session;
  BoxConstraints get viewport => widget.viewport;
  List<dynamic> get aiCandidates => widget.aiCandidates;
  bool get snapActive => widget.snapActive;
  void Function(double seconds, {required bool isMove}) get onPlace =>
      widget.onPlace;
  ValueChanged<dynamic> get onApplyCandidate => widget.onApplyCandidate;
  ValueChanged<FineTarget> get onPickTarget => widget.onPickTarget;
  void Function(FineTarget target, double deltaSec) get onNudge =>
      widget.onNudge;
  VoidCallback get onAudition => widget.onAudition;
  VoidCallback get onCancel => widget.onCancel;
  VoidCallback get onConfirm => widget.onConfirm;
  VoidCallback get onTogglePlay => widget.onTogglePlay;
  VoidCallback get onRewind => widget.onRewind;
  VoidCallback get onSkipFwd => widget.onSkipFwd;
  bool get seamless => widget.seamless;
  double _zoomWidth = 800;
  double _zoomStart = 0;
  double? _zoomEnd;
  @override
  void didUpdateWidget(covariant _ManualRefineOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (state.playing && _zoomEnd != null) {
      final view = pagedPlaybackWindow(
        duration: state.ai.durationSec,
        start: _zoomStart,
        end: _zoomEnd!,
        playhead: state.playhead,
      );
      _zoomStart = view.start;
      _zoomEnd = view.end;
    }
  }

  void _zoom(double factor) {
    final duration = state.ai.durationSec;
    if (duration <= 0) return;
    final span = ((_zoomEnd ?? duration) - _zoomStart) * factor;
    final width = span
        .clamp(
          minimumWaveformSpan(
            duration: duration,
            bins: state.ai.waveformPeaks.isEmpty
                ? 512
                : state.ai.waveformPeaks.length,
            width: _zoomWidth,
          ),
          duration,
        )
        .toDouble();
    final center = state.playhead;
    setState(() {
      _zoomStart = (center - width / 2).clamp(0.0, duration - width);
      _zoomEnd = _zoomStart + width;
    });
  }

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final width = math.min(
      widget.preferredWidth,
      math.max(0.0, viewport.maxWidth - 48),
    );
    final height = math.min(724.0, math.max(0.0, viewport.maxHeight - 48));
    final compact = width < 860;

    return Stack(
      key: const ValueKey('manual-refine-overlay'),
      children: [
        // 背景虚化 + 冷色压暗遮罩：精修台浮到屏幕中央，背后的编辑器被模糊压暗。
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onCancel,
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
              child: const ColoredBox(color: RmTokens.modalBackdrop),
            ),
          ),
        ),
        Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: width, maxHeight: height),
            child: GestureDetector(
              onTap: () {},
              child: Container(
                decoration: BoxDecoration(
                  color: rm.panel,
                  border: Border.all(color: rm.borderStrong),
                  borderRadius: BorderRadius.circular(RmTokens.rXl),
                  boxShadow: RmTokens.modal,
                ),
                clipBehavior: Clip.antiAlias,
                // 高度跟随内容（最高到 maxHeight），不再撑满留出大片空白。
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _header(context),
                    Flexible(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: compact
                            ? _compactBody(context)
                            : _wideBody(context),
                      ),
                    ),
                    _footer(context),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    ).withFeatureTour(TourPage.refine, onComplete: widget.onTourComplete);
  }

  Widget _header(BuildContext context) {
    final rm = context.rm;
    final acc = groupAccent(rm, session.kind);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 13, 14, 12),
      decoration: BoxDecoration(
        color: rm.panel,
        border: Border(bottom: BorderSide(color: rm.border)),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: acc.bg,
              border: Border.all(color: acc.ring),
              borderRadius: BorderRadius.circular(RmTokens.rMd),
            ),
            child: Text(
              session.kind.code,
              style: RmText.mono(12, weight: FontWeight.w700, color: acc.base),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${session.kind.name} · 人工精修',
                  style: RmText.sans(17, weight: FontWeight.w700, color: rm.fg),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 3),
                Text(
                  session.kind.isLoop
                      ? '左键定位播放；右键放置或拖动 A / B，确认后锁定。'
                      : '左键定位播放；右键放置或拖动起点，确认后锁定。',
                  style: RmText.sans(12.5, color: rm.fg3),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          RmButton.icon(
            key: const ValueKey('manual-zoom-out'),
            icon: const RmIcon('zoom-out', size: 12),
            tooltip: '缩小波形 · Ctrl + 滚轮',
            onPressed: () => _zoom(1.55),
          ),
          const SizedBox(width: 6),
          RmButton.icon(
            key: const ValueKey('manual-zoom-in'),
            icon: const RmIcon('zoom-in', size: 12),
            tooltip: '放大波形 · Ctrl + 滚轮',
            onPressed: () => _zoom(0.65),
          ),
          const SizedBox(width: 10),
          _statusPill(context),
          const SizedBox(width: 6),
          const SizedBox(width: 6),
          RmButton.icon(
            onPressed: onCancel,
            icon: const RmIcon('x', size: 13),
            tooltip: '取消人工选点',
          ),
        ],
      ),
    );
  }

  Widget _wideBody(BuildContext context) {
    if (aiCandidates.isEmpty) {
      return SingleChildScrollView(
        child: _mainEditor(context, scrollable: false),
      );
    }
    // 左侧自然高度决定右侧 AI panel 高度：少候选时撑满，多候选时内部滚动。
    return SingleChildScrollView(
      child: _ManualRefineWideBody(
        main: _mainEditor(context, scrollable: false),
        aiPanelBuilder: (height) =>
            SizedBox(width: 300, height: height, child: _aiApplyPanel(context)),
      ),
    );
  }

  Widget _compactBody(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _mainEditor(context, scrollable: false),
          if (aiCandidates.isNotEmpty) ...[
            const SizedBox(height: 12),
            SizedBox(height: 260, child: _aiApplyPanel(context)),
          ],
        ],
      ),
    );
  }

  Widget _mainEditor(BuildContext context, {bool scrollable = true}) {
    final content = Column(
      key: const ValueKey('manual-refine-main-editor'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _focusWaveform(context),
        const SizedBox(height: 10),
        TransportBar(
          state: state,
          aiPending: false,
          compact: true,
          onTogglePlay: onTogglePlay,
          onRewind: onRewind,
          onSkipFwd: onSkipFwd,
          onUndo: widget.onUndo,
          onRedo: widget.onRedo,
          actions: _transportActions(context),
        ),
        const SizedBox(height: 10),
        _finePanel(context),
      ],
    );
    if (!scrollable) return content;
    return SingleChildScrollView(child: content);
  }

  /// 精修台主波形 —— 直接点 / 拖放置当前时间组的端点。
  Widget _focusWaveform(BuildContext context) {
    final rm = context.rm;
    final acc = groupAccent(rm, session.kind);
    final ai = state.ai;
    final bars = ai.waveformPeaks.isEmpty
        ? WaveformBars.build(segments: ai.segments, duration: ai.durationSec)
        : WaveformBars.fromValues(ai.waveformPeaks);

    final List<FocusHandle> handles;
    if (session.kind.isLoop) {
      final editingEnd = session.activeTarget == FineTarget.loopEnd;
      handles = [
        FocusHandle(
          key: 'a',
          t: session.start,
          label: '${session.kind.code}·A',
          active: !editingEnd,
          dim: editingEnd,
        ),
        FocusHandle(
          key: 'b',
          t: session.end,
          label: '${session.kind.code}·B',
          active: editingEnd,
          dim: !editingEnd,
        ),
      ];
    } else {
      handles = [
        FocusHandle(
          key: 't',
          t: session.pointTime,
          label: session.kind.code,
          active: true,
        ),
      ];
    }

    return EditorWaveformPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ManualFocusWaveform(
            bars: bars,
            beats: ai.beats,
            segments: ai.segments,
            duration: ai.durationSec,
            onZoom: _zoom,
            onViewportWidth: (width) => _zoomWidth = width,
            windowStart: _zoomStart,
            windowEnd: _zoomEnd,
            accent: acc.base,
            handles: handles,
            free: !snapActive,
            locked: false,
            playhead: state.playhead,
            onPlace: onPlace,
            onSeek: widget.onSeek,
            onQuickConfirm: onConfirm,
          ),
          const SizedBox(height: 8),
          WaveformOverview(
            key: const ValueKey('manual-waveform-overview'),
            height: 32,
            bars: bars,
            duration: ai.durationSec,
            windowStart: _zoomStart,
            windowEnd: _zoomEnd ?? ai.durationSec,
            onWindowStart: (start) => setState(() {
              final span = (_zoomEnd ?? ai.durationSec) - _zoomStart;
              _zoomStart = start;
              _zoomEnd = start + span;
            }),
          ),
        ],
      ),
    ).tourAnchor('waveform');
  }

  List<Widget> _transportActions(BuildContext context) => [
    RmButton(
      key: const ValueKey('manual-use-playhead'),
      onPressed: widget.onMarkPlayback,
      label: '取播放位置',
    ),
    _manualAuditionButton(context),
    const AuditionSettingsButton(compact: true).tourAnchor('audition'),
    if (session.kind.isLoop) _endpointToggle(context),
  ];

  Widget _manualAuditionButton(BuildContext context) {
    final isLoop = session.kind.isLoop;
    return RmButton(
      key: ValueKey(
        isLoop ? 'manual-refine-loop-preview' : 'manual-refine-point-preview',
      ),
      onPressed: onAudition,
      size: RmButtonSize.md,
      leading: RmIcon(isLoop ? 'loop' : 'play', size: 12),
      label: isLoop ? '试听拼接' : '试听',
    );
  }

  /// A/B 端点切换，放在传输条行尾，对应当前正在放置的循环端点。
  Widget _endpointToggle(BuildContext context) {
    final rm = context.rm;
    final acc = groupAccent(rm, session.kind);
    Widget seg(String label, FineTarget target) {
      final on = session.activeTarget == target;
      return GestureDetector(
        onTap: () => onPickTarget(target),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
          decoration: BoxDecoration(
            color: on ? acc.base : Colors.transparent,
            borderRadius: BorderRadius.circular(5),
          ),
          child: Text(
            label,
            style: RmText.mono(
              11,
              weight: FontWeight.w700,
              color: on ? Colors.white : rm.fg3,
            ),
          ),
        ),
      );
    }

    return Container(
      height: 32,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: rm.raised,
        border: Border.all(color: rm.border),
        borderRadius: BorderRadius.circular(RmTokens.rSm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          seg('端点 A', FineTarget.loopStart),
          seg('端点 B', FineTarget.loopEnd),
        ],
      ),
    );
  }

  Widget _finePanel(BuildContext context) {
    final rm = context.rm;
    return Container(
      key: const ValueKey('manual-refine-fine-panel'),
      decoration: BoxDecoration(
        color: rm.panel,
        border: Border.all(color: rm.border),
        borderRadius: BorderRadius.circular(RmTokens.rLg),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          children: [
            if (session.kind.isLoop) ...[
              _fineRow(
                context,
                label: 'A · start',
                value: session.start,
                target: FineTarget.loopStart,
                active: session.activeTarget == FineTarget.loopStart,
              ),
              const SizedBox(height: 8),
              _fineRow(
                context,
                label: 'B · end',
                value: session.end,
                target: FineTarget.loopEnd,
                active: session.activeTarget == FineTarget.loopEnd,
              ),
            ] else
              _fineRow(
                context,
                label: '播放起点',
                value: session.pointTime,
                target: FineTarget.point,
                active: true,
              ),
            const SizedBox(height: 8),
            _metaRow(context),
          ],
        ),
      ),
    ).tourAnchor('values');
  }

  Widget _fineRow(
    BuildContext context, {
    required String label,
    required double value,
    required FineTarget target,
    required bool active,
  }) {
    final rm = context.rm;
    final acc = groupAccent(rm, session.kind);
    final beat = state.ai.bpm <= 0 ? 0.5 : 60 / state.ai.bpm;
    final sampleRate = session.kind.sampleRate;
    return MouseRegion(
      cursor: session.kind.isLoop
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: session.kind.isLoop ? () => onPickTarget(target) : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: active ? acc.bg : rm.raised,
            border: Border.all(color: active ? acc.base : rm.border),
            borderRadius: BorderRadius.circular(RmTokens.rSm),
          ),
          // 单行：标签在左 · 大时间码居中 · 微调按钮成组靠右。
          child: Row(
            children: [
              SizedBox(
                width: 154,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _fineLabel(context, label, active),
                    const SizedBox(height: 4),
                    Text(
                      '= ${formatSamples(value, sampleRate)} samples',
                      style: RmText.mono(10, color: rm.fg4),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TimeInputField(
                      key: ValueKey('manual-time-${target.name}'),
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      textAlign: TextAlign.center,
                      seconds: value,
                      onCommit: (seconds) {
                        if (seconds > state.ai.durationSec) {
                          throw const FormatException('时间必须位于歌曲范围内');
                        }
                        if (session.kind.isLoop &&
                            (target == FineTarget.loopStart
                                ? seconds >= session.end
                                : seconds <= session.start)) {
                          throw const FormatException('循环结束必须晚于开始');
                        }
                        onNudge(target, seconds - value);
                      },
                    ),
                    const SizedBox(height: 1),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _nudgePair(context, target, beat, '−拍', '+拍', beatUnit: true),
              const SizedBox(width: 8),
              _nudgePair(context, target, 0.010, '−10', '+10', beatUnit: false),
            ],
          ),
        ),
      ),
    );
  }

  /// 一组微调按钮（减 / 加），ms 组在后面补一个单位标签。
  Widget _nudgePair(
    BuildContext context,
    FineTarget target,
    double delta,
    String minus,
    String plus, {
    required bool beatUnit,
  }) {
    return EditorNudgePair(
      minus: minus,
      plus: plus,
      unit: beatUnit ? null : 'ms',
      onMinus: () => onNudge(target, -delta),
      onPlus: () => onNudge(target, delta),
    );
  }

  Widget _fineLabel(BuildContext context, String label, bool active) {
    final rm = context.rm;
    final acc = groupAccent(rm, session.kind);
    return Row(
      children: [
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(
            color: active ? acc.base : rm.fg4,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            label,
            style: RmText.mono(
              12,
              weight: FontWeight.w700,
              color: active ? rm.fg : rm.fg2,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  /// 元信息（BPM / 1 拍 / 磁吸 / Δ）。试听入口在传输条行尾。
  Widget _metaRow(BuildContext context) {
    final rm = context.rm;
    final beatMs = state.ai.bpm <= 0 ? 0 : 60 / state.ai.bpm * 1000;
    return Row(
      children: [
        Expanded(
          child: Wrap(
            spacing: 14,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _meta(context, 'BPM', state.ai.bpm.toStringAsFixed(1)),
              _meta(context, '1 拍', '${beatMs.round()}ms'),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('磁吸 ', style: RmText.mono(11, color: rm.fg3)),
                  Text(
                    snapActive ? 'downbeat' : 'off',
                    style: RmText.mono(
                      11,
                      color: snapActive
                          ? groupAccent(rm, session.kind).base
                          : rm.fg4,
                    ),
                  ),
                ],
              ),
              if (session.kind.isLoop)
                _meta(
                  context,
                  'Δ',
                  '${(session.end - session.start).toStringAsFixed(3)}s',
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _meta(BuildContext context, String label, String value) {
    final rm = context.rm;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label ', style: RmText.mono(11, color: rm.fg3)),
        Text(value, style: RmText.mono(11, color: rm.fg)),
      ],
    );
  }

  Widget _aiApplyPanel(BuildContext context) {
    final rm = context.rm;
    final acc = groupAccent(rm, session.kind);
    return Container(
      key: const ValueKey('manual-refine-ai-panel'),
      decoration: BoxDecoration(
        color: rm.raised,
        border: Border.all(color: rm.border),
        borderRadius: BorderRadius.circular(RmTokens.rLg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 11, 12, 10),
            child: Row(
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: acc.base,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    seamless ? '套用循环建议' : '套用 AI 建议',
                    style: RmText.sans(
                      13,
                      weight: FontWeight.w700,
                      color: rm.fg,
                    ),
                  ),
                ),
                Text(
                  '${aiCandidates.length} 个',
                  style: RmText.mono(11, color: rm.fg3),
                ),
              ],
            ),
          ),
          Container(height: 1, color: rm.border),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.all(10),
              itemCount: aiCandidates.length,
              separatorBuilder: (_, _) => const SizedBox(height: 6),
              itemBuilder: (context, i) {
                return _aiCandidateRow(context, i, aiCandidates[i]);
              },
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(12, 9, 12, 10),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: rm.border)),
            ),
            child: Text(
              seamless
                  ? 'SeamlessLoopMusic 衔接匹配；套用后请试听，仍可手动微调。'
                  : '套用后仍可继续点波形或微调；AI 只是起点。',
              style: RmText.sans(11.5, color: rm.fg3, height: 1.3),
            ),
          ),
        ],
      ),
    ).tourAnchor('suggestions');
  }

  Widget _aiCandidateRow(BuildContext context, int index, dynamic candidate) {
    final rm = context.rm;
    final acc = groupAccent(rm, session.kind);
    final selected = session.matches(candidate);
    // 整张卡片即点选区域，去掉单独的「套用」按钮。
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        key: ValueKey('manual-refine-ai-apply-$index'),
        onTap: () => onApplyCandidate(candidate),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? acc.bg : rm.panel,
            border: Border.all(color: selected ? acc.base : rm.border),
            borderRadius: BorderRadius.circular(RmTokens.rSm),
          ),
          child: Row(
            children: [
              Container(
                width: 20,
                height: 20,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: selected ? acc.base : rm.raised,
                  border: Border.all(
                    color: selected ? acc.base : rm.borderStrong,
                  ),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  '${index + 1}',
                  style: RmText.mono(
                    10.5,
                    color: selected ? Colors.white : rm.fg2,
                  ),
                ),
              ),
              const SizedBox(width: 9),
              Expanded(child: _candidateText(context, candidate)),
              if (selected) ...[
                const SizedBox(width: 8),
                RmIcon('check', size: 12, color: acc.base),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _candidateText(BuildContext context, dynamic candidate) {
    final rm = context.rm;
    if (candidate is LoopCandidate) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${formatEditorTimecode(candidate.start)} → ${formatEditorTimecode(candidate.end)}',
                  style: RmText.mono(13, weight: FontWeight.w700, color: rm.fg),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                seamless
                    ? '${(candidate.end - candidate.start).toStringAsFixed(1)} s'
                    : '${candidate.bars} 小节',
                style: RmText.mono(9.5, color: rm.fg4),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            candidate.why,
            style: RmText.sans(11, color: rm.fg3),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          if (seamless && !candidate.why.startsWith('SeamlessLoopMusic'))
            Text('当前点位 · 未评估衔接', style: RmText.sans(10.5, color: rm.fg4))
          else
            _confidenceBar(context, candidate.score),
        ],
      );
    }
    final point = candidate as PointCandidate;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          formatEditorTimecode(point.t),
          style: RmText.mono(13, weight: FontWeight.w700, color: rm.fg),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 2),
        Text(
          point.why,
          style: RmText.sans(11, color: rm.fg3),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 4),
        _confidenceBar(context, point.score),
      ],
    );
  }

  /// 置信度迷你条 —— 42px 轨道按 score 填充 + 百分比。
  Widget _confidenceBar(BuildContext context, double score) {
    final rm = context.rm;
    final acc = groupAccent(rm, session.kind);
    final pct = score.clamp(0.0, 1.0);
    return Row(
      children: [
        Container(
          width: 42,
          height: 4,
          decoration: BoxDecoration(
            color: rm.border,
            borderRadius: BorderRadius.circular(2),
          ),
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: pct,
            child: Container(
              decoration: BoxDecoration(
                color: acc.base,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
        const SizedBox(width: 7),
        Text(
          '${(pct * 100).round()}%',
          style: RmText.mono(10.5, color: rm.fg3),
        ),
      ],
    );
  }

  Widget _footer(BuildContext context) {
    final rm = context.rm;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Container(
            key: const ValueKey('manual-refine-footer-divider'),
            height: 1,
            color: rm.border,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
          child: Row(
            children: [
              Expanded(
                child: EditorShortcutHints(
                  hints: widget.shortcutHint.split(' · '),
                ),
              ),
              const SizedBox(width: 12),
              RmButton(onPressed: onCancel, label: '取消'),
              const SizedBox(width: 10),
              RmButton(
                onPressed: onConfirm,
                variant: RmButtonVariant.primary,
                leading: const RmIcon('check', size: 12),
                label: '确认选点',
              ),
            ],
          ),
        ),
      ],
    ).tourAnchor('confirm');
  }

  Widget _statusPill(BuildContext context) {
    final rm = context.rm;
    final dotColor = snapActive ? RmTokens.trafficGreen : rm.warn;
    final label = snapActive ? '磁吸到拍' : '自由放置';
    return GestureDetector(
      key: const ValueKey('manual-toggle-snap'),
      onTap: widget.onToggleSnap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
        decoration: BoxDecoration(
          color: snapActive ? rm.raised : rm.warnBg,
          border: Border.all(color: snapActive ? rm.border : rm.warn),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                color: dotColor,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 7),
            Text(
              label,
              style: RmText.sans(12, color: snapActive ? rm.fg3 : rm.warn),
            ),
          ],
        ),
      ),
    );
  }
}

class _ManualRefineSession {
  const _ManualRefineSession({
    required this.kind,
    required this.pointTime,
    required this.start,
    required this.end,
    required this.activeTarget,
  });

  factory _ManualRefineSession.fromState(
    ReplaceEditorState state,
    GroupKind kind,
  ) {
    if (kind.isLoop) {
      final current = switch (kind) {
        GroupKind.tl =>
          state.selectedManualOf(kind) ? state.tlManual! : state.tl,
        GroupKind.pl =>
          state.selectedManualOf(kind) ? state.plManual! : state.pl,
        GroupKind.td || GroupKind.pd => state.tl,
      };
      return _ManualRefineSession(
        kind: kind,
        pointTime: current.start,
        start: current.start,
        end: current.end,
        activeTarget: FineTarget.loopStart,
      );
    }
    final current = switch (kind) {
      GroupKind.td => state.selectedManualOf(kind) ? state.tdManual! : state.td,
      GroupKind.pd => state.selectedManualOf(kind) ? state.pdManual! : state.pd,
      GroupKind.tl || GroupKind.pl => state.td,
    };
    return _ManualRefineSession(
      kind: kind,
      pointTime: current.t,
      start: current.t,
      end: current.t,
      activeTarget: FineTarget.point,
    );
  }

  final GroupKind kind;
  final double pointTime;
  final double start;
  final double end;
  final FineTarget activeTarget;

  double get focusTime {
    if (!kind.isLoop) return pointTime;
    return activeTarget == FineTarget.loopEnd ? end : start;
  }

  _ManualRefineSession copyWith({
    double? pointTime,
    double? start,
    double? end,
    FineTarget? activeTarget,
  }) {
    return _ManualRefineSession(
      kind: kind,
      pointTime: pointTime ?? this.pointTime,
      start: start ?? this.start,
      end: end ?? this.end,
      activeTarget: activeTarget ?? this.activeTarget,
    );
  }

  _ManualRefineSession placeAt(double seconds, {required double duration}) {
    if (!kind.isLoop) {
      return copyWith(pointTime: _clampTime(seconds, duration));
    }
    if (activeTarget == FineTarget.loopEnd) {
      return _withLoop(end: seconds, duration: duration);
    }
    return _withLoop(start: seconds, duration: duration);
  }

  _ManualRefineSession nudge(
    FineTarget target,
    double deltaSec, {
    required double duration,
  }) {
    if (!kind.isLoop) {
      return copyWith(
        pointTime: _clampTime(pointTime + deltaSec, duration),
        activeTarget: FineTarget.point,
      );
    }
    if (target == FineTarget.loopEnd) {
      return _withLoop(
        end: end + deltaSec,
        duration: duration,
        activeTarget: target,
      );
    }
    return _withLoop(
      start: start + deltaSec,
      duration: duration,
      activeTarget: FineTarget.loopStart,
    );
  }

  _ManualRefineSession fromCandidate(
    dynamic candidate, {
    required double duration,
  }) {
    if (candidate is LoopCandidate) {
      return _withLoop(
        start: candidate.start,
        end: candidate.end,
        duration: duration,
        activeTarget: FineTarget.loopStart,
      );
    }
    final point = candidate as PointCandidate;
    return copyWith(
      pointTime: _clampTime(point.t, duration),
      start: _clampTime(point.t, duration),
      end: _clampTime(point.t, duration),
      activeTarget: FineTarget.point,
    );
  }

  bool matches(dynamic candidate) {
    const epsilon = 0.001;
    if (candidate is LoopCandidate) {
      return (candidate.start - start).abs() < epsilon &&
          (candidate.end - end).abs() < epsilon;
    }
    final point = candidate as PointCandidate;
    return (point.t - pointTime).abs() < epsilon;
  }

  _ManualRefineSession _withLoop({
    double? start,
    double? end,
    required double duration,
    FineTarget? activeTarget,
  }) {
    const minGap = 0.05;
    final safeDuration = math.max(0.0, duration);
    if (safeDuration <= minGap) {
      return copyWith(
        start: 0,
        end: safeDuration,
        pointTime: 0,
        activeTarget: activeTarget ?? this.activeTarget,
      );
    }
    var nextStart = _clampTime(start ?? this.start, safeDuration);
    var nextEnd = _clampTime(end ?? this.end, safeDuration);
    final target = activeTarget ?? this.activeTarget;
    if (nextEnd - nextStart < minGap) {
      if (target == FineTarget.loopEnd) {
        nextEnd = math.min(safeDuration, nextStart + minGap);
        nextStart = math.min(nextStart, nextEnd - minGap);
      } else {
        nextStart = math.max(0, nextEnd - minGap);
        nextEnd = math.max(nextEnd, nextStart + minGap);
      }
    }
    return copyWith(
      start: nextStart,
      end: nextEnd,
      pointTime: target == FineTarget.loopEnd ? nextEnd : nextStart,
      activeTarget: target,
    );
  }

  static double _clampTime(double seconds, double duration) {
    return seconds.clamp(0, math.max(0.0, duration)).toDouble();
  }
}

int _barsForManual(double start, double end, double bpm) {
  final beat = bpm <= 0 ? 0.5 : 60 / bpm;
  return ((end - start) / beat / 4).round().clamp(1, 128).toInt();
}

class _PreviewRange {
  const _PreviewRange({
    required this.start,
    required this.end,
    required this.loop,
    this.playerManagedLoop = false,
  });

  final double start;
  final double end;
  final bool loop;
  final bool playerManagedLoop;

  _PreviewRange withPlayerManagedLoop() {
    return _PreviewRange(
      start: start,
      end: end,
      loop: loop,
      playerManagedLoop: true,
    );
  }
}
