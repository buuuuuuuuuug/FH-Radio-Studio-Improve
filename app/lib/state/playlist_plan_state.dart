import '../core/playlist_capacity.dart';
import 'playlist_capacity.dart';
import 'editor_options.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/playlist_plan.dart';
import '../core/project_refs.dart';
import '../domain/radio_library.dart';
import 'studio_state.dart';
import 'unsaved_edits.dart';
import 'dart:io';

class PlaylistPlanController extends StateNotifier<PlaylistPlan> {
  PlaylistPlanController(this.ref) : super(const PlaylistPlan.empty()) {
    _projectDir = ref.read(studioProvider).projectDir;
    _resetDraft();
    final edits = ref.read(unsavedEditsProvider);
    edits.entries['playlist'] = PendingEdit(
      label: '播放列表',
      dirty: () => mounted && dirty,
      save: save,
      discard: discard,
      discardBlockedReason: _discardBlockedReason,
    );
    ref.onDispose(() => edits.entries.remove('playlist'));
    ref.listen<String>(studioProvider.select((state) => state.projectDir), (
      _,
      next,
    ) {
      _projectDir = next;
      _resetDraft();
    });
  }

  final Ref ref;
  late String _projectDir;
  String _savedSignature = '';
  PlaylistPlan _saved = const PlaylistPlan.empty();
  bool hasUserPlan = false;
  bool _savedUserPlan = false;
  final _undo = <({PlaylistPlan plan, bool userPlan})>[];
  final _redo = <({PlaylistPlan plan, bool userPlan})>[];
  int _transactionDepth = 0;
  bool get canUndo => _undo.isNotEmpty && !_editingLocked;
  bool get canRedo => _redo.isNotEmpty && !_editingLocked;
  ({PlaylistPlan plan, bool userPlan}) get _entry =>
      (plan: state, userPlan: hasUserPlan);
  void _restore(({PlaylistPlan plan, bool userPlan}) entry) {
    hasUserPlan = entry.userPlan;
    state = entry.plan.copyWith();
  }

  void undo() {
    if (!canUndo) return;
    _ensureCapacity(_undo.last.plan);
    _redo.add(_entry);
    _restore(_undo.removeLast());
  }

  void redo() {
    if (!canRedo) return;
    _ensureCapacity(_redo.last.plan);
    _undo.add(_entry);
    _restore(_redo.removeLast());
  }

  T transaction<T>(T Function() operation) {
    final before = _entry;
    _transactionDepth++;
    try {
      return operation();
    } catch (_) {
      _restore(before);
      rethrow;
    } finally {
      _transactionDepth--;
      if (_transactionDepth == 0 &&
          (before.plan.encodeForStorage() != state.encodeForStorage() ||
              before.userPlan != hasUserPlan)) {
        _undo.add(before);
        if (_undo.length > 100) _undo.removeAt(0);
        _redo.clear();
      }
    }
  }

  void _ensureCapacity(PlaylistPlan plan, {bool absolute = false}) {
    if (ref.read(editorOptionsProvider).expansionEnabled) return;
    ref
        .read(playlistCapacityPolicyProvider)
        .requireTransition(state, plan, allowExistingOverflow: !absolute);
  }

  void _apply(PlaylistPlan plan) {
    if (_transactionDepth == 0) {
      transaction(() => _apply(plan));
      return;
    }
    _ensureCapacity(plan);
    hasUserPlan = true;
    state = plan;
  }

  bool get dirty =>
      hasUserPlan != _savedUserPlan ||
      state.encodeForStorage() != _savedSignature;

  void _resetDraft() {
    _undo.clear();
    _redo.clear();
    hasUserPlan = File(PlaylistPlanStore.configPath(_projectDir)).existsSync();
    try {
      state = hasUserPlan
          ? PlaylistPlanStore.read(_projectDir)
          : const PlaylistPlan.empty();
    } on ProjectRefException {
      state = const PlaylistPlan.empty();
      hasUserPlan = false;
    }
    _saved = state;
    _savedUserPlan = hasUserPlan;
    _savedSignature = state.encodeForStorage();
  }

  void reload() => _resetDraft();

  // 草稿是纯内存权威（不再每次写盘）；build 时由 buildPackage 经 stdin 喂给 CLI。
  void replaceWith(PlaylistPlan plan) {
    if (_editingLocked) return;
    _apply(
      plan.splitPlaylistTypes != null || plan.splitSnapshot != null
          ? plan.copyWith()
          : plan.withSceneStateFrom(state),
    );
  }

  void save() {
    final plan = hasUserPlan ? state : _stateSeededFromPackage();
    _ensureCapacity(plan, absolute: true);
    PlaylistPlanStore.write(_projectDir, plan);
    hasUserPlan = true;
    _savedUserPlan = true;
    _saved = plan;
    _savedSignature = plan.encodeForStorage();
    state = plan.copyWith();
  }

  String? _discardBlockedReason() {
    try {
      _ensureCapacity(_saved);
      return null;
    } on PlaylistCapacityException catch (error) {
      return '已保存的旧播放列表仍超出原始容量：${describeCapacityViolations(error.issues).join('；')}。'
          '放弃更改会恢复旧列表。请先保存当前播放列表；如需恢复旧列表，请先重新开启电台扩容。';
    }
  }

  void discard() {
    _ensureCapacity(_saved);
    _undo.clear();
    _redo.clear();
    hasUserPlan = _savedUserPlan;
    state = _saved.copyWith();
  }

  void assign({
    required String source,
    required String radioCode,
    required String playlistType,
    required int slot,
  }) {
    if (_editingLocked) return;
    final next = _stateSeededFromPackage().assign(
      source: source,
      radioCode: radioCode,
      playlistType: playlistType,
      slot: slot,
      projectDir: _projectDir,
    );
    _apply(next);
  }

  void unassign(String source, {String? radioCode, String? playlistType}) {
    if (_editingLocked) return;
    final next = _stateSeededFromPackage().unassign(
      source,
      radioCode: radioCode,
      playlistType: playlistType,
      projectDir: _projectDir,
    );
    _apply(next);
  }

  void removeDeletedSource(String source) {
    removeDeletedSources([source]);
  }

  void removeDeletedSources(Iterable<String> sources) {
    _undo.clear();
    _redo.clear();
    final base = _stateSeededFromPackage();
    hasUserPlan = true;
    final deleted = sources.toList();
    state = base.removeDeletedSourcesEverywhere(deleted);
    _saved = _saved.removeDeletedSourcesEverywhere(deleted);
    _savedSignature = _saved.encodeForStorage();
  }

  void restoreBuiltin({
    required String radioCode,
    required String playlistType,
  }) {
    if (_editingLocked) return;
    final next = _stateSeededFromPackage().restoreBuiltin(
      radioCode: radioCode,
      playlistType: playlistType,
    );
    _apply(next);
  }

  PlaylistPlan _stateSeededFromPackage() {
    if (hasUserPlan || state.hasDraft) return state;
    final cli = ref.read(studioProvider);
    return playlistPlanFromPackageSummaries(
      projectDir: cli.projectDir,
      pending: cli.pendingPackageSummary,
      last: cli.lastPackageSummary,
    );
  }

  bool get _editingLocked => ref.read(studioProvider).projectEditingLocked;
}

final playlistPlanProvider =
    StateNotifierProvider<PlaylistPlanController, PlaylistPlan>(
      (ref) => PlaylistPlanController(ref),
    );

final effectivePlaylistPlanProvider = Provider<PlaylistPlan>((ref) {
  final plan = ref.watch(playlistPlanProvider);
  if (ref.read(playlistPlanProvider.notifier).hasUserPlan || plan.hasDraft) {
    return plan;
  }
  final cli = ref.watch(
    studioProvider.select(
      (state) => (
        projectDir: state.projectDir,
        pending: state.pendingPackageSummary,
        last: state.lastPackageSummary,
      ),
    ),
  );
  return playlistPlanFromPackageSummaries(
    projectDir: cli.projectDir,
    pending: cli.pending,
    last: cli.last,
  );
});

PlaylistPlan playlistPlanFromPackageSummaries({
  required String projectDir,
  required PackageArtifactSummary? pending,
  required PackageArtifactSummary? last,
}) {
  final package = pending ?? last;
  if (package == null || package.assignments.isEmpty) {
    return const PlaylistPlan.empty();
  }
  if (!isUiSupportedRadio(name: package.station)) {
    return const PlaylistPlan.empty();
  }
  final assignments = <String, PlaylistAssignment>{};
  for (final item in package.assignments) {
    if (item.source.trim().isEmpty || item.slot <= 0) continue;
    final radioCode = canonicalRadioCode(item.radioLabel);
    final playlistTypes = item.normalizedPlaylistTypes;
    for (final playlistType in playlistTypes) {
      final assignment = PlaylistAssignment(
        trackKey: _playlistTrackKey(projectDir, item.source),
        source: item.source,
        radioCode: radioCode,
        playlistType: playlistType,
        slot: item.slotForPlaylist(playlistType),
      );
      if (!assignment.isValid || !assignment.isAssigned) continue;
      assignments[assignment.assignmentKey] = assignment;
    }
  }
  return PlaylistPlan(assignments: assignments);
}

String _playlistTrackKey(String projectDir, String source) {
  try {
    return trackKeyForProjectPath(projectDir, source) ??
        PlaylistAssignment.keyForPath(source);
  } on Object {
    return PlaylistAssignment.keyForPath(source);
  }
}
