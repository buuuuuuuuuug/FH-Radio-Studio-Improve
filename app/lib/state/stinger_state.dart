import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/fh_radio_studio_cli.dart';
import '../screens/stingers/stinger_models.dart';
import '../screens/stingers/stinger_session.dart';
import 'studio_state.dart';
import 'unsaved_edits.dart';

final stingerMemoryCacheProvider =
    StateProvider<Map<String, Map<String, dynamic>>>((ref) => {});
final stingerCliProvider = Provider<FhRadioStudioCli>(
  (ref) => FhRadioStudioCli(
    repoRoot: ref.watch(studioProvider.select((s) => s.repoRoot)),
  ),
);
final stingerRequestOverrideProvider =
    Provider<
      Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)?
    >((ref) => null);

String stingerSignature(Object? value) {
  Object? ordered(Object? item) {
    if (item is Map) {
      final keys = item.keys.map((key) => '$key').toList()..sort();
      return {for (final key in keys) key: ordered(item[key])};
    }
    if (item is List) return item.map(ordered).toList();
    return item;
  }

  return jsonEncode(ordered(value));
}

Map<String, dynamic> stingerDefaultEdit(Map<String, dynamic> asset) {
  final duration = stingerNumber(asset['duration']);
  return {
    'asset_id': asset['id'],
    'start': 0.0,
    'end': duration,
    'gain_db': 0.0,
    'next_track': math.max(0.0, duration - math.min(1.2, duration / 4)),
  };
}

/// Like playlists, arrangement edits live in memory until the user saves.
/// Audio imports/caches remain project-owned; dragging never starts a worker.
class StingerDraftController extends StateNotifier<Map<String, dynamic>?> {
  StingerDraftController(this.ref) : super(null) {
    final edits = ref.read(unsavedEditsProvider);
    edits.entries['stingers'] = PendingEdit(
      label: '电台台呼',
      dirty: () => mounted && dirty,
      save: save,
      discard: discard,
    );
    ref.onDispose(() => edits.entries.remove('stingers'));
    ref.listen(studioProvider.select((s) => s.projectDir), (_, next) {
      _project = next;
      _saved = {};
      _undo.clear();
      _redo.clear();
      _materialPreviews.clear();
      state = null;
    });
  }
  final Ref ref;
  String _project = '', _game = '', _locale = 'JP';
  Map<String, dynamic> _saved = {};
  final _undo = <Map<String, dynamic>>[], _redo = <Map<String, dynamic>>[];
  final _materialPreviews = <String, Map<String, dynamic>>{};

  void rememberMaterialPreview(
    String assetId,
    Map<String, dynamic> edit,
    Map<String, dynamic> wave,
  ) {
    _materialPreviews['$assetId|${stingerSignature(edit)}'] = {
      ...wave,
      'edit': stingerClone(edit),
      'clip_gain': edit['gain_db'],
    };
  }

  Future<void>? _saving;
  bool get dirty =>
      state != null && stingerSignature(state) != stingerSignature(_saved);
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  Map<String, dynamic> get snapshot => stingerClone(state ?? {});

  void hydrate(Map<String, dynamic> data) {
    final studio = ref.read(studioProvider);
    _project = studio.projectDir;
    _game = studio.gameDir;
    _locale = '${data['locale'] ?? _locale}';
    final incoming = stingerClone(stingerMap(data['draft']));
    incoming['removed_assets'] ??= <String>[];
    if (state == null) {
      _saved = stingerClone(incoming);
      state = incoming;
      return;
    }
    // Importing a new file does not save or overwrite pending arrangement edits.
    final next = snapshot;
    for (final field in ['asset_edits', 'asset_names']) {
      final values = stingerMap(next[field]), saved = stingerMap(_saved[field]);
      for (final entry in stingerMap(incoming[field]).entries) {
        if (!values.containsKey(entry.key)) {
          values[entry.key] = entry.value;
          saved[entry.key] = entry.value;
        }
      }
      next[field] = values;
      _saved[field] = saved;
    }
    state = next;
  }

  void apply(Map<String, dynamic> next) {
    final normalized = stingerClone(next);
    normalized['assignments'] = stingerMap(normalized['assignments'])
      ..removeWhere((_, value) {
        final edit = stingerMap(value);
        return edit.containsKey('asset_id') &&
            edit['asset_id'] == null &&
            [
              'start',
              'end',
              'gain_db',
              'next_track',
            ].every((key) => edit[key] == null);
      });
    if (stingerSignature(normalized) == stingerSignature(state)) return;
    _undo.add(snapshot);
    if (_undo.length > 100) _undo.removeAt(0);
    _redo.clear();
    state = normalized;
  }

  void undo() {
    if (!canUndo) return;
    _redo.add(snapshot);
    state = _undo.removeLast();
  }

  void redo() {
    if (!canRedo) return;
    _undo.add(snapshot);
    state = _redo.removeLast();
  }

  void discard() {
    _undo.clear();
    _redo.clear();
    state = stingerClone(_saved);
  }

  Future<void> save() => _saving ??= _save().whenComplete(() => _saving = null);
  Future<void> _save() async {
    if (state == null || !dirty) return;
    final value = snapshot, project = _project;
    final override = ref.read(stingerRequestOverrideProvider);
    if (override != null) {
      await override('restore-draft', {
        'input': {...value, 'all_locales': true},
        'locale': _locale,
      });
    } else {
      final session = StingerSession(
        ref.read(stingerCliProvider),
        project,
        _game,
      );
      try {
        await session.call(
          'restore-draft',
          locale: _locale,
          input: {...value, 'all_locales': true},
        );
      } finally {
        session.dispose();
      }
    }
    if (!mounted || project != _project) return;
    _saved = stingerClone(value);
    state = snapshot;
    if ((value['removed_assets'] as List? ?? []).isNotEmpty) {
      _undo.clear();
      _redo.clear();
    }
    ref.read(stingerMemoryCacheProvider.notifier).state = {
      for (final entry in ref.read(stingerMemoryCacheProvider).entries)
        entry.key:
            entry.key.startsWith('$project|') && entry.key.endsWith('|false')
            ? render(entry.value)
            : entry.value,
    };
  }

  Map<String, dynamic> render(Map<String, dynamic> data) {
    if (state == null) return data;
    final draft = state!, assignments = stingerMap(draft['assignments']);
    final removed = (draft['removed_assets'] as List? ?? []).toSet();
    Map<String, dynamic> material(Map<String, dynamic> a) {
      final edit = stingerMap(
        stingerMap(draft['asset_edits'])[a['id']] ?? stingerDefaultEdit(a),
      );
      final cached = stingerMap(
        _materialPreviews['${a['id']}|${stingerSignature(edit)}'] ??
            stingerMap(a['material_previews'])[stingerSignature(edit)] ??
            a['preview'],
      );
      return {
        ...a,
        'name': stingerMap(draft['asset_names'])[a['id']] ?? a['name'],
        'edit': edit,
        'preview':
            cached['path'] != null &&
                stingerSignature(cached['edit']) == stingerSignature(edit)
            ? cached
            : {
                ...stingerMap(a['source_preview']),
                'clip_start': edit['start'],
                'clip_end': edit['end'],
                'clip_gain': edit['gain_db'],
              },
      };
    }

    final assets = [
      for (final a in stingerMaps(data['assets']))
        if (!removed.contains(a['id'])) material(a),
    ];
    final byId = {for (final a in assets) a['id']: a};
    final stations = <Map<String, dynamic>>[];
    for (final station in stingerMaps(data['stations'])) {
      final previous = stingerMaps(station['slots']);
      final original =
          (station['original_count'] as num?)?.toInt() ?? previous.length;
      final slots = <Map<String, dynamic>>[];
      for (var i = 0; i < original; i++) {
        final base = previous[i];
        final name = base['sound_name'];
        final id = '${base['id']}';
        final edit = stingerMap(assignments[id]);
        final asset = byId[edit['asset_id']];
        final slot = <String, dynamic>{
          ...base,
          'id': id,
          'sound_name': name,
          'number': i + 1,
          'assignment': assignments[id],
        };
        slot.remove('preview');
        if (edit.isNotEmpty && asset != null) {
          final candidates = [base['preview'], asset['preview']];
          final cached = candidates
              .map(stingerMap)
              .where(
                (p) =>
                    p['path'] != null &&
                    stingerSignature(p['edit']) == stingerSignature(edit),
              )
              .firstOrNull;
          slot['preview'] =
              cached ??
              {
                ...stingerMap(asset['source_preview']),
                'clip_start': edit['start'],
                'clip_end': edit['end'],
                'clip_gain': edit['gain_db'],
              };
        }
        slots.add(slot);
      }
      stations.add({...station, 'slots': slots, 'original_count': original});
    }
    return {
      ...data,
      'assets': assets,
      'stations': stations,
      'draft': snapshot,
      'assignment_count': assignments.keys
          .where((k) => k.contains(':${data['locale']}:'))
          .length,
    };
  }
}

final stingerDraftProvider =
    StateNotifierProvider<StingerDraftController, Map<String, dynamic>?>(
      (ref) => StingerDraftController(ref),
    );
