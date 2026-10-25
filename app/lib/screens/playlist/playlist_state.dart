import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/playlist_plan.dart';
import '../../core/playlist_capacity.dart';
import '../../core/project_workspace.dart';
import '../../domain/radio_library.dart';
import '../../state/studio_state.dart';
import '../../state/custom_pool_tracks.dart';
import '../../state/playlist_catalog_state.dart';
import '../../state/playlist_plan_state.dart';

enum PlaylistMode { freeroam, event }

@immutable
class PlaylistState {
  static final _poolIndexes = Expando<Map<String, PoolTrack>>(
    'playlist pool index',
  );
  const PlaylistState({
    required this.pool,
    required this.mode,
    required this.search,
    required this.splitPlaylistTypes,
  });

  final List<PoolTrack> pool;
  final PlaylistMode mode;
  final String search;
  final bool splitPlaylistTypes;

  List<PoolTrack> tracksOfRadio(
    String radioCode,
    String playlistType,
    PlaylistPlan plan,
  ) {
    final bySource = _poolIndexes[this] ??= {
      for (final track in pool)
        PlaylistAssignment.keyForPath(track.source): track,
    };
    final out = <PoolTrack>[];
    for (final assignment in plan.assignmentsForRadio(
      radioCode,
      playlistType,
    )) {
      final track =
          bySource[assignment.trackKey] ??
          bySource[PlaylistAssignment.keyForPath(assignment.source)];
      if (track == null) continue;
      out.add(
        track.copyWith(assignedTo: assignment.radioCode, slot: assignment.slot),
      );
    }
    return out;
  }

  List<PoolTrack> poolForDisplay(PlaylistPlan plan) {
    // Resolve assignments once. Repeating assignmentForPath for every song
    // previously normalized and sorted the entire plan for each pool row.
    final ordered = plan.assignments.values.where((a) => a.isAssigned).toList()
      ..sort((a, b) {
        final radio = a.radioCode.compareTo(b.radioCode);
        if (radio != 0) return radio;
        final type = (a.playlistType == 'FreeRoam' ? 0 : 1).compareTo(
          b.playlistType == 'FreeRoam' ? 0 : 1,
        );
        if (type != 0) return type;
        final slot = a.slot.compareTo(b.slot);
        return slot != 0
            ? slot
            : a.source.toLowerCase().compareTo(b.source.toLowerCase());
      });
    final firstBySource = <String, PlaylistAssignment>{};
    for (final assignment in ordered) {
      if (assignment.trackKey.isNotEmpty) {
        firstBySource.putIfAbsent(assignment.trackKey, () => assignment);
      }
      firstBySource.putIfAbsent(
        PlaylistAssignment.keyForPath(assignment.source),
        () => assignment,
      );
    }
    PoolTrack withAssignment(PoolTrack track) {
      final assignment =
          firstBySource[PlaylistAssignment.keyForPath(track.source)];
      return assignment == null
          ? track.copyWith(clearAssigned: true)
          : track.copyWith(
              assignedTo: assignment.radioCode,
              slot: assignment.slot,
            );
    }

    final assignedTrackKeys = _assignedTrackKeys(plan);
    final indexed = [
      for (var index = 0; index < pool.length; index += 1)
        (
          index: index,
          track: pool[index],
          assigned: assignedTrackKeys.contains(
            PlaylistAssignment.keyForPath(pool[index].source),
          ),
        ),
    ];
    indexed.sort((a, b) {
      if (a.assigned != b.assigned) return a.assigned ? 1 : -1;
      final byCompleteness = _configurationCompleteness(
        b.track,
      ).compareTo(_configurationCompleteness(a.track));
      if (byCompleteness != 0) return byCompleteness;
      if (a.track.configured != b.track.configured) {
        return a.track.configured ? -1 : 1;
      }
      if (a.track.isSiren != b.track.isSiren) {
        return a.track.isSiren ? -1 : 1;
      }
      return a.index.compareTo(b.index);
    });
    return [for (final item in indexed) withAssignment(item.track)];
  }

  PlaylistState copyWith({
    List<PoolTrack>? pool,
    PlaylistMode? mode,
    String? search,
    bool? splitPlaylistTypes,
  }) {
    return PlaylistState(
      pool: pool ?? this.pool,
      mode: mode ?? this.mode,
      search: search ?? this.search,
      splitPlaylistTypes: splitPlaylistTypes ?? this.splitPlaylistTypes,
    );
  }
}

Set<String> _assignedTrackKeys(PlaylistPlan plan) {
  final keys = <String>{};
  for (final assignment in plan.assignments.values) {
    if (!assignment.isAssigned) continue;
    if (assignment.trackKey.isNotEmpty) keys.add(assignment.trackKey);
    if (assignment.source.trim().isNotEmpty) {
      keys.add(PlaylistAssignment.keyForPath(assignment.source));
    }
  }
  return keys;
}

class PlaylistNotifier extends StateNotifier<PlaylistState> {
  PlaylistNotifier(this.ref, List<PoolTrack> pool, {bool splitTypes = false})
    : super(
        PlaylistState(
          pool: List<PoolTrack>.from(pool),
          mode: PlaylistMode.freeroam,
          search: '',
          splitPlaylistTypes: splitTypes,
        ),
      );

  final Ref ref;
  String? lastEditBlockedReason;

  void setMode(PlaylistMode m) => state = state.copyWith(mode: m);
  void setSearch(String s) => state = state.copyWith(search: s);
  void setSplitPlaylistTypes(bool value, {String keepType = 'FreeRoam'}) {
    if (_editingLocked) return;
    if (value == state.splitPlaylistTypes) return;
    final next = _editablePlan().setSplitMode(value, keepType: keepType);
    ref.read(playlistPlanProvider.notifier).replaceWith(next);
    state = state.copyWith(splitPlaylistTypes: value);
  }

  // A saved, reconstructed or undone split layout must never be silently
  // collapsed by the next ordinary drag while the scene switch is hidden.
  void preserveSplitLayout(bool hasDifferences) {
    if (hasDifferences != state.splitPlaylistTypes) {
      // Riverpod may refresh a derived layout lazily during a widget rebuild.
      // Publish that UI change after the frame, never from inside build.
      if (SchedulerBinding.instance.schedulerPhase ==
          SchedulerPhase.persistentCallbacks) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            preserveSplitLayout(ref.read(_loadedSplitLayoutProvider));
          }
        });
        return;
      }
      state = state.copyWith(splitPlaylistTypes: hasDifferences);
    }
  }

  void setPool(List<PoolTrack> pool) {
    state = state.copyWith(pool: List<PoolTrack>.from(pool));
  }

  void reorder(
    String source,
    String beforeSource,
    String radioCode,
    String type,
  ) => ref
      .read(playlistPlanProvider.notifier)
      .transaction(() => _reorder(source, beforeSource, radioCode, type));

  void _reorder(
    String source,
    String beforeSource,
    String radioCode,
    String type,
  ) {
    if (_editingLocked || source == beforeSource) return;
    var plan = _ensureEditablePlanSeeded().moveBefore(
      source: source,
      beforeSource: beforeSource,
      radioCode: radioCode,
      playlistType: type,
    );
    if (!state.splitPlaylistTypes) plan = plan.syncPlaylistTypesFrom(type);
    ref.read(playlistPlanProvider.notifier).replaceWith(plan);
  }

  /// 把曲目分配到电台。slot 自动 = 该电台当前已分配数 + 1。
  bool assignToRadio(
    String trackId,
    String radioCode,
    String playlistType, {
    int? maxSlots,
    String? originRadioCode,
    String? originPlaylistType,
  }) => ref
      .read(playlistPlanProvider.notifier)
      .transaction(
        () => _assignToRadio(
          trackId,
          radioCode,
          playlistType,
          maxSlots: maxSlots,
          originRadioCode: originRadioCode,
          originPlaylistType: originPlaylistType,
        ),
      );

  bool _assignToRadio(
    String trackId,
    String radioCode,
    String playlistType, {
    int? maxSlots,
    String? originRadioCode,
    String? originPlaylistType,
  }) {
    lastEditBlockedReason = null;
    if (_editingLocked) return false;
    final track = _trackById(trackId);
    if (track == null) return false;
    final targetRadio = radioCode.trim().toUpperCase();
    final targetType = PlaylistAssignment.normalizePlaylistType(playlistType);
    var plan = _editablePlan();
    if (originRadioCode != null &&
        originPlaylistType != null &&
        _wouldEmptySplitList(
          plan,
          [track.source],
          radioCode: originRadioCode,
          playlistType: originPlaylistType,
          targetRadioCode: targetRadio,
          targetPlaylistType: targetType,
        )) {
      return false;
    }
    if (!state.splitPlaylistTypes) {
      plan = plan.syncPlaylistTypesFrom(targetType);
    }
    final existing =
        plan.assignmentFor(
          source: track.source,
          radioCode: targetRadio,
          playlistType: targetType,
        ) ??
        (!state.splitPlaylistTypes
            ? plan.assignmentFor(
                source: track.source,
                radioCode: targetRadio,
                playlistType: _otherPlaylistType(targetType),
              )
            : null);
    if (existing == null &&
        maxSlots != null &&
        (!plan.canFitRadioSources(targetRadio, [track.source], maxSlots) ||
            plan.assignmentsForRadio(targetRadio, targetType).length >=
                maxSlots)) {
      return false;
    }
    final nextSlot =
        existing?.slot ??
        plan.assignmentsForRadio(targetRadio, targetType).length + 1;
    var nextPlan = plan.assign(
      source: track.source,
      radioCode: targetRadio,
      playlistType: targetType,
      slot: nextSlot,
      projectDir: ref.read(studioProvider).projectDir,
    );
    if (!state.splitPlaylistTypes) {
      nextPlan = nextPlan.assign(
        source: track.source,
        radioCode: targetRadio,
        playlistType: _otherPlaylistType(targetType),
        slot: nextSlot,
        projectDir: ref.read(studioProvider).projectDir,
      );
    }
    nextPlan = _removeMoveOrigin(
      plan: nextPlan,
      source: track.source,
      targetRadioCode: targetRadio,
      targetPlaylistType: targetType,
      originRadioCode: originRadioCode,
      originPlaylistType: originPlaylistType,
    );
    ref.read(playlistPlanProvider.notifier).replaceWith(nextPlan);
    state = state.copyWith(
      pool: [
        for (final t in state.pool)
          if (t.id == trackId)
            t.copyWith(assignedTo: targetRadio, slot: nextSlot)
          else
            t,
      ],
    );
    return true;
  }

  /// Build the entire selection locally; exceeding capacity changes nothing.
  bool assignManyToRadio(
    List<String> trackIds,
    String radioCode,
    String playlistType, {
    required int maxSlots,
    String? originRadioCode,
    String? originPlaylistType,
  }) {
    lastEditBlockedReason = null;
    if (_editingLocked) return false;
    final tracks = <PoolTrack>[];
    final seen = <String>{};
    for (final id in trackIds) {
      final track = _trackById(id);
      if (track == null) return false;
      if (seen.add(PlaylistAssignment.keyForPath(track.source))) {
        tracks.add(track);
      }
    }
    if (tracks.isEmpty) return false;
    var plan = _editablePlan();
    if (originRadioCode != null &&
        originPlaylistType != null &&
        _wouldEmptySplitList(
          plan,
          tracks.map((t) => t.source),
          radioCode: originRadioCode,
          playlistType: originPlaylistType,
          targetRadioCode: radioCode,
          targetPlaylistType: playlistType,
        )) {
      return false;
    }
    if (!state.splitPlaylistTypes) {
      plan = plan.syncPlaylistTypesFrom(playlistType);
    }
    final type = PlaylistAssignment.normalizePlaylistType(playlistType);
    final existing = plan.assignmentsForRadio(radioCode, type);
    final newTracks = tracks
        .where(
          (t) =>
              plan.assignmentFor(
                source: t.source,
                radioCode: radioCode,
                playlistType: type,
              ) ==
              null,
        )
        .toList();
    if (existing.length + newTracks.length > maxSlots ||
        !plan.canFitRadioSources(
          radioCode,
          newTracks.map((t) => t.source),
          maxSlots,
        )) {
      return false;
    }
    var slot = existing.length;
    for (final track in newTracks) {
      plan = plan.assign(
        source: track.source,
        radioCode: radioCode,
        playlistType: type,
        slot: ++slot,
        projectDir: ref.read(studioProvider).projectDir,
      );
    }
    if (!state.splitPlaylistTypes) plan = plan.syncPlaylistTypesFrom(type);
    for (final track in tracks) {
      plan = _removeMoveOrigin(
        plan: plan,
        source: track.source,
        targetRadioCode: radioCode,
        targetPlaylistType: type,
        originRadioCode: originRadioCode,
        originPlaylistType: originPlaylistType,
      );
    }
    ref.read(playlistPlanProvider.notifier).replaceWith(plan);
    return true;
  }

  void reorderMany(
    List<String> sources,
    String beforeSource,
    String radioCode,
    String type,
  ) {
    if (_editingLocked ||
        sources.any(
          (s) =>
              PlaylistAssignment.keyForPath(s) ==
              PlaylistAssignment.keyForPath(beforeSource),
        )) {
      return;
    }
    var plan = _editablePlan();
    for (final source in sources) {
      plan = plan.moveBefore(
        source: source,
        beforeSource: beforeSource,
        radioCode: radioCode,
        playlistType: type,
      );
    }
    if (!state.splitPlaylistTypes) plan = plan.syncPlaylistTypesFrom(type);
    ref.read(playlistPlanProvider.notifier).replaceWith(plan);
  }

  void unassignMany(
    List<String> ids, {
    required String radioCode,
    required String playlistType,
  }) {
    lastEditBlockedReason = null;
    if (_editingLocked) return;
    final tracks = [for (final id in ids) _trackById(id)];
    if (tracks.any((t) => t == null)) return;
    var plan = _editablePlan();
    if (_wouldEmptySplitList(
      plan,
      tracks.map((t) => t!.source),
      radioCode: radioCode,
      playlistType: playlistType,
    )) {
      return;
    }
    if (!state.splitPlaylistTypes) {
      plan = plan.syncPlaylistTypesFrom(playlistType);
    }
    for (final track in tracks) {
      plan = plan.unassign(
        track!.source,
        radioCode: radioCode,
        playlistType: state.splitPlaylistTypes ? playlistType : null,
        projectDir: ref.read(studioProvider).projectDir,
      );
    }
    ref.read(playlistPlanProvider.notifier).replaceWith(plan);
  }

  PlaylistPlan _removeMoveOrigin({
    required PlaylistPlan plan,
    required String source,
    required String targetRadioCode,
    required String targetPlaylistType,
    required String? originRadioCode,
    required String? originPlaylistType,
  }) {
    final originRadio = originRadioCode?.trim().toUpperCase();
    if (originRadio == null || originRadio.isEmpty) return plan;
    final originType = originPlaylistType == null
        ? null
        : PlaylistAssignment.normalizePlaylistType(originPlaylistType);
    if (state.splitPlaylistTypes) {
      if (originType == null) return plan;
      if (originRadio == targetRadioCode && originType == targetPlaylistType) {
        return plan;
      }
      return plan.unassign(
        source,
        radioCode: originRadio,
        playlistType: originType,
        projectDir: ref.read(studioProvider).projectDir,
      );
    }
    if (originRadio == targetRadioCode) return plan;
    return plan.unassign(
      source,
      radioCode: originRadio,
      projectDir: ref.read(studioProvider).projectDir,
    );
  }

  /// 把曲目移回池子（取消分配）。
  void unassign(String trackId, {String? radioCode, String? playlistType}) =>
      ref
          .read(playlistPlanProvider.notifier)
          .transaction(
            () => _unassign(
              trackId,
              radioCode: radioCode,
              playlistType: playlistType,
            ),
          );

  void _unassign(String trackId, {String? radioCode, String? playlistType}) {
    lastEditBlockedReason = null;
    if (_editingLocked) return;
    final track = _trackById(trackId);
    if (track == null) return;
    if (_wouldEmptySplitList(
      _editablePlan(),
      [track.source],
      radioCode: radioCode,
      playlistType: playlistType,
    )) {
      return;
    }
    if (!state.splitPlaylistTypes && playlistType != null) {
      _syncPlanFrom(playlistType);
    } else {
      _ensureEditablePlanSeeded();
    }
    ref
        .read(playlistPlanProvider.notifier)
        .unassign(
          track.source,
          radioCode: radioCode,
          playlistType: state.splitPlaylistTypes ? playlistType : null,
        );
    state = state.copyWith(
      pool: [
        for (final t in state.pool)
          if (t.id == trackId) t.copyWith(clearAssigned: true) else t,
      ],
    );
  }

  void restoreBuiltin(String radioCode, String playlistType) => ref
      .read(playlistPlanProvider.notifier)
      .transaction(() => _restoreBuiltin(radioCode, playlistType));

  /// Copy the other scene into this scene as one reversible edit.
  bool copyScenePlaylist(
    String radioCode, {
    required String fromType,
    required String toType,
  }) {
    lastEditBlockedReason = null;
    final studio = ref.read(studioProvider);
    if (studio.projectEditingLocked) {
      lastEditBlockedReason = studio.projectEditingLockMessage;
      return false;
    }
    if (!ref.read(_loadedSplitLayoutProvider)) {
      lastEditBlockedReason = '请先启用分场景编辑，再使用另一场景的歌单。';
      return false;
    }
    final radio = radioCode.trim().toUpperCase();
    final from = PlaylistAssignment.normalizePlaylistType(fromType);
    final to = PlaylistAssignment.normalizePlaylistType(toType);
    if (radio.isEmpty || from == to) {
      lastEditBlockedReason = '请选择同一电台的另一场景歌单。';
      return false;
    }
    final plan = _editablePlan();
    if (plan.hasBuiltinOverride(radio, from) ||
        !plan.hasAssignmentsForRadio(radio, from)) {
      lastEditBlockedReason =
          '另一场景没有可复制的自建歌单。不支持一边原版、一边自建；如需恢复原版，请关闭分场景编辑后恢复整台。';
      return false;
    }
    if (plan
        .assignmentsForRadio(radio, from)
        .any((assignment) => !File(assignment.source).existsSync())) {
      lastEditBlockedReason = '另一场景有找不到的歌曲文件，请先重新导入或移除缺失歌曲，再复制歌单。';
      return false;
    }
    try {
      final copied = plan.copyScenePlaylist(
        radioCode: radio,
        fromType: from,
        toType: to,
      );
      ref.read(playlistPlanProvider.notifier).transaction(() {
        ref
            .read(playlistPlanProvider.notifier)
            .replaceWith(
              PlaylistPlan(
                assignments: copied.assignments,
                builtinTargets: copied.builtinTargets,
                // Legacy plans infer split mode from different scene lists.
                // Copying makes those lists equal but must keep split editing on.
                splitPlaylistTypes: true,
                splitSnapshot: copied.splitSnapshot,
              ),
            );
      });
      return true;
    } on PlaylistCapacityException catch (error) {
      lastEditBlockedReason = error.toString();
      return false;
    }
  }

  void _restoreBuiltin(String radioCode, String playlistType) {
    lastEditBlockedReason = null;
    if (_editingLocked) return;
    if (state.splitPlaylistTypes &&
        _editablePlan().hasAssignmentsForRadio(
          radioCode,
          _otherPlaylistType(playlistType),
        )) {
      lastEditBlockedReason = '两场景共用曲库，暂不支持一边原版、一边自建。请先关闭分场景编辑，合并列表后恢复整台。';
      return;
    }
    final controller = ref.read(playlistPlanProvider.notifier);
    _ensureEditablePlanSeeded();
    if (!state.splitPlaylistTypes) {
      _syncPlanFrom(playlistType);
    }
    controller.restoreBuiltin(radioCode: radioCode, playlistType: playlistType);
    if (!state.splitPlaylistTypes) {
      controller.restoreBuiltin(
        radioCode: radioCode,
        playlistType: _otherPlaylistType(playlistType),
      );
    }
    state = state.copyWith(
      pool: [for (final t in state.pool) t.copyWith(clearAssigned: true)],
    );
  }

  int copyGameLayout(PlaylistCatalog catalog, {String? unifiedType}) {
    if (_editingLocked) return 0;
    var plan = playlistPlanFromCatalog(
      catalog,
      state.pool,
      projectDir: ref.read(studioProvider).projectDir,
    );
    if (!state.splitPlaylistTypes) {
      plan = plan.syncPlaylistTypesFrom(
        unifiedType ??
            (state.mode == PlaylistMode.event ? 'Event' : 'FreeRoam'),
      );
    }
    ref.read(playlistPlanProvider.notifier).replaceWith(plan);
    return plan.assignments.length;
  }

  bool get _editingLocked => ref.read(studioProvider).projectEditingLocked;

  bool _wouldEmptySplitList(
    PlaylistPlan plan,
    Iterable<String> sources, {
    String? radioCode,
    String? playlistType,
    String? targetRadioCode,
    String? targetPlaylistType,
  }) {
    if (!state.splitPlaylistTypes) return false;
    final removed = sources.map(PlaylistAssignment.keyForPath).toSet();
    final affected = plan.assignments.values.where(
      (a) =>
          removed.contains(PlaylistAssignment.keyForPath(a.source)) &&
          (radioCode == null || a.radioCode == radioCode) &&
          (playlistType == null || a.playlistType == playlistType),
    );
    for (final assignment in affected) {
      if (assignment.radioCode == targetRadioCode &&
          assignment.playlistType == targetPlaylistType) {
        continue;
      }
      final existing = plan.assignmentsForRadio(
        assignment.radioCode,
        assignment.playlistType,
      );
      if (existing.every(
        (a) => removed.contains(PlaylistAssignment.keyForPath(a.source)),
      )) {
        lastEditBlockedReason = '分场景列表暂不支持清空。请至少保留一首歌曲，或关闭分场景编辑后恢复整台原版。';
        return true;
      }
    }
    return false;
  }

  PoolTrack? _trackById(String trackId) {
    for (final track in state.pool) {
      if (track.id == trackId) return track;
    }
    return null;
  }

  void _syncPlanFrom(String playlistType) {
    final plan = _ensureEditablePlanSeeded();
    if (!plan.hasDraft && !plan.hasSplitPlaylistDifferences) return;
    ref
        .read(playlistPlanProvider.notifier)
        .replaceWith(plan.syncPlaylistTypesFrom(playlistType));
  }

  PlaylistPlan _editablePlan() {
    final current = ref.read(playlistPlanProvider);
    if (current.hasDraft ||
        ref.read(playlistPlanProvider.notifier).hasUserPlan) {
      return current;
    }
    final effective = ref.read(effectivePlaylistPlanProvider);
    if (effective.hasDraft) return effective;
    final catalog = ref.read(playlistCatalogProvider);
    if (catalog.failed) return effective;
    return playlistPlanFromCatalog(
      catalog,
      state.pool,
      projectDir: ref.read(studioProvider).projectDir,
      includeBuiltinTargets: false,
    );
  }

  PlaylistPlan _ensureEditablePlanSeeded() {
    final plan = _editablePlan();
    if (!identical(plan, ref.read(playlistPlanProvider)) && plan.hasDraft) {
      ref.read(playlistPlanProvider.notifier).replaceWith(plan);
    }
    return plan;
  }

  String _otherPlaylistType(String playlistType) {
    return PlaylistAssignment.normalizePlaylistType(playlistType) == 'Event'
        ? 'FreeRoam'
        : 'Event';
  }
}

PlaylistPlan playlistPlanFromCatalog(
  PlaylistCatalog catalog,
  List<PoolTrack> pool, {
  String? projectDir,
  bool includeBuiltinTargets = true,
}) {
  var plan = const PlaylistPlan.empty();
  for (final radio in catalog.radios) {
    for (final playlistType in const ['FreeRoam', 'Event']) {
      if (catalog.modeOfList(radio.code, playlistType) != StationMode.custom) {
        if (includeBuiltinTargets) {
          plan = plan.restoreBuiltin(
            radioCode: radio.code,
            playlistType: playlistType,
          );
        }
        continue;
      }

      var slot = 1;
      for (final track in catalog.tracksOfRadio(radio.code, playlistType)) {
        // Source identities are supplied by the catalog's authoritative mapping.
        final source = catalog.sourceForTrack(track);
        if (source == null || source.trim().isEmpty) continue;
        plan = plan.assign(
          source: source,
          radioCode: radio.code,
          playlistType: playlistType,
          slot: slot,
          projectDir: projectDir,
        );
        slot += 1;
      }
    }
  }
  return plan;
}

final playlistProvider = StateNotifierProvider<PlaylistNotifier, PlaylistState>(
  (ref) {
    ref.watch(studioProvider.select((s) => s.projectDir));
    final notifier = PlaylistNotifier(
      ref,
      ref.read(realPoolTracksProvider),
      splitTypes: ref.read(_loadedSplitLayoutProvider),
    );
    ref.listen<bool>(_loadedSplitLayoutProvider, (_, hasDifferences) {
      notifier.preserveSplitLayout(hasDifferences);
    });
    ref.listen<List<PoolTrack>>(
      realPoolTracksProvider,
      (_, next) => notifier.setPool(next),
    );
    return notifier;
  },
  dependencies: [
    studioProvider,
    realPoolTracksProvider,
    _loadedSplitLayoutProvider,
  ],
);

final _loadedSplitLayoutProvider = Provider<bool>(
  (ref) {
    final plan = ref.watch(effectivePlaylistPlanProvider);
    if (plan.splitPlaylistTypes != null) return plan.splitPlaylistTypes!;
    if (FhRadioStudioProject.readSettings(
          ref.read(studioProvider).projectDir,
        )['split_playlist_types'] ==
        true) {
      return true;
    }
    if (ref.read(playlistPlanProvider.notifier).hasUserPlan || plan.hasDraft) {
      return plan.hasSplitPlaylistDifferences;
    }
    return playlistPlanFromCatalog(
      ref.watch(playlistCatalogProvider),
      const [],
      includeBuiltinTargets: false,
    ).hasSplitPlaylistDifferences;
  },
  dependencies: [
    effectivePlaylistPlanProvider,
    playlistPlanProvider,
    playlistCatalogProvider,
  ],
);

int _configurationCompleteness(PoolTrack track) {
  if (track.configured) return 4;
  return track.confirmed.clamp(0, 4).toInt();
}
