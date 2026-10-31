import '../../core/waveform_zoom.dart';
import '../../core/playback_window.dart';
import 'dart:async';
import '../../state/seamless_loop_state.dart';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/track_timing_config.dart';
import '../../domain/radio_library.dart';
import '../../domain/replacement_models.dart';
import '../../state/audio_analysis_state.dart';
import '../../state/custom_pool_tracks.dart';
import '../../state/track_timing_state.dart';
import '../../state/editor_options.dart';
import '../../state/unsaved_edits.dart';
import '../../state/studio_state.dart';
import '../../core/fh_radio_studio_cli.dart';
import '../../widgets/time_input_field.dart';
import '../../core/waveform_service.dart';

enum PlaybackMode { idle, full, pointPreview, loopPreview }

@immutable
class ReplaceEditorState {
  const ReplaceEditorState({
    required this.trackId,
    required this.track,
    required this.ai,
    required this.tdIdx,
    required this.pdIdx,
    required this.tlIdx,
    required this.plIdx,
    required this.tdConfirmed,
    required this.pdConfirmed,
    required this.tlConfirmed,
    required this.plConfirmed,
    this.tdManual,
    this.pdManual,
    this.tlManual,
    this.plManual,
    required this.playing,
    required this.playhead,
    required this.zoomStart,
    required this.zoomEnd,
    required this.activeGroup,
    required this.playbackMode,
    required this.analyzing,
    required this.dirty,
    required this.saved,
    this.error,
    this.bpmManual = false,
  });

  factory ReplaceEditorState.initial({
    required String trackId,
    required PoolTrack track,
    required AiResult ai,
    TrackTimingConfig? config,
  }) {
    final initialAi = config == null ? ai : _applyConfig(ai, config);
    return ReplaceEditorState(
      trackId: trackId,
      track: track,
      ai: initialAi,
      tdIdx: 0,
      pdIdx: 0,
      tlIdx: 0,
      plIdx: 0,
      tdConfirmed: config?.confirmed['td'] ?? track.confirmed >= 1,
      pdConfirmed: config?.confirmed['pd'] ?? track.confirmed >= 2,
      tlConfirmed: config?.confirmed['tl'] ?? track.confirmed >= 3,
      plConfirmed: config?.confirmed['pl'] ?? track.confirmed >= 4,
      playing: false,
      playhead: 0,
      zoomStart: 0,
      zoomEnd: initialAi.durationSec,
      activeGroup: GroupKind.td,
      playbackMode: PlaybackMode.idle,
      analyzing: track.id.startsWith('real:') && config == null,
      dirty: false,
      saved: config != null,
      bpmManual: config?.bpmManual ?? false,
    );
  }

  final String trackId;
  final PoolTrack track;
  final AiResult ai;
  final int tdIdx;
  final int pdIdx;
  final int tlIdx;
  final int plIdx;
  final bool tdConfirmed;
  final bool pdConfirmed;
  final bool tlConfirmed;
  final bool plConfirmed;
  final PointCandidate? tdManual;
  final PointCandidate? pdManual;
  final LoopCandidate? tlManual;
  final LoopCandidate? plManual;
  final bool playing;
  final double playhead;
  final double zoomStart;
  final double zoomEnd;
  final GroupKind activeGroup;
  final PlaybackMode playbackMode;
  final bool analyzing;
  final bool dirty;
  final bool saved;
  final bool bpmManual;
  final String? error;

  PointCandidate get td => selectedManualOf(GroupKind.td)
      ? tdManual!
      : ai.td[_idx(tdIdx, ai.td.length)];
  PointCandidate get pd => selectedManualOf(GroupKind.pd)
      ? pdManual!
      : ai.pd[_idx(pdIdx, ai.pd.length)];
  LoopCandidate get tl => selectedManualOf(GroupKind.tl)
      ? tlManual!
      : ai.tl[_idx(tlIdx, ai.tl.length)];
  LoopCandidate get pl => selectedManualOf(GroupKind.pl)
      ? plManual!
      : ai.pl[_idx(plIdx, ai.pl.length)];

  bool get allConfirmed =>
      tdConfirmed && pdConfirmed && tlConfirmed && plConfirmed;

  bool get aiPending => analyzing && error == null;

  int get doneCount =>
      (tdConfirmed ? 1 : 0) +
      (pdConfirmed ? 1 : 0) +
      (tlConfirmed ? 1 : 0) +
      (plConfirmed ? 1 : 0);

  bool confirmedOf(GroupKind k) => switch (k) {
    GroupKind.td => tdConfirmed,
    GroupKind.pd => pdConfirmed,
    GroupKind.tl => tlConfirmed,
    GroupKind.pl => plConfirmed,
  };

  int selectedIdxOf(GroupKind k) => switch (k) {
    GroupKind.td => tdIdx,
    GroupKind.pd => pdIdx,
    GroupKind.tl => tlIdx,
    GroupKind.pl => plIdx,
  };

  int aiCandidateCountOf(GroupKind k) => switch (k) {
    GroupKind.td => ai.td.length,
    GroupKind.pd => ai.pd.length,
    GroupKind.tl => ai.tl.length,
    GroupKind.pl => ai.pl.length,
  };

  dynamic manualCandidateOf(GroupKind k) => switch (k) {
    GroupKind.td => tdManual,
    GroupKind.pd => pdManual,
    GroupKind.tl => tlManual,
    GroupKind.pl => plManual,
  };

  bool hasManualOf(GroupKind k) => manualCandidateOf(k) != null;

  int manualIndexOf(GroupKind k) => aiCandidateCountOf(k);

  bool selectedManualOf(GroupKind k) {
    return hasManualOf(k) && selectedIdxOf(k) == manualIndexOf(k);
  }

  bool selectableIdxOf(GroupKind k, int idx) {
    if (idx < 0) return false;
    return idx < aiCandidateCountOf(k) + (hasManualOf(k) ? 1 : 0);
  }

  Map<String, double> get markerSeconds => {
    'TrackDrop': td.t,
    'PostDrop': pd.t,
    'TrackLoopStart': tl.start,
    'TrackLoopEnd': tl.end,
    'PostRaceLoopStart': pl.start,
    'PostRaceLoopEnd': pl.end,
  };

  Map<String, bool> get confirmedGroups => {
    'td': tdConfirmed,
    'pd': pdConfirmed,
    'tl': tlConfirmed,
    'pl': plConfirmed,
  };

  ReplaceEditorState copyWith({
    PoolTrack? track,
    AiResult? ai,
    int? tdIdx,
    int? pdIdx,
    int? tlIdx,
    int? plIdx,
    bool? tdConfirmed,
    bool? pdConfirmed,
    bool? tlConfirmed,
    bool? plConfirmed,
    Object? tdManual = _sentinel,
    Object? pdManual = _sentinel,
    Object? tlManual = _sentinel,
    Object? plManual = _sentinel,
    bool? playing,
    double? playhead,
    double? zoomStart,
    double? zoomEnd,
    GroupKind? activeGroup,
    PlaybackMode? playbackMode,
    bool? analyzing,
    bool? dirty,
    bool? saved,
    bool? bpmManual,
    Object? error = _sentinel,
  }) {
    final nextAi = ai ?? this.ai;
    final nextTdManual = identical(tdManual, _sentinel)
        ? this.tdManual
        : tdManual as PointCandidate?;
    final nextPdManual = identical(pdManual, _sentinel)
        ? this.pdManual
        : pdManual as PointCandidate?;
    final nextTlManual = identical(tlManual, _sentinel)
        ? this.tlManual
        : tlManual as LoopCandidate?;
    final nextPlManual = identical(plManual, _sentinel)
        ? this.plManual
        : plManual as LoopCandidate?;
    return ReplaceEditorState(
      trackId: trackId,
      track: track ?? this.track,
      ai: nextAi,
      tdIdx: _idxWithManual(
        tdIdx ?? this.tdIdx,
        nextAi.td.length,
        nextTdManual != null,
      ),
      pdIdx: _idxWithManual(
        pdIdx ?? this.pdIdx,
        nextAi.pd.length,
        nextPdManual != null,
      ),
      tlIdx: _idxWithManual(
        tlIdx ?? this.tlIdx,
        nextAi.tl.length,
        nextTlManual != null,
      ),
      plIdx: _idxWithManual(
        plIdx ?? this.plIdx,
        nextAi.pl.length,
        nextPlManual != null,
      ),
      tdConfirmed: tdConfirmed ?? this.tdConfirmed,
      pdConfirmed: pdConfirmed ?? this.pdConfirmed,
      tlConfirmed: tlConfirmed ?? this.tlConfirmed,
      plConfirmed: plConfirmed ?? this.plConfirmed,
      tdManual: nextTdManual,
      pdManual: nextPdManual,
      tlManual: nextTlManual,
      plManual: nextPlManual,
      playing: playing ?? this.playing,
      playhead: (playhead ?? this.playhead).clamp(0, nextAi.durationSec),
      zoomStart: (zoomStart ?? this.zoomStart).clamp(0, nextAi.durationSec),
      zoomEnd: (zoomEnd ?? this.zoomEnd).clamp(0, nextAi.durationSec),
      activeGroup: activeGroup ?? this.activeGroup,
      playbackMode: playbackMode ?? this.playbackMode,
      analyzing: analyzing ?? this.analyzing,
      dirty: dirty ?? this.dirty,
      saved: saved ?? this.saved,
      bpmManual: bpmManual ?? this.bpmManual,
      error: identical(error, _sentinel) ? this.error : error as String?,
    );
  }
}

class ReplaceEditorNotifier extends StateNotifier<ReplaceEditorState> {
  ReplaceEditorNotifier(
    this.ref,
    super.state,
    TrackTimingConfig? initialConfig,
    this._analysisController,
  ) {
    _savedState = state;
    _edits = ref.read(unsavedEditsProvider);
    _entry = PendingEdit(
      label: state.track.title,
      dirty: () =>
          mounted &&
          (state.dirty ||
              TimeInputValidation.drafts.isNotEmpty ||
              TimeInputValidation.invalid.isNotEmpty ||
              (pendingManualDirty?.call() ?? false)),
      save: () {
        saveToProject();
      },
      discard: () {
        discardManualDraft?.call();
        super.state = _savedState;
      },
    );
    _edits.entries['editor'] = _entry;
  }

  late final UnsavedEdits _edits;
  late final PendingEdit _entry;
  late ReplaceEditorState _savedState;
  final Ref ref;
  final AudioAnalysisController _analysisController;
  final List<ReplaceEditorState> _history = [];
  final List<ReplaceEditorState> _redoHistory = [];
  bool Function()? pendingManualDirty;
  VoidCallback? commitManualDraft;
  VoidCallback? discardManualDraft;

  @override
  set state(ReplaceEditorState value) {
    final old = super.state;
    if (syncingPostLoop &&
        (value.tl.start != old.tl.start ||
            value.tl.end != old.tl.end ||
            value.tlConfirmed != old.tlConfirmed)) {
      value = value.copyWith(
        plManual: value.tl,
        plIdx: value.ai.pl.length,
        plConfirmed: value.tlConfirmed,
      );
    }
    super.state = value;
  }

  // A temporary override belongs to this editor session, never the project setting.
  bool postLoopSyncPaused = false;
  bool get syncingPostLoop =>
      ref.read(editorOptionsProvider).syncPostLoop && !postLoopSyncPaused;
  void setPostLoopSyncPaused(bool paused) {
    postLoopSyncPaused = paused;
    if (!paused) {
      syncPostLoopFromTrackLoop();
    } else {
      super.state = state.copyWith();
    }
  }

  void syncPostLoopFromTrackLoop() {
    if (state.pl.start == state.tl.start &&
        state.pl.end == state.tl.end &&
        state.plConfirmed == state.tlConfirmed) {
      super.state = state.copyWith();
      return;
    }
    applyManualLoop(
      GroupKind.pl,
      state.tl.start,
      state.tl.end,
      confirm: state.tlConfirmed,
    );
  }

  // Saving refreshes library metadata without discarding decoded audio or drafts.
  void refreshTrackMetadata(PoolTrack track) {
    if (!mounted || track.source != state.track.source) return;
    super.state = state.copyWith(track: track);
    _savedState = _savedState.copyWith(track: track);
  }

  void setBpm(double bpm) {
    if (!bpm.isFinite || bpm < 20 || bpm > 400) {
      throw const FormatException('BPM 必须在 20–400 之间');
    }
    if (state.bpmManual && state.ai.bpm == bpm) return;
    _remember();
    state = state.copyWith(
      ai: _withManualBpm(state.ai, bpm),
      bpmManual: true,
      tlManual: state.tlManual?.copyWith(
        bars: _barsFor(state.tlManual!.start, state.tlManual!.end, bpm),
      ),
      plManual: state.plManual?.copyWith(
        bars: _barsFor(state.plManual!.start, state.plManual!.end, bpm),
      ),
      dirty: true,
    );
  }

  void editTime(GroupKind kind, FineTarget target, double seconds) {
    if (!seconds.isFinite || seconds < 0 || seconds > state.ai.durationSec) {
      throw const FormatException('时间必须位于歌曲范围内');
    }
    if (kind.isLoop) {
      final current = kind == GroupKind.tl ? state.tl : state.pl;
      final start = target == FineTarget.loopStart ? seconds : current.start;
      final end = target == FineTarget.loopEnd ? seconds : current.end;
      if (end <= start) throw const FormatException('循环结束必须晚于开始');
      applyManualLoop(kind, start, end, confirm: false);
    } else {
      applyManualPoint(kind, seconds, confirm: false);
    }
  }

  CliCancellationToken? _waveformToken;
  Future<void> loadWaveform({bool withLoops = true}) async {
    final studio = ref.read(studioProvider);
    final token = _waveformToken = CliCancellationToken();
    try {
      final payload = await WaveformService.load(
        project: studio.projectDir,
        repoRoot: studio.repoRoot,
        source: state.track.source,
        token: token,
      );
      if (!mounted || token.isCancelled) return;
      final waveform = AudioAnalysisResult.fromJson(payload);
      state = state.copyWith(
        ai: state.ai.copyWith(
          durationSec: waveform.durationSec,
          waveformPeaks: _waveformDisplayValues(waveform.waveform),
          beats: state.bpmManual
              ? _withManualBpm(
                  state.ai.copyWith(durationSec: waveform.durationSec),
                  state.ai.bpm,
                ).beats
              : waveform.beats.isNotEmpty
              ? waveform.beats
              : state.ai.beats.isNotEmpty
              ? state.ai.beats
              : (state.track.bpm > 0 || state.saved)
              ? _genBeats(waveform.durationSec, state.ai.bpm)
              : const [],
          segments: state.ai.segments.isNotEmpty
              ? state.ai.segments
              : [
                  for (final segment in waveform.segments)
                    if (segment.end > segment.start)
                      Segment(
                        start: segment.start,
                        end: segment.end,
                        label: segment.label,
                      ),
                ],
          sourceSampleRate: waveform.sampleRate,
          sourceSamples: waveform.samples,
        ),
      );
      _savedState = _savedState.copyWith(
        ai: _savedState.ai.copyWith(
          durationSec: waveform.durationSec,
          waveformPeaks: state.ai.waveformPeaks,
          beats: _savedState.bpmManual
              ? _withManualBpm(
                  _savedState.ai.copyWith(durationSec: waveform.durationSec),
                  _savedState.ai.bpm,
                ).beats
              : _savedState.ai.beats,
          segments: state.ai.segments,
          sourceSampleRate: waveform.sampleRate,
          sourceSamples: waveform.samples,
        ),
      );
      if (withLoops && ref.read(editorOptionsProvider).slmEnabled) {
        await analyzeSeamless();
      }
    } on Object catch (error) {
      if (mounted && !token.isCancelled) {
        state = state.copyWith(error: '$error', analyzing: false);
      }
    }
  }

  Future<void> analyze({bool force = false}) async {
    if (ref.read(editorOptionsProvider).manualOnly) {
      await loadWaveform(withLoops: false);
      if (mounted && ref.read(editorOptionsProvider).slmEnabled) {
        await analyzeSeamless(force: force);
      }
      return;
    }
    final path = pathFromRealTrackId(state.trackId) ?? state.track.source;
    if (path.trim().isEmpty) return;
    state = state.copyWith(analyzing: true, error: null);
    final result = await ref.read(audioAnalysisProvider.notifier).analyze(path);
    if (!mounted) return;
    final analysis = ref.read(audioAnalysisProvider);
    if (analysis.error != null) {
      state = state.copyWith(analyzing: false, error: analysis.error);
      return;
    }
    if (result == null) {
      state = state.copyWith(analyzing: false);
      return;
    }

    var nextAi = _aiFromAnalysis(result);
    if (state.ai.waveformPeaks.length > nextAi.waveformPeaks.length) {
      nextAi = nextAi.copyWith(waveformPeaks: state.ai.waveformPeaks);
    }
    if (state.dirty || state.saved) {
      if (ref.read(editorOptionsProvider).slmEnabled) {
        nextAi = nextAi.copyWith(
          tl: _nativeLoopsWithCurrent(state.tl, nextAi.tl),
          pl: _nativeLoopsWithCurrent(state.pl, nextAi.pl),
        );
      }
      nextAi = _applyCurrentMarkers(nextAi, state);
    }
    if (state.bpmManual) nextAi = _withManualBpm(nextAi, state.ai.bpm);
    state = state.copyWith(
      ai: nextAi,
      tlIdx: ref.read(editorOptionsProvider).slmEnabled
          ? (state.selectedManualOf(GroupKind.tl) ? nextAi.tl.length : 0)
          : state.tlIdx,
      plIdx: ref.read(editorOptionsProvider).slmEnabled
          ? (state.selectedManualOf(GroupKind.pl) ? nextAi.pl.length : 0)
          : state.plIdx,
      analyzing: false,
      dirty: force ? true : state.dirty,
      saved: force ? false : state.saved,
      error: null,
      zoomStart: 0,
      zoomEnd: nextAi.durationSec,
    );
    if (pathFromRealTrackId(state.trackId) != null &&
        state.ai.waveformPeaks.length < WaveformService.detailedBins) {
      await loadWaveform(withLoops: false);
    }
  }

  CliCancellationToken? _seamlessToken;
  Future<void> analyzeSeamless({bool force = false}) async {
    if (!ref.read(editorOptionsProvider).slmEnabled) return;
    final studio = ref.read(studioProvider);
    final token = _seamlessToken = CliCancellationToken();
    state = state.copyWith(analyzing: true, error: null);
    try {
      final loops = await ref.read(seamlessLoopLoaderProvider)(
        studio.repoRoot,
        studio.projectDir,
        state.track.source,
        token,
        force,
      );
      if (!mounted ||
          token.isCancelled ||
          !ref.read(editorOptionsProvider).slmEnabled) {
        return;
      }
      final keep =
          state.saved || state.dirty || state.tlConfirmed || state.plConfirmed;
      final nextAi = state.ai.copyWith(
        tl: keep ? _nativeLoopsWithCurrent(state.tl, loops) : loops,
        pl: keep ? _nativeLoopsWithCurrent(state.pl, loops) : loops,
      );
      final next = state.copyWith(
        ai: nextAi,
        analyzing: false,
        error: null,
        tlIdx: state.selectedManualOf(GroupKind.tl) ? nextAi.tl.length : 0,
        plIdx: state.selectedManualOf(GroupKind.pl) ? nextAi.pl.length : 0,
      );
      state = next;
      if (!state.dirty) {
        _savedState = _savedState.copyWith(
          ai: nextAi,
          tlIdx: next.tlIdx,
          plIdx: next.plIdx,
        );
      }
    } on Object catch (error) {
      if (mounted && !token.isCancelled) {
        state = state.copyWith(analyzing: false, error: '$error');
      }
    } finally {
      if (mounted && identical(_seamlessToken, token)) {
        state = state.copyWith(analyzing: false);
      }
    }
  }

  @override
  void dispose() {
    if (identical(_edits.entries['editor'], _entry)) {
      _edits.entries.remove('editor');
    }
    if (_seamlessToken != null) {
      unawaited(_seamlessToken!.cancel());
    }
    if (_waveformToken != null) {
      unawaited(_waveformToken!.cancel());
    }
    unawaited(_analysisController.cancel());
    super.dispose();
  }

  void selectCandidate(GroupKind kind, int idx) {
    if (state.confirmedOf(kind)) return;
    if (!state.selectableIdxOf(kind, idx)) return;
    _remember();
    state = switch (kind) {
      GroupKind.td => state.copyWith(
        tdIdx: idx,
        activeGroup: kind,
        dirty: true,
        saved: false,
      ),
      GroupKind.pd => state.copyWith(
        pdIdx: idx,
        activeGroup: kind,
        dirty: true,
        saved: false,
      ),
      GroupKind.tl => state.copyWith(
        tlIdx: idx,
        activeGroup: kind,
        dirty: true,
        saved: false,
      ),
      GroupKind.pl => state.copyWith(
        plIdx: idx,
        activeGroup: kind,
        dirty: true,
        saved: false,
      ),
    };
  }

  void setConfirmed(GroupKind kind, bool value) {
    _remember();
    state = switch (kind) {
      GroupKind.td => state.copyWith(
        tdConfirmed: value,
        activeGroup: kind,
        dirty: true,
        saved: false,
      ),
      GroupKind.pd => state.copyWith(
        pdConfirmed: value,
        activeGroup: kind,
        dirty: true,
        saved: false,
      ),
      GroupKind.tl => state.copyWith(
        tlConfirmed: value,
        activeGroup: kind,
        dirty: true,
        saved: false,
      ),
      GroupKind.pl => state.copyWith(
        plConfirmed: value,
        activeGroup: kind,
        dirty: true,
        saved: false,
      ),
    };
  }

  void confirmActive() {
    setConfirmed(state.activeGroup, true);
  }

  void setPlayhead(double t) {
    final view = pagedPlaybackWindow(
      duration: state.ai.durationSec,
      start: state.zoomStart,
      end: state.zoomEnd,
      playhead: t,
    );
    state = state.copyWith(
      playhead: t,
      zoomStart: state.playing ? view.start : null,
      zoomEnd: state.playing ? view.end : null,
    );
  }

  void togglePlay() {
    state = state.copyWith(playing: !state.playing);
  }

  void setPlaying(bool value) {
    state = state.copyWith(playing: value);
  }

  void setPlayback(PlaybackMode mode, {bool? playing}) {
    state = state.copyWith(playbackMode: mode, playing: playing);
  }

  void setError(String? message) {
    state = state.copyWith(error: message);
  }

  void seekRelative(double deltaSec) {
    setPlayhead(state.playhead + deltaSec);
  }

  void setActiveGroup(GroupKind kind) =>
      state = state.copyWith(activeGroup: kind);

  void jumpToSegment(int index) {
    if (index < 0 || index >= state.ai.segments.length) return;
    setPlayhead(state.ai.segments[index].start);
  }

  void nudge(GroupKind kind, FineTarget target, double deltaSec) {
    if (state.confirmedOf(kind)) return;
    _remember();
    final duration = state.ai.durationSec;
    double bound(double value) => value.clamp(0, duration).toDouble();

    switch (kind) {
      case GroupKind.td:
        if (state.selectedManualOf(kind)) {
          final current = state.tdManual!;
          state = state.copyWith(
            tdManual: current.copyWith(
              t: bound(current.t + deltaSec),
              why: '人工选点',
            ),
            activeGroup: kind,
            dirty: true,
            saved: false,
          );
          return;
        }
        final list = [...state.ai.td];
        list[state.tdIdx] = list[state.tdIdx].copyWith(
          t: bound(list[state.tdIdx].t + deltaSec),
          why: '手动微调',
        );
        state = state.copyWith(
          ai: state.ai.copyWith(td: list),
          activeGroup: kind,
          dirty: true,
          saved: false,
        );
      case GroupKind.pd:
        if (state.selectedManualOf(kind)) {
          final current = state.pdManual!;
          state = state.copyWith(
            pdManual: current.copyWith(
              t: bound(current.t + deltaSec),
              why: '人工选点',
            ),
            activeGroup: kind,
            dirty: true,
            saved: false,
          );
          return;
        }
        final list = [...state.ai.pd];
        list[state.pdIdx] = list[state.pdIdx].copyWith(
          t: bound(list[state.pdIdx].t + deltaSec),
          why: '手动微调',
        );
        state = state.copyWith(
          ai: state.ai.copyWith(pd: list),
          activeGroup: kind,
          dirty: true,
          saved: false,
        );
      case GroupKind.tl:
        if (state.selectedManualOf(kind)) {
          final current = state.tlManual!;
          final start = target == FineTarget.loopEnd
              ? current.start
              : bound(current.start + deltaSec);
          final end = target == FineTarget.loopStart
              ? current.end
              : bound(current.end + deltaSec);
          final nextStart = start.clamp(0, end - 0.05).toDouble();
          final nextEnd = end.clamp(nextStart + 0.05, duration).toDouble();
          state = state.copyWith(
            tlManual: current.copyWith(
              start: nextStart,
              end: nextEnd,
              bars: _barsFor(nextStart, nextEnd, state.ai.bpm),
              why: '人工选点',
            ),
            activeGroup: kind,
            dirty: true,
            saved: false,
          );
          return;
        }
        final list = [...state.ai.tl];
        final current = list[state.tlIdx];
        final start = target == FineTarget.loopEnd
            ? current.start
            : bound(current.start + deltaSec);
        final end = target == FineTarget.loopStart
            ? current.end
            : bound(current.end + deltaSec);
        final nextStart = start.clamp(0, end - 0.05).toDouble();
        final nextEnd = end.clamp(nextStart + 0.05, duration).toDouble();
        list[state.tlIdx] = current.copyWith(
          start: nextStart,
          end: nextEnd,
          bars: _barsFor(nextStart, nextEnd, state.ai.bpm),
          why: '手动微调',
        );
        state = state.copyWith(
          ai: state.ai.copyWith(tl: list),
          activeGroup: kind,
          dirty: true,
          saved: false,
        );
      case GroupKind.pl:
        if (state.selectedManualOf(kind)) {
          final current = state.plManual!;
          final start = target == FineTarget.loopEnd
              ? current.start
              : bound(current.start + deltaSec);
          final end = target == FineTarget.loopStart
              ? current.end
              : bound(current.end + deltaSec);
          final nextStart = start.clamp(0, end - 0.05).toDouble();
          final nextEnd = end.clamp(nextStart + 0.05, duration).toDouble();
          state = state.copyWith(
            plManual: current.copyWith(
              start: nextStart,
              end: nextEnd,
              bars: _barsFor(nextStart, nextEnd, state.ai.bpm),
              why: '人工选点',
            ),
            activeGroup: kind,
            dirty: true,
            saved: false,
          );
          return;
        }
        final list = [...state.ai.pl];
        final current = list[state.plIdx];
        final start = target == FineTarget.loopEnd
            ? current.start
            : bound(current.start + deltaSec);
        final end = target == FineTarget.loopStart
            ? current.end
            : bound(current.end + deltaSec);
        final nextStart = start.clamp(0, end - 0.05).toDouble();
        final nextEnd = end.clamp(nextStart + 0.05, duration).toDouble();
        list[state.plIdx] = current.copyWith(
          start: nextStart,
          end: nextEnd,
          bars: _barsFor(nextStart, nextEnd, state.ai.bpm),
          why: '手动微调',
        );
        state = state.copyWith(
          ai: state.ai.copyWith(pl: list),
          activeGroup: kind,
          dirty: true,
          saved: false,
        );
    }
  }

  void applyManualPoint(GroupKind kind, double timeSec, {bool confirm = true}) {
    if (kind.isLoop) return;
    _remember();
    final duration = state.ai.durationSec;
    final candidate = PointCandidate(
      t: timeSec.clamp(0, duration).toDouble(),
      score: 1,
      why: '人工选点',
    );
    state = switch (kind) {
      GroupKind.td => state.copyWith(
        tdManual: candidate,
        tdIdx: state.ai.td.length,
        tdConfirmed: confirm,
        activeGroup: kind,
        dirty: true,
        saved: false,
      ),
      GroupKind.pd => state.copyWith(
        pdManual: candidate,
        pdIdx: state.ai.pd.length,
        pdConfirmed: confirm,
        activeGroup: kind,
        dirty: true,
        saved: false,
      ),
      GroupKind.tl || GroupKind.pl => state,
    };
  }

  void applyManualLoop(
    GroupKind kind,
    double startSec,
    double endSec, {
    bool confirm = true,
  }) {
    if (!kind.isLoop) return;
    _remember();
    final duration = state.ai.durationSec;
    final boundedStart = startSec.clamp(0, duration).toDouble();
    final boundedEnd = endSec.clamp(0, duration).toDouble();
    final start = math
        .min(boundedStart, boundedEnd - 0.05)
        .clamp(0, duration)
        .toDouble();
    final end = math
        .max(boundedEnd, start + 0.05)
        .clamp(start + 0.05, duration)
        .toDouble();
    final candidate = LoopCandidate(
      start: start,
      end: end,
      score: 1,
      bars: _barsFor(start, end, state.ai.bpm),
      why: '人工选点',
    );
    state = switch (kind) {
      GroupKind.tl => state.copyWith(
        tlManual: candidate,
        tlIdx: state.ai.tl.length,
        tlConfirmed: confirm,
        activeGroup: kind,
        dirty: true,
        saved: false,
      ),
      GroupKind.pl => state.copyWith(
        plManual: candidate,
        plIdx: state.ai.pl.length,
        plConfirmed: confirm,
        activeGroup: kind,
        dirty: true,
        saved: false,
      ),
      GroupKind.td || GroupKind.pd => state,
    };
  }

  double waveformViewportWidth = 800;
  double get _minimumZoom => minimumWaveformSpan(
    duration: state.ai.durationSec,
    bins: state.ai.waveformPeaks.isEmpty ? 512 : state.ai.waveformPeaks.length,
    width: waveformViewportWidth,
  );
  void zoomByFactor(double factor) {
    final duration = state.ai.durationSec;
    if (duration <= 0 || !factor.isFinite || factor <= 0) return;
    _setZoomWidth(
      ((state.zoomEnd - state.zoomStart) * factor).clamp(
        _minimumZoom,
        duration,
      ),
    );
  }

  void zoomIn() => zoomByFactor(.65);
  void zoomOut() => zoomByFactor(1.55);

  void _setZoomWidth(double width) {
    final center = state.playhead.clamp(0, state.ai.durationSec);
    var start = center - width / 2;
    var end = center + width / 2;
    if (start < 0) {
      end -= start;
      start = 0;
    }
    if (end > state.ai.durationSec) {
      start -= end - state.ai.durationSec;
      end = state.ai.durationSec;
    }
    state = state.copyWith(zoomStart: start, zoomEnd: end);
  }

  void undo() {
    if (_history.isEmpty) return;
    _redoHistory.add(state);
    state = _history.removeLast();
  }

  TrackTimingConfig saveToProject() {
    TimeInputValidation.flush();
    if (TimeInputValidation.invalid.isNotEmpty) {
      throw const FormatException('存在无效的时间输入，请先修正');
    }
    commitManualDraft?.call();
    final config = TrackTimingConfig(
      source: state.track.source,
      bpm: state.ai.bpm,
      bpmManual: state.bpmManual,
      markersSec: state.markerSeconds,
      confirmed: state.confirmedGroups,
      updatedAt: DateTime.now().toUtc(),
    );
    ref.read(trackTimingProvider.notifier).save(config);
    state = state.copyWith(dirty: false, saved: true);
    _savedState = state;
    return config;
  }

  void redo() {
    if (_redoHistory.isEmpty) return;
    _history.add(state);
    state = _redoHistory.removeLast();
  }

  void _remember() {
    _redoHistory.clear();
    _history.add(state);
    if (_history.length > 40) _history.removeAt(0);
  }
}

final replaceEditorProvider = StateNotifierProvider.autoDispose
    .family<ReplaceEditorNotifier, ReplaceEditorState, String>((ref, trackId) {
      final realTracks = ref.read(realPoolTracksProvider);
      final track =
          _resolveTrack(trackId, realTracks) ??
          _fallbackTrackForRouteId(trackId);
      final config = track.id.startsWith('real:')
          ? ref.read(trackTimingProvider.notifier).configForPath(track.source)
          : null;
      var initial = ReplaceEditorState.initial(
        trackId: track.id,
        track: track,
        ai: _seedAiFromTrackMetadata(kReplacementEdit.ai, track),
        config: config,
      );
      if (config == null && ref.read(editorOptionsProvider).manualOnly) {
        final d = initial.ai.durationSec;
        const point = PointCandidate(t: 0, score: 0, why: '待手动设置');
        final loop = LoopCandidate(
          start: 0,
          end: d,
          score: 0,
          bars: 0,
          why: '待手动设置',
        );
        initial = initial.copyWith(
          ai: initial.ai.copyWith(
            td: [point],
            pd: [point],
            tl: [loop],
            pl: [loop],
          ),
        );
      }
      final notifier = ReplaceEditorNotifier(
        ref,
        ref.read(editorOptionsProvider).manualOnly
            ? initial.copyWith(analyzing: false)
            : initial,
        config,
        ref.read(audioAnalysisProvider.notifier),
      );
      ref.listen<List<PoolTrack>>(realPoolTracksProvider, (_, next) {
        final track = _resolveTrack(trackId, next);
        if (track != null) notifier.refreshTrackMetadata(track);
      });
      return notifier;
    });

const Object _sentinel = Object();

AiResult _seedAiFromTrackMetadata(AiResult ai, PoolTrack track) {
  final duration = track.durationSec > 0 ? track.durationSec : ai.durationSec;
  final bpm = track.bpm > 0 ? track.bpm.toDouble() : ai.bpm;
  final hasAudioMetadata =
      track.sampleRate != null ||
      track.channels != null ||
      track.samples != null;
  if (!track.id.startsWith('real:') &&
      duration == ai.durationSec &&
      bpm == ai.bpm &&
      !hasAudioMetadata) {
    return ai;
  }
  final scale = ai.durationSec > 0 ? duration / ai.durationSec : 1.0;
  double t(double value) => (value * scale).clamp(0, duration).toDouble();
  final sampleRate =
      track.sampleRate ??
      (ai.sourceSampleRate <= 0 ? 48000 : ai.sourceSampleRate);
  final channels = track.channels ?? (ai.channels <= 0 ? 2 : ai.channels);
  final samples =
      track.samples ?? (duration > 0 ? (duration * sampleRate).round() : null);
  return ai.copyWith(
    waveformPeaks: const [],
    beats: const [],
    segments: const [],
    durationSec: duration,
    bpm: bpm,
    td: [for (final item in ai.td) item.copyWith(t: t(item.t))],
    pd: [for (final item in ai.pd) item.copyWith(t: t(item.t))],
    tl: [
      for (final item in ai.tl)
        item.copyWith(start: t(item.start), end: t(item.end)),
    ],
    pl: [
      for (final item in ai.pl)
        item.copyWith(start: t(item.start), end: t(item.end)),
    ],
    sourceSampleRate: sampleRate,
    channels: channels,
    sourceSamples: samples,
  );
}

PoolTrack? _resolveTrack(String routeTrackId, List<PoolTrack> realTracks) {
  final candidates = <String>{routeTrackId};
  if (routeTrackId.startsWith('real:')) {
    final source = pathFromRealTrackId(routeTrackId);
    if (source != null && source.isNotEmpty) {
      candidates.add(realTrackIdForPath(source));
    }
  }
  for (final track in [...realTracks, ...kCustomPool]) {
    if (candidates.contains(track.id)) return track;
  }
  return null;
}

PoolTrack _fallbackTrackForRouteId(String routeTrackId) {
  final source = routeTrackId.startsWith('real:')
      ? pathFromRealTrackId(routeTrackId)
      : null;
  if (source != null && source.isNotEmpty) {
    final file = File(source);
    final (artist, title) = guessTrackMetadata(file);
    return PoolTrack(
      id: realTrackIdForPath(source),
      title: title,
      artist: artist,
      source: source,
      durationSec: 0,
      bpm: 0,
      key: '待分析',
      configured: false,
      confirmed: 0,
      added: '未知',
    );
  }
  return PoolTrack(
    id: routeTrackId,
    title: '找不到曲目',
    artist: 'Unknown Artist',
    source: '',
    durationSec: 0,
    bpm: 0,
    key: '待分析',
    configured: false,
    confirmed: 0,
    added: '未知',
  );
}

AiResult _aiFromAnalysis(AudioAnalysisResult result) {
  final duration = result.durationSec <= 0 ? 1.0 : result.durationSec;
  final bpm = result.bpm <= 0 ? 120.0 : result.bpm;
  final beat = 60 / bpm;
  double m(String key, double fallback) {
    final value = result.markers[key];
    if (value == null || value.isNaN) return fallback.clamp(0, duration);
    return value.clamp(0, duration).toDouble();
  }

  List<PointCandidate> point(
    String key,
    String group,
    String label,
    double fallback,
  ) {
    final v2 = result.pointCandidates[group] ?? const [];
    if (v2.isNotEmpty) {
      return [
        for (final item in v2)
          PointCandidate(
            t: item.t.clamp(0, duration).toDouble(),
            score: item.score,
            why: item.why.isEmpty ? '$label · AI v2 建议' : item.why,
          ),
      ];
    }
    final base = m(key, fallback);
    return [
      PointCandidate(t: base, score: 0.82, why: '$label · 本地分析建议'),
      PointCandidate(
        t: (base - beat).clamp(0, duration).toDouble(),
        score: 0.62,
        why: '提前 1 拍',
      ),
      PointCandidate(
        t: (base + beat).clamp(0, duration).toDouble(),
        score: 0.58,
        why: '推后 1 拍',
      ),
    ];
  }

  List<LoopCandidate> loop(
    String startKey,
    String endKey,
    String group,
    double startFallback,
    double endFallback,
    String label,
  ) {
    final v2 = result.loopCandidates[group] ?? const [];
    if (v2.isNotEmpty) {
      return [
        for (final item in v2)
          LoopCandidate(
            start: item.start.clamp(0, duration).toDouble(),
            end: item.end.clamp(item.start + 0.5, duration).toDouble(),
            score: item.score,
            bars: item.bars <= 0 ? 1 : item.bars,
            why: item.why.isEmpty ? '$label · AI v2 建议' : item.why,
          ),
      ];
    }
    final start = m(startKey, startFallback);
    final end = m(endKey, endFallback).clamp(start + 0.5, duration).toDouble();
    final bars = ((end - start) / beat / 4).round().clamp(1, 128);
    return [
      LoopCandidate(
        start: start,
        end: end,
        score: 0.78,
        bars: bars,
        why: '$label · 能量窗口启发式',
      ),
      LoopCandidate(
        start: (start + beat * 4).clamp(0, duration - 0.5).toDouble(),
        end: end,
        score: 0.61,
        bars: bars,
        why: '短一点的循环入口',
      ),
      LoopCandidate(
        start: start,
        end: (end - beat * 4).clamp(start + 0.5, duration).toDouble(),
        score: 0.52,
        bars: (bars - 1).clamp(1, 128),
        why: '短一点的循环出口',
      ),
    ];
  }

  final segments = result.segments
      .where((segment) => segment.end > segment.start)
      .map(
        (segment) => Segment(
          start: segment.start.clamp(0, duration).toDouble(),
          end: segment.end.clamp(0, duration).toDouble(),
          label: segment.label,
        ),
      )
      .toList(growable: false);

  return AiResult(
    durationSec: duration,
    bpm: bpm,
    confidence: 0.72,
    td: point('TrackDrop', 'td', 'TrackDrop', duration * 0.25),
    pd: point('PostDrop', 'pd', 'PostDrop', duration * 0.68),
    tl: loop(
      'TrackLoopStart',
      'TrackLoopEnd',
      'tl',
      duration * 0.12,
      duration * 0.55,
      'TrackLoop',
    ),
    pl: loop(
      'PostRaceLoopStart',
      'PostRaceLoopEnd',
      'pl',
      duration * 0.55,
      duration * 0.86,
      'PostLoop',
    ),
    beats: result.beats.isEmpty ? _genBeats(duration, bpm) : result.beats,
    segments: segments.isEmpty
        ? [Segment(start: 0, end: duration, label: 'chorus')]
        : segments,
    waveformPeaks: _waveformDisplayValues(result.waveform),
    sourceSampleRate: result.sampleRate <= 0 ? 48000 : result.sampleRate,
    channels: result.channels <= 0 ? 2 : result.channels,
    sourceSamples: result.samples <= 0 ? null : result.samples,
    decoder: result.decoder,
    rmsDbfs: result.rmsDbfs,
    peakDbfs: result.peakDbfs,
    aiNote: result.aiNote,
  );
}

AiResult _applyConfig(AiResult ai, TrackTimingConfig config) {
  return _applyMarkers(
    config.bpmManual ? _withManualBpm(ai, config.bpm) : ai,
    config.markersSec,
    bpm: config.bpm > 0 ? config.bpm : ai.bpm,
  );
}

AiResult _applyCurrentMarkers(AiResult ai, ReplaceEditorState state) {
  return _applyMarkers(ai, state.markerSeconds, bpm: state.ai.bpm);
}

AiResult _applyMarkers(
  AiResult ai,
  Map<String, double> markers, {
  required double bpm,
}) {
  PointCandidate firstPoint(
    List<PointCandidate> list,
    String marker,
    String why,
  ) {
    final fallback = list.isEmpty ? 0.0 : list.first.t;
    return PointCandidate(
      t: (markers[marker] ?? fallback).clamp(0, ai.durationSec).toDouble(),
      score: list.isEmpty ? 1 : list.first.score,
      why: why,
    );
  }

  LoopCandidate firstLoop(
    List<LoopCandidate> list,
    String startMarker,
    String endMarker,
    String why,
  ) {
    final fallback = list.isEmpty
        ? LoopCandidate(
            start: 0,
            end: ai.durationSec,
            score: 1,
            bars: 1,
            why: why,
          )
        : list.first;
    final start = (markers[startMarker] ?? fallback.start)
        .clamp(0, ai.durationSec)
        .toDouble();
    final end = (markers[endMarker] ?? fallback.end)
        .clamp(start + 0.05, ai.durationSec)
        .toDouble();
    return fallback.copyWith(start: start, end: end, why: why);
  }

  return ai.copyWith(
    bpm: bpm,
    td: [firstPoint(ai.td, 'TrackDrop', '已保存配置'), ...ai.td.skip(1)],
    pd: [firstPoint(ai.pd, 'PostDrop', '已保存配置'), ...ai.pd.skip(1)],
    tl: [
      firstLoop(ai.tl, 'TrackLoopStart', 'TrackLoopEnd', '已保存配置'),
      ...ai.tl.skip(1),
    ],
    pl: [
      firstLoop(ai.pl, 'PostRaceLoopStart', 'PostRaceLoopEnd', '已保存配置'),
      ...ai.pl.skip(1),
    ],
  );
}

AiResult _withManualBpm(AiResult ai, double bpm) {
  // Retain the first detected beat as the phase anchor. A fixed BPM cannot
  // reproduce a changing tempo, but must agree with nudge and snap intervals.
  final step = 60 / bpm;
  final anchor = ai.beats.isEmpty ? 0.0 : ai.beats.first;
  final phase = anchor % step;
  List<LoopCandidate> loops(List<LoopCandidate> values) => [
    for (final loop in values)
      loop.copyWith(bars: _barsFor(loop.start, loop.end, bpm)),
  ];
  return ai.copyWith(
    bpm: bpm,
    beats: [for (double t = phase; t <= ai.durationSec; t += step) t],
    tl: loops(ai.tl),
    pl: loops(ai.pl),
  );
}

List<double> _genBeats(double duration, double bpm) {
  final step = bpm <= 0 ? 0.5 : 60 / bpm;
  return [
    for (double t = 0; t <= duration; t += step)
      double.parse(t.toStringAsFixed(3)),
  ];
}

List<double> _waveformDisplayValues(List<AudioWaveformBin> bins) {
  return [
    for (final bin in bins)
      (bin.rms.clamp(0, 1) * 0.88 + bin.peak.clamp(0, 1) * 0.12)
          .clamp(0, 1)
          .toDouble(),
  ];
}

int _idx(int value, int length) {
  if (length <= 1) return 0;
  return value.clamp(0, length - 1).toInt();
}

int _idxWithManual(int value, int aiLength, bool hasManual) {
  final max = aiLength + (hasManual ? 1 : 0);
  if (max <= 1) return 0;
  return value.clamp(0, max - 1).toInt();
}

int _barsFor(double start, double end, double bpm) {
  final beat = bpm <= 0 ? 0.5 : 60 / bpm;
  return ((end - start) / beat / 4).round().clamp(1, 128).toInt();
}

// Keep an existing edit, but never show the same seam twice.
List<LoopCandidate> _nativeLoopsWithCurrent(
  LoopCandidate current,
  List<LoopCandidate> loops,
) {
  final index = loops.indexWhere(
    (loop) =>
        (loop.start - current.start).abs() < 0.000001 &&
        (loop.end - current.end).abs() < 0.000001,
  );
  if (index < 0) return [current, ...loops];
  return [
    loops[index],
    for (var i = 0; i < loops.length; i++)
      if (i != index) loops[i],
  ];
}
