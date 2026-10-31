import '../widgets/external_audio_drop_target.dart';
import '../core/audio_import_error.dart';
import '../core/voice_audition.dart';
import '../widgets/playlist_toolbar_row.dart';
import '../widgets/timing_dialog_frame.dart';
import '../state/stinger_state.dart';
export '../state/stinger_state.dart'
    show
        stingerMemoryCacheProvider,
        stingerCliProvider,
        stingerRequestOverrideProvider;
import '../state/unsaved_edits.dart';
import 'stingers/stinger_build_dialog.dart';
import '../core/path_keys.dart';
import '../state/editor_shortcuts.dart';
import 'stingers/stinger_assignment.dart';
import 'stingers/stinger_session.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit/media_kit.dart';

import '../core/fh_radio_studio_cli.dart';
import '../core/package_manifest.dart';
import '../core/song_selection.dart';
import '../core/studio_audio_players.dart';
import '../state/layout_options.dart';
import '../state/playlist_plan_state.dart';
import '../state/router.dart';
import '../state/studio_state.dart';
import '../theme/app_theme.dart';
import '../theme/text_styles.dart';
import '../theme/tokens.dart';
import '../widgets/feature_tour.dart';
import '../widgets/audio_import_feedback.dart';
import '../widgets/open_package_folder_button.dart';
import '../widgets/playlist_layout_controls.dart';
import '../widgets/rm_banner.dart';
import '../widgets/rm_button.dart';
import '../widgets/rm_chip.dart';
import '../widgets/rm_icon.dart';
import '../widgets/contained_scroll.dart';
import '../widgets/playlist_search_field.dart';
import '../widgets/pool_selection_actions.dart';
import '../state/playlist_catalog_state.dart';
import '../domain/radio_library.dart';
import 'playlist/playlist_view_switch.dart';
import 'playlist/playlist_drag_preview.dart';
import '../widgets/rm_select.dart';
import 'playlist/playlist_draggable.dart';
import 'playlist/radio_column.dart';
import 'stingers/stinger_card.dart';
import 'stingers/stinger_editor.dart';
import 'stingers/stinger_models.dart';

const _languages = {
  'JP': '日语',
  'CN': '简体中文',
  'EN': '英语',
  'KO': '韩语',
  'TW': '繁体中文',
  'DE': '德语',
  'ES': '西班牙语',
  'IT': '意大利语',
  'BR': '葡萄牙语',
  'MX': '拉美西班牙语',
};

class StingersScreen extends ConsumerStatefulWidget {
  const StingersScreen({super.key});
  @override
  ConsumerState<StingersScreen> createState() => _StingersScreenState();
}

class _StingersScreenState extends ConsumerState<StingersScreen> {
  String? _previewKey;
  int _previewGeneration = 0;
  int _playGeneration = 0;
  Future<void> _audioQueue = Future.value();
  StreamSubscription<bool>? _completed;
  StingerSession? _session;
  String? _sessionKey;
  Player? _audio;
  Player get _player => _audio ??= StudioAudioPlayers.stinger;
  final _search = TextEditingController();
  final _boardScroll = ScrollController();
  Map<String, dynamic>? _data;
  Map<String, dynamic>? _sourceData;
  bool _working = false,
      _gameView = false,
      _selecting = false,
      _reverse = false;
  String _locale = 'JP', _sort = 'name', _status = 'all', _radioFilter = 'all';
  String? _activeAsset;
  final _focus = FocusNode();
  String? _loadedKey, _notice, _error;
  int _cacheDone = 0, _cacheTotal = 0;
  int _importCount = 0;
  CliCancellationToken? _token;
  SongSelection _selection = SongSelection();
  StingerDraftController get _draft => ref.read(stingerDraftProvider.notifier);
  Timer? _rowSnapTimer;
  double _rowExtent = 0;
  bool _snapOnScroll(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is ScrollStartNotification ||
        notification is ScrollUpdateNotification ||
        notification is OverscrollNotification) {
      _rowSnapTimer?.cancel();
      return false;
    }
    if (notification is! ScrollEndNotification ||
        ref.read(stingerLayoutOptionsProvider).heightMode !=
            RadioHeightMode.oneRow) {
      return false;
    }
    _rowSnapTimer?.cancel();
    _rowSnapTimer = Timer(const Duration(milliseconds: 450), () {
      if (!mounted ||
          !_boardScroll.hasClients ||
          _boardScroll.position.isScrollingNotifier.value ||
          _rowExtent <= 0 ||
          ref.read(stingerLayoutOptionsProvider).heightMode !=
              RadioHeightMode.oneRow) {
        return;
      }
      final target = ((_boardScroll.offset / _rowExtent).round() * _rowExtent)
          .clamp(0.0, _boardScroll.position.maxScrollExtent);
      if ((target - _boardScroll.offset).abs() < 1) return;
      _boardScroll.animateTo(
        target,
        duration: const Duration(milliseconds: 190),
        curve: Curves.easeOutCubic,
      );
    });
    return false;
  }

  void _local(Map<String, dynamic> value, [String? notice]) {
    _draft.apply(value);
    if (_data == null || !mounted) return;
    setState(() {
      _data = _draft.render(_sourceData ?? _data!);
      _error = null;
      _notice = notice;
    });
  }

  Future<void> _saveDraft() => _guard(() async {
    await _draft.save();
    if (mounted) setState(() => _notice = '台呼排布已保存，构建准备包后生效。');
  });
  List<Map<String, dynamic>> get _stations => stingerMaps(_data?['stations']);
  List<Map<String, dynamic>> get _assets => stingerMaps(_data?['assets']);
  List<Map<String, dynamic>> get _slots => [
    for (final station in _stations) ...stingerMaps(station['slots']),
  ];
  String get _cacheKey {
    final state = ref.read(studioProvider);
    return '${state.projectDir}|${state.gameDir}|$_locale|$_gameView';
  }

  @override
  void initState() {
    super.initState();
    final language = ref.read(studioProvider).targetLang;
    _locale = const {'CHS': 'CN', 'CHT': 'TW'}[language] ?? language;
    final cached = ref.read(stingerMemoryCacheProvider)[_cacheKey];
    if (cached != null) {
      _sourceData = cached;
      _data = _draft.render(cached);
      _loadedKey = _cacheKey;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (cached != null && !_gameView) {
        _draft.hydrate(cached);
        setState(() => _data = _draft.render(cached));
      }
      _load();
    });
  }

  @override
  void dispose() {
    _rowSnapTimer?.cancel();
    _session?.dispose();
    unawaited(_token?.cancel());
    unawaited(_completed?.cancel());
    unawaited(_audio?.pause());
    _focus.dispose();
    _search.dispose();
    _boardScroll.dispose();
    super.dispose();
  }

  Future<Map<String, dynamic>> _call(
    String action, {
    String? slot,
    String? asset,
    List<String> paths = const [],
    Map<String, dynamic>? input,
  }) async {
    if (!mounted) throw const FormatException('已离开台呼页面。');
    final state = ref.read(studioProvider);
    final request = ref.read(stingerRequestOverrideProvider);
    if (request != null) {
      return request(action, {
        'slot': slot,
        'asset': asset,
        'paths': paths,
        'input': input,
        'locale': _locale,
        'game_view': _gameView,
      });
    }
    final project = state.projectDir;
    final cli = ref.read(stingerCliProvider);
    final sessionKey = '$project|${state.gameDir}';
    if (_sessionKey != sessionKey) {
      _session?.dispose();
      _session = StingerSession(cli, project, state.gameDir);
      _sessionKey = sessionKey;
    }
    if (action != 'warm-cache' || _data != null) {
      final result = await _session!.call(
        action,
        locale: _locale,
        gameView: _gameView,
        slot: slot,
        asset: asset,
        paths: paths,
        input: input,
      );
      if (!mounted || project != ref.read(studioProvider).projectDir) {
        throw const FormatException('工程已切换，请重新读取台呼');
      }
      return result;
    }
    final tools = cli.uvRuntime.audioToolsDir;
    final token = _token = CliCancellationToken();
    final result = await cli.runBase(
      [
        'stingers',
        action,
        '--project-dir',
        project,
        '--game-dir',
        state.gameDir,
        '--locale',
        _locale,
        if (_gameView) '--current-game',
        if (action == 'warm-cache') '--progress-jsonl',
        if (slot != null) ...['--slot', slot],
        if (asset != null) ...['--asset-id', asset],
        if (paths.isNotEmpty) ...['--paths', ...paths],
        '--ffmpeg',
        '$tools/ffmpeg/ffmpeg.exe',
        '--vgmstream-cli',
        '$tools/vgmstream/vgmstream-cli.exe',
      ],
      stdinInput: input == null ? null : jsonEncode(input),
      cancellationToken: token,
      onStdout: (line) {
        if (mounted && line.startsWith('FH_STINGER_CACHE_PROGRESS ')) {
          final progress =
              jsonDecode(line.substring('FH_STINGER_CACHE_PROGRESS '.length))
                  as Map;
          setState(() {
            _cacheDone = (progress['done'] as num).toInt();
            _cacheTotal = (progress['total'] as num).toInt();
          });
        }
      },
    );
    if (!mounted || project != ref.read(studioProvider).projectDir) {
      throw const FormatException('工程已切换，请重新读取台呼');
    }
    if (!result.ok) {
      throw FormatException(
        result.cancelled ? '缓存已停止；已完成的缓存会保留。' : result.stderr.trim(),
      );
    }
    final json = const LineSplitter()
        .convert(result.stdout)
        .lastWhere((line) => line.startsWith('{'));
    return stingerMap(jsonDecode(json));
  }

  Future<void> _guard(Future<void> Function() action) async {
    if (!mounted || _working) return;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await action();
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = '$error'.replaceFirst('FormatException: ', ''));
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _reload() async {
    final key = _cacheKey;
    var data = await _call('warm-cache');
    if (!mounted || key != _cacheKey) return;
    _sourceData = data;
    if (!_gameView) {
      _draft.hydrate(data);
      data = _draft.render(data);
    }
    if (!mounted || key != _cacheKey) return;
    ref.read(stingerMemoryCacheProvider.notifier).state = {
      ...ref.read(stingerMemoryCacheProvider),
      key: _sourceData!,
      if (!_gameView && data['game_view'] is Map)
        '${ref.read(studioProvider).projectDir}|${ref.read(studioProvider).gameDir}|$_locale|true':
            stingerMap(data['game_view']),
    };
    setState(() {
      _data = data;
      _loadedKey = key;
    });
  }

  Future<void> _load({bool force = false}) async {
    if (_working || (!force && _data != null && _loadedKey == _cacheKey)) {
      return;
    }
    await _stopPreview();
    if (!mounted) return;
    final key = _cacheKey;
    if (force) {
      final prefix = key.substring(0, key.lastIndexOf('|') + 1);
      ref.read(stingerMemoryCacheProvider.notifier).state = {
        for (final e in ref.read(stingerMemoryCacheProvider).entries)
          if (!e.key.startsWith(prefix)) e.key: e.value,
      };
    }
    final cached = ref.read(stingerMemoryCacheProvider)[key];
    _selection = SongSelection();
    if (!force && cached != null) {
      setState(() {
        if (!_gameView) _draft.hydrate(cached);
        _sourceData = cached;
        _data = _gameView ? cached : _draft.render(cached);
        _loadedKey = key;
      });
      return;
    }
    await _guard(() async {
      setState(() {
        _data = null;
        _loadedKey = key;
        _cacheDone = 0;
        _cacheTotal = 0;
      });
      await _reload();
    });
  }

  Future<void> _import() async {
    final files = await FilePicker.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: ['wav', 'flac', 'mp3', 'ogg', 'aiff', 'm4a', 'aac'],
      dialogTitle: '导入台呼音频',
    );
    final paths = files?.paths.whereType<String>().toList() ?? [];
    if (paths.isNotEmpty) await _importPaths(paths);
  }

  Future<void> _importPaths(
    List<String> paths, {
    Map<String, dynamic>? target,
  }) async {
    if (!mounted ||
        _working ||
        _gameView ||
        ref.read(studioProvider).projectEditingLocked) {
      return;
    }
    final ids = <String>[];
    setState(() => _importCount = paths.length);
    try {
      await _guard(() async {
        final data = await _call('import', paths: paths);
        ids.addAll((data['asset_ids'] as List? ?? []).map((v) => '$v'));
        await _reload();
        if (mounted) setState(() => _notice = '素材已导入并缓存，可双击编辑或拖入电台位置。');
      });
    } finally {
      if (mounted) setState(() => _importCount = 0);
    }
    if (!mounted) return;
    if (_error != null) {
      setState(() => _error = audioImportErrorDetail(_error!));
    }
    showAudioImportResult(
      context,
      _error != null
          ? '台呼导入未完成：$_error'
          : '台呼导入完成，已准备 ${ids.toSet().length} 个素材；已有素材会复用。',
    );
    if (mounted && target != null && ids.isNotEmpty) {
      await _drop(StingerDrag(ids), target);
    }
  }

  Future<void> _play(
    Map<String, dynamic> payload, {
    double? start,
    double? end,
    double gain = 0,
  }) async {
    final generation = ++_playGeneration;
    final previous = _audioQueue;
    final task = () async {
      await previous;
      if (!mounted || generation != _playGeneration) return;
      await StudioAudioPlayers.pauseOthers(_player);
      if (!mounted || generation != _playGeneration) return;
      await startVoiceAudition(
        _player,
        '${payload['path']}',
        start: start ?? 0,
        end: end,
        gainDb: gain,
        isCurrent: () => mounted && generation == _playGeneration,
      );
      if (generation != _playGeneration) await _audio?.stop();
      if (mounted) setState(() {});
    }();
    _audioQueue = task.catchError((Object _) {});
    await task;
  }

  Future<void> _stopPreview() async {
    _previewGeneration++;
    _playGeneration++;
    if (mounted) setState(() => _previewKey = null);
    await _audioQueue;
    await _audio?.stop();
  }

  Future<void> _quickPlay(String key, Map<String, dynamic> audio) async {
    if (_previewKey == key) {
      await _stopPreview();
      return;
    }
    final generation = ++_previewGeneration;
    setState(() => _previewKey = key);
    try {
      await _play(
        audio,
        start: (audio['clip_start'] as num?)?.toDouble(),
        end: (audio['clip_end'] as num?)?.toDouble(),
        gain: (audio['clip_gain'] as num?)?.toDouble() ?? 0,
      );
      if (!mounted || generation != _previewGeneration) {
        return;
      }
      setState(() => _previewKey = key);
      _completed ??= _player.stream.completed.listen((done) {
        if (done && mounted) setState(() => _previewKey = null);
      });
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _previewKey = null;
          _error = '试听未开始：$error';
        });
      }
    }
  }

  Future<void> _playSlot(Map<String, dynamic> slot) => _quickPlay(
    'slot:${slot['id']}',
    stingerMap(
      _gameView
          ? slot['original_preview']
          : slot['preview'] ?? slot['original_preview'],
    ),
  );

  Future<void> _mutate(String action, Map<String, dynamic> input) async {
    if (!mounted ||
        _working ||
        _gameView ||
        ref.read(studioProvider).projectEditingLocked) {
      return;
    }
    if (action == 'copy-game') {
      await _guard(() async {
        final result = await _call('copy-game-draft');
        if (!mounted) return;
        final data = stingerMap(result['data']);
        final incoming = stingerMap(data['draft']);
        _draft.hydrate(data);
        final next = _draft.snapshot;
        final assignments = stingerMap(next['assignments'])
          ..removeWhere((k, _) => k.contains(':$_locale:'));
        assignments.addAll(
          stingerMap(incoming['assignments']).map((k, v) => MapEntry(k, v))
            ..removeWhere((k, _) => !k.contains(':$_locale:')),
        );
        next['assignments'] = assignments;
        _local(next);
        if (result['needs_cache'] == true) await _reload();
      });
      return;
    }
    final next = _draft.snapshot,
        assignments = stingerMap(_draft.snapshot['assignments']);
    if (action == 'set-assignments') {
      final changes = stingerMap(input['changes']);
      if (_previewKey?.startsWith('slot:') == true &&
          changes.containsKey(_previewKey!.substring(5))) {
        unawaited(_stopPreview());
      }
      for (final entry in changes.entries) {
        if (entry.value == null) {
          assignments.remove(entry.key);
        } else {
          assignments[entry.key] = entry.value;
        }
      }
    }
    next['assignments'] = assignments;
    _local(next);
  }

  Future<void> _history(bool redo) async {
    if (_working || _gameView) return;
    if (redo) {
      _draft.redo();
    } else {
      _draft.undo();
    }
    if (mounted && _data != null) {
      setState(() {
        _data = _draft.render(_sourceData ?? _data!);
        _notice = null;
        _error = null;
      });
    }
  }

  Future<void> _edit({
    Map<String, dynamic>? station,
    Map<String, dynamic>? slot,
    Map<String, dynamic>? asset,
  }) async {
    if (_working || ref.read(studioProvider).busy) return;
    await _stopPreview();
    if (!mounted) return;
    final assetId =
        '${asset?['id'] ?? stingerMap(slot?['assignment'])['asset_id'] ?? ''}';
    final configured = ref.read(studioProvider).radio;
    final usedRadios = [
      for (final s in _stations)
        if (stingerMaps(
          s['slots'],
        ).any((slot) => stingerMap(slot['assignment'])['asset_id'] == assetId))
          s['radio'] as int,
    ];
    final radio =
        station?['radio'] as int? ??
        (usedRadios.contains(configured)
            ? configured
            : usedRadios.firstOrNull ?? configured);
    final plan = ref.read(effectivePlaylistPlanProvider);
    final roaming = plan.assignmentsForRadio('R$radio', 'FreeRoam');
    final assigned = roaming.isNotEmpty
        ? roaming
        : plan.assignmentsForRadio('R$radio', 'Event');
    final songs = stingerMaps(_data?['songs']);
    final preferred = [
      for (final entry in assigned)
        for (final song in songs)
          if (sameCanonicalPath(entry.source, '${song['path']}'))
            '${song['path']}',
    ];
    final previewSlot =
        slot ??
        stingerMaps(
          _stations.firstWhere(
            (s) => s['radio'] == radio,
            orElse: () => _stations.first,
          )['slots'],
        ).first;
    Map<String, dynamic>? saved;
    final result = await showStingerEditor(
      context,
      station: station,
      slot: slot,
      asset: asset,
      assets: _assets,
      songs: stingerMaps(_data?['songs']),
      player: _player,
      preferredWidth: ref.read(layoutOptionsProvider).manualRefineWidth,
      readOnly: _gameView || ref.read(studioProvider).projectEditingLocked,
      contextKey: '${ref.read(studioProvider).projectDir}|R$radio',
      preferredSongs: preferred,
      usedCount: _slots
          .where((s) => stingerMap(s['assignment'])['asset_id'] == assetId)
          .length,
      play: _play,
      deferSave: true,
      onSaved: (value) => saved = value,
      call: (action, input) async {
        if (!mounted) return {};
        if (action == 'update' || action == 'update-asset') {
          final next = _draft.snapshot;
          final edit = {
            for (final key in [
              'asset_id',
              'start',
              'end',
              'gain_db',
              'next_track',
              'audio_edits',
            ])
              key: key == 'audio_edits'
                  ? input[key] ?? <dynamic>[]
                  : input[key],
          };
          final assignments = stingerMap(next['assignments']);
          if (action == 'update-asset') {
            next['asset_edits'] = {
              ...stingerMap(next['asset_edits']),
              '${asset!['id']}': edit,
            };
            next['asset_names'] = {
              ...stingerMap(next['asset_names']),
              '${asset['id']}': input['name'],
            };
            for (final key in assignments.keys.toList()) {
              if (stingerMap(assignments[key])['asset_id'] == asset['id']) {
                assignments[key] = edit;
              }
            }
          } else if (input['asset_id'] == null) {
            assignments.remove('${slot!['id']}');
          } else {
            assignments['${slot!['id']}'] = edit;
          }
          next['assignments'] = assignments;
          _local(next, '选段已应用到台呼草稿；请在页面顶部保存。');
          return {'saved': true};
        }
        return _call(
          action == 'preview' ? 'asset-preview' : action,
          input: input,
          slot: (action == 'seam' ? previewSlot['id'] : slot?['id']) as String?,
          asset: '${input['asset_id'] ?? asset?['id'] ?? ''}',
        );
      },
    );
    await _audio?.stop();
    if (result == true && mounted && saved != null) {
      setState(() => _notice = '选段已应用到草稿；请在页面顶部保存台呼。');
    }
  }

  Future<void> _drop(StingerDrag drag, Map<String, dynamic> slot) async {
    if (_working || _gameView) return;
    try {
      final changes = stingerDropChanges(
        slots: _slots,
        assets: _assets,
        drag: drag,
        targetId: '${slot['id']}',
        copy: HardwareKeyboard.instance.isControlPressed,
      );
      if (changes.isEmpty) return;
      await _mutate('set-assignments', {'changes': changes});
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = '$error'.replaceFirst('FormatException: ', ''));
      }
    }
  }

  Future<bool> _confirm(
    String title,
    String body, {
    String confirm = '确认',
    bool danger = false,
  }) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) {
          final rm = context.rm;
          return TimingDialogFrame(
            title: title,
            icon: danger ? 'trash' : 'info',
            busy: false,
            width: 520,
            body: Text(body, style: RmText.body(color: rm.fg3)),
            actions: [
              RmButton(
                label: '取消',
                onPressed: () => Navigator.pop(context, false),
              ),
              RmButton(
                label: confirm,
                variant: danger
                    ? RmButtonVariant.dangerPrimary
                    : RmButtonVariant.primary,
                onPressed: () => Navigator.pop(context, true),
              ),
            ],
          );
        },
      ) ??
      false;

  Future<void> _restoreRadio(Map<String, dynamic> station) async {
    final changed = stingerMaps(
      station['slots'],
    ).where((s) => s['assignment'] != null).toList();
    if (changed.isEmpty) return;
    if (await _confirm(
      '恢复 ${station['name']} 的原有台呼？',
      '将清除 ${changed.length} 个位置的替换分配，素材保留在池中。构建准备包后生效，可撤销。',
      confirm: '恢复原有台呼',
    )) {
      await _mutate('set-assignments', {
        'changes': {for (final s in changed) '${s['id']}': null},
      });
    }
  }

  Future<void> _removeAssets(List<String> ids) async {
    if (!mounted) return;
    final used = stingerMap(_draft.snapshot['assignments']).values.any(
      (assignment) => ids.contains(stingerMap(assignment)['asset_id']),
    );
    if (used) {
      setState(() => _error = '所选素材仍被台呼使用（含其他语音语言），请先清除对应分配。');
      return;
    }
    if (!await _confirm(
      '移除 ${ids.length} 个素材？',
      '只从当前台呼素材池移除，导入前的音频文件不受影响。',
      confirm: '移除素材',
      danger: true,
    )) {
      return;
    }
    final next = _draft.snapshot;
    next['removed_assets'] = {
      ...(next['removed_assets'] as List? ?? []),
      ...ids,
    }.toList();
    _selection = SongSelection();
    _local(next, '素材已从草稿移除，保存后生效。');
  }

  Future<void> _chooseTarget(List<String> ids) async {
    if (ids.isEmpty || _working || _gameView) return;
    final choice = await showDialog<Map<String, int>>(
      context: context,
      builder: (_) => StingerAssignDialog(
        stations: _stations,
        count: ids.length,
        radio: ref.read(studioProvider).radio,
      ),
    );
    if (choice == null || !mounted) return;
    final station = _stations.firstWhere((s) => s['radio'] == choice['radio']);
    final slot = stingerMaps(station['slots'])[choice['start']! - 1];
    await _drop(StingerDrag(ids), slot);
  }

  Future<void> _copyGame() async {
    if (await _confirm(
      '复制游戏内台呼排布？',
      '当前语音语言的台呼分配将与游戏内一致，素材保留，可撤销。',
      confirm: '复制排布',
    )) {
      await _mutate('copy-game', {});
    }
  }

  Future<void> _buildPackage() async {
    if (!await ref.read(unsavedEditsProvider).confirmForBuild(context) ||
        !mounted) {
      return;
    }
    await _stopPreview();
    if (!mounted) return;
    final before = ref.read(studioProvider);
    final manifest = readPackageManifest(before.lastPackageDir);
    final quality = stingerNumber(
      manifest?['quality'],
      50,
    ).round().clamp(1, 100);
    final plan = ref.read(effectivePlaylistPlanProvider);
    var auditionActive = true;
    final gain = await showDialog<double>(
      context: context,
      builder: (_) => StingerBuildDialog(
        stations: _stations,
        initialGain: stingerNumber(
          stingerMap(manifest?['stingers'])['gain_db'],
        ),
        quality: quality,
        restoredRadios:
            plan.builtinTargets.map((t) => t.split('|').first).toSet().toList()
              ..sort(),
        preview: (edit) =>
            _call('asset-preview', asset: '${edit['asset_id']}', input: edit),
        play: (audio) async {
          if (auditionActive) await _play(audio);
        },
        stop: _stopPreview,
      ),
    );
    auditionActive = false;
    if (!mounted) return;
    await _stopPreview();
    if (gain == null || !mounted) return;
    await _guard(() async {
      final oldLog = before.log.toSet();
      final success = await ref
          .read(studioProvider.notifier)
          .buildPackage(
            plan: plan,
            quality: quality,
            stingerGainDb: gain,
            loudnessOffsetLu: stingerNumber(manifest?['loudness_offset_lu'], 3),
          );
      if (!mounted) return;
      setState(() {
        final delta = stingerMap(
          readPackageManifest(
            ref.read(studioProvider).lastPackageDir,
          )?['package_delta'],
        );
        _notice = !success
            ? null
            : delta['no_changes'] == true
            ? '当前配置与游戏一致，无需写入。'
            : '准备包已构建：仅保留实际改动及必要配置${delta['file_count'] == null ? '' : '，共 ${delta['file_count']} 个文件'}。可前往概览写入游戏。';
        if (ref.read(studioProvider).packageBuildCancelled) {
          _notice = '构建已停止，上次完成的准备包与分配已保留。';
        } else if (!success) {
          final lines = ref
              .read(studioProvider)
              .log
              .where((l) => !oldLog.contains(l))
              .toList();
          final errors = lines.where((l) => l.startsWith('ERR ')).toList();
          _error = (errors.isEmpty ? lines : errors).reversed
              .take(6)
              .toList()
              .reversed
              .join('\n');
        }
      });
    });
  }

  List<Map<String, dynamic>> get _visibleAssets {
    final query = _search.text.trim().toLowerCase();
    final assets = _assets.where((a) {
      final uses = _slots
          .where((s) => stingerMap(s['assignment'])['asset_id'] == a['id'])
          .toList();
      return (query.isEmpty || '${a['name']}'.toLowerCase().contains(query)) &&
          (_status == 'all' ||
              (_status == 'used' ? uses.isNotEmpty : uses.isEmpty)) &&
          (_radioFilter == 'all' ||
              uses.any((s) => '${s['id']}'.startsWith('$_radioFilter:')));
    }).toList();
    assets.sort((a, b) {
      final by = _sort == 'duration'
          ? (stingerNumber(stingerMap(a['edit'])['end']) -
                    stingerNumber(stingerMap(a['edit'])['start']))
                .compareTo(
                  stingerNumber(stingerMap(b['edit'])['end']) -
                      stingerNumber(stingerMap(b['edit'])['start']),
                )
          : '${a['name']}'.toLowerCase().compareTo(
              '${b['name']}'.toLowerCase(),
            );
      return _reverse ? -by : by;
    });
    return assets;
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || ModalRoute.of(context)?.isCurrent == false) {
      return KeyEventResult.ignored;
    }
    final typing =
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorStateOfType<EditableTextState>() !=
        null;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      setState(() {
        _selection = SongSelection();
        _selecting = false;
      });
      return KeyEventResult.handled;
    }
    if (typing || _working || _gameView) return KeyEventResult.ignored;
    final keys = ref.read(editorShortcutsProvider),
        keyboard = HardwareKeyboard.instance;
    final ids = _selection.ids.isNotEmpty
        ? _visibleAssets
              .where((a) => _selection.ids.contains(a['id']))
              .map((a) => '${a['id']}')
              .toList()
        : _visibleAssets.any((a) => a['id'] == _activeAsset)
        ? [_activeAsset!]
        : <String>[];
    if (keys[EditorAction.assign]!.matches(
          event,
          ctrl: keyboard.isControlPressed,
          shift: keyboard.isShiftPressed,
          alt: keyboard.isAltPressed,
          meta: keyboard.isMetaPressed,
        ) &&
        ids.isNotEmpty) {
      unawaited(_chooseTarget(ids));
      return KeyEventResult.handled;
    }
    if (keys[EditorAction.save]!.matches(
      event,
      ctrl: keyboard.isControlPressed,
      shift: keyboard.isShiftPressed,
      alt: keyboard.isAltPressed,
      meta: keyboard.isMetaPressed,
    )) {
      unawaited(_saveDraft());
      return KeyEventResult.handled;
    }
    if (HardwareKeyboard.instance.isControlPressed) {
      if (event.logicalKey == LogicalKeyboardKey.keyZ &&
          !keyboard.isShiftPressed) {
        unawaited(_history(false));
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.keyY) {
        unawaited(_history(true));
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.keyA) {
        setState(
          () => _selection = SongSelection(
            ids: _visibleAssets.map((a) => '${a['id']}').toSet(),
          ),
        );
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final rm = context.rm,
        state = ref.watch(studioProvider),
        layout = ref.watch(layoutOptionsProvider);
    ref.watch(stingerDraftProvider);
    final busy = _working || state.busy,
        locked = busy || _gameView || state.projectEditingLocked;
    final previewWarnings = (_data?['preview_warnings'] as List? ?? []).join(
      '\n',
    );
    final voice =
        const {'CHS': 'CN', 'CHT': 'TW'}[state.targetLang] ?? state.targetLang;
    if (voice != _locale && !_working) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && voice != _locale) {
          setState(() => _locale = voice);
          _load();
        }
      });
    } else if (_loadedKey != null && _loadedKey != _cacheKey && !_working) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    }
    return Focus(
          autofocus: true,
          focusNode: _focus,
          onKeyEvent: _key,
          child: ContainedScroll(
            controller: _boardScroll,
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: layout.pageWidth(1280)),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(40, 24, 40, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      LayoutBuilder(
                        builder: (context, c) {
                          final heading = Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('电台台呼', style: RmText.pageH1(color: rm.fg)),
                              const SizedBox(height: 6),
                              Text(
                                _gameView
                                    ? '查看当前游戏内台呼；编辑请切回准备包。'
                                    : '双击编辑 · 拖入分配 · 台呼间拖动交换 · Ctrl 拖动复制 · 拖回池子清除分配；保存后与歌曲一起构建。',
                                style: RmText.body(color: rm.fg3),
                              ),
                            ],
                          );
                          final actions = Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              OpenPackageFolderButton(
                                path: state.lastPackageDeployDir,
                              ),
                              RmButton(
                                key: const ValueKey('stinger-save'),
                                label: '保存台呼',
                                leading: const RmIcon('check', size: 12),
                                onPressed: locked || !_draft.dirty
                                    ? null
                                    : _saveDraft,
                              ).tourAnchor('save'),
                              RmButton(
                                key: const ValueKey('stinger-build'),
                                label: '构建准备包',
                                leading: const RmIcon('music', size: 12),
                                variant: RmButtonVariant.primary,
                                onPressed: locked ? null : _buildPackage,
                              ).tourAnchor('build'),
                            ],
                          );
                          return c.maxWidth > 850
                              ? Row(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Expanded(child: heading),
                                    const SizedBox(width: 16),
                                    actions,
                                  ],
                                )
                              : Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    heading,
                                    const SizedBox(height: 12),
                                    actions,
                                  ],
                                );
                        },
                      ),
                      if (previewWarnings.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: RmBanner(
                            kind: RmBannerKind.warn,
                            title: '部分素材预览未就绪',
                            body:
                                '$previewWarnings\n可继续编辑素材并调整音量或选段；构建时仍会校验音频。',
                          ),
                        ),
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: rm.panel,
                          border: Border.all(color: rm.border),
                          borderRadius: BorderRadius.circular(RmTokens.rLg),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _toolbar(busy, locked).tourAnchor('view'),
                            const SizedBox(height: 10),
                            PlaylistSearchRow(
                              search: _searchBox(),
                            ).tourAnchor('search'),
                            LayoutBuilder(
                              builder: (context, c) => PlaylistLayoutControls(
                                controllerProvider:
                                    stingerLayoutOptionsProvider,
                                showHeight: true,
                                topSpacing: 2,
                                availableRadioWidth:
                                    LayoutOptions.radioWidthFor(
                                      c.maxWidth,
                                      withPool: !_gameView,
                                    ),
                              ),
                            ).tourAnchor('layout'),
                          ],
                        ),
                      ),
                      if (_error != null || _notice != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: RmBanner(
                            kind: _error != null
                                ? RmBannerKind.danger
                                : RmBannerKind.info,
                            title: _error != null ? '操作未完成' : '台呼工程',
                            body: _error ?? _notice!,
                            action: _error == null && _notice!.contains('可前往')
                                ? RmButton(
                                    label: '前往概览写入游戏',
                                    variant: RmButtonVariant.primary,
                                    leading: const RmIcon(
                                      'arrow-right',
                                      size: 13,
                                    ),
                                    onPressed: () =>
                                        context.go(RmRoutes.dashboard),
                                  )
                                : null,
                          ),
                        ),
                      const SizedBox(height: 14),
                      Expanded(
                        child: _data == null
                            ? _loading()
                            : _board(busy, locked),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        )
        .withAudioImportProgress(count: _importCount, noun: '台呼素材')
        .withFeatureTour(TourPage.stingers, enabled: _data != null && !busy);
  }

  Widget _toolbar(bool busy, bool locked) {
    final view = Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        PlaylistViewSwitch(
          value: _gameView
              ? PlaylistCatalogView.game
              : PlaylistCatalogView.package,
          onChanged: (v) {
            if (!busy) {
              _audio?.stop();
              setState(() {
                _gameView = v == PlaylistCatalogView.game;
                _previewKey = null;
              });
              _load();
            }
          },
        ),
        RmChip(
          label: _gameView ? '当前游戏内' : '当前准备包',
          showDot: true,
          variant: _gameView ? RmChipVariant.info : RmChipVariant.accent,
        ),
        if (!_gameView)
          RmButton(
            label: '复制游戏内排布',
            leading: const RmIcon('copy', size: 12),
            onPressed: locked ? null : _copyGame,
          ),
      ],
    );
    final history = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        RmButton(
          key: const ValueKey('stinger-undo'),
          label: '撤销',
          size: RmButtonSize.sm,
          leading: const RmIcon('undo', size: 12),
          tooltip: '撤销 · Ctrl+Z',
          onPressed: locked || !_draft.canUndo ? null : () => _history(false),
        ),
        const SizedBox(width: 6),
        RmButton(
          key: const ValueKey('stinger-redo'),
          label: '重做',
          size: RmButtonSize.sm,
          leading: const RmIcon('redo', size: 12),
          tooltip: '重做 · Ctrl+Y',
          onPressed: locked || !_draft.canRedo ? null : () => _history(true),
        ),
      ],
    );
    final right = Wrap(
      spacing: 12,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        history,
        RmChip(
          key: const ValueKey('stinger-cache-ready'),
          label: _gameView
              ? '只读查看'
              : '${_data?['assignment_count'] ?? 0} 条替换 · ${_draft.dirty ? '未保存' : '已保存'}',
          variant: _gameView
              ? RmChipVariant.muted
              : _draft.dirty
              ? RmChipVariant.warn
              : RmChipVariant.accent,
          showDot: true,
        ),
      ],
    );
    return PlaylistToolbarRow(leading: view, trailing: right);
  }

  Widget _searchBox() => PlaylistSearchField(
    key: const ValueKey('stinger-search'),
    controller: _search,
    hint: '搜索素材名称',
    onChanged: (_) => setState(() {}),
  );

  Widget _loading() {
    final rm = context.rm;
    return Center(
      child: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _working ? '正在准备台呼缓存' : '尚未读取台呼',
              style: RmText.sans(15, color: rm.fg, weight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            if (_working)
              LinearProgressIndicator(
                value: _cacheTotal > 0 ? _cacheDone / _cacheTotal : null,
                color: rm.accent.base,
                minHeight: 3,
              ),
            const SizedBox(height: 10),
            Text(
              _cacheTotal > 0
                  ? '$_cacheDone / $_cacheTotal · 首次解码，之后直接试听和编辑'
                  : '首次读取会缓存原台呼和波形，缓存保存在当前工程。',
              style: RmText.sans(12, color: rm.fg3),
              textAlign: TextAlign.center,
            ),
            if (_working) ...[
              const SizedBox(height: 12),
              RmButton(label: '停止并返回', onPressed: () => _token?.cancel()),
            ],
          ],
        ),
      ),
    );
  }

  Widget _board(bool busy, bool locked) => LayoutBuilder(
    builder: (context, c) {
      final poolWidth = LayoutOptions.poolWidthFor(c.maxWidth);
      final showPool = !_gameView;
      final width = LayoutOptions.radioWidthFor(c.maxWidth, withPool: showPool);
      final options = ref.watch(stingerLayoutOptionsProvider);
      // Search only filters entries, never the set/width of station columns.
      final stations = _stations;
      final count = math.min(
        math.max(1, stations.length),
        options.columnsFor(width),
      );
      final columnWidth = (width - 12 * (count - 1)) / count;
      final height = options.heightFor(
        c.maxHeight,
        math.max(1, stations.length),
        count,
      );
      _rowExtent = height + 12;
      final board = NotificationListener<ScrollNotification>(
        onNotification: _snapOnScroll,
        child: SingleChildScrollView(
          key: const ValueKey('stinger-radio-board'),
          controller: _boardScroll,
          primary: false,
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final station in stations)
                SizedBox(
                  width: columnWidth,
                  height: height,
                  child: _radio(station, busy, locked),
                ),
            ],
          ),
        ),
      );
      if (!showPool) return board.tourAnchor('board');
      if (c.maxWidth < LayoutOptions.minColumnWidth + 12 + 160) {
        return SingleChildScrollView(
          child: Column(
            children: [
              SizedBox(height: 480, child: board.tourAnchor('board')),
              const SizedBox(height: 12),
              SizedBox(
                height: 420,
                child: _pool(busy, locked).tourAnchor('import'),
              ),
            ],
          ),
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: board.tourAnchor('board')),
          const SizedBox(width: 12),
          SizedBox(
            width: poolWidth,
            child: _pool(busy, locked).tourAnchor('import'),
          ),
        ],
      );
    },
  );

  bool _slotMatches(Map<String, dynamic> slot, String query) {
    final asset = _assets
        .where((a) => a['id'] == stingerMap(slot['assignment'])['asset_id'])
        .firstOrNull;
    return asset != null && '${asset['name']}'.toLowerCase().contains(query);
  }

  Widget _radio(Map<String, dynamic> station, bool busy, bool locked) {
    final rm = context.rm, slots = stingerMaps(station['slots']);
    final changed = slots.where((s) => s['assignment'] != null).length;
    final query = _search.text.trim().toLowerCase();
    final visible = slots;
    final header = RadioColumnHeader(
      radio: RadioStation(
        code: 'R${station['radio']}',
        name: '${station['name']}',
        hue: const [
          'lime',
          'magenta',
          'orange',
          'violet',
          'yellow',
          'teal',
          'red',
          'cyan',
          'cyan',
        ][((station['radio'] as int) - 1).clamp(0, 8)],
        genre: '${_languages[_locale] ?? _locale} · 转场台呼',
        slot: slots.length,
      ),
      isCustom: changed > 0 && !_gameView,
      count: changed,
      capacity: slots.length,
      pendingCount: 0,
      expanded: false,
      originalCount: slots.length,
      restoreTooltip: '恢复此电台原有台呼',
      onRestoreBuiltin:
          locked ||
              changed == 0 &&
                  slots.length <= (station['original_count'] as num? ?? 10)
          ? null
          : () => _restoreRadio(station),
    );
    return PlaylistColumn.builder(
      key: ValueKey('stinger-radio-${station['radio']}'),
      fitContents: false,
      kind: ColumnKind.customRadio,
      header: header,
      metadataPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      metadata: SizedBox(
        height: 18,
        child: Row(
          children: [
            Expanded(
              child: Text(
                '${slots.length} 个位置 · ${_gameView
                    ? '当前游戏'
                    : changed == 0
                    ? '沿用原台呼'
                    : '已替换 $changed 条'}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: RmText.mono(10.5, color: rm.fg3),
              ),
            ),
          ],
        ),
      ),
      itemCount: visible.length,
      emptyText: '没有符合条件的台呼',
      itemBuilder: (context, i) {
        final slot = visible[i], edit = stingerMap(slot['assignment']);
        final asset = _assets
            .where((a) => a['id'] == edit['asset_id'])
            .firstOrNull;
        return ExternalAudioDropTarget(
          enabled: !locked && !busy,
          onDrop: (paths) => _importPaths(paths, target: slot),
          child: DragTarget<StingerDrag>(
            onWillAcceptWithDetails: (d) =>
                !locked && d.data.sourceSlot != slot['id'],
            onAcceptWithDetails: (d) => _drop(d.data, slot),
            builder: (context, candidates, rejected) {
              final card = StingerCard(
                dragBuilder: locked || asset == null
                    ? null
                    : (body) => PlaylistDraggable<StingerDrag>(
                        data: StingerDrag([
                          '${asset['id']}',
                        ], sourceSlot: '${slot['id']}'),
                        feedback: _feedback(['${asset['id']}']),
                        childWhenDragging: Opacity(opacity: .35, child: body),
                        child: body,
                      ),
                key: ValueKey('stinger-slot-${slot['id']}'),
                title: _gameView || asset == null
                    ? '台呼 ${'${slot['number']}'.padLeft(2, '0')}'
                    : '${asset['name']}',
                subtitle: _gameView || asset == null
                    ? '原有转场台呼'
                    : '下一首 ${stingerTime(edit['next_track'])}',
                duration: _gameView || asset == null
                    ? stingerNumber(slot['duration'])
                    : stingerEditedDuration(edit),
                order: (slot['number'] as num).toInt(),
                accent: !_gameView && asset != null,
                dragging: candidates.isNotEmpty,
                playing: _previewKey == 'slot:${slot['id']}',
                onPlay: busy ? null : () => _playSlot(slot),
                onEdit: busy ? null : () => _edit(station: station, slot: slot),
                onRemove: locked || asset == null
                    ? null
                    : () => _mutate('set-assignments', {
                        'changes': {'${slot['id']}': null},
                      }),
              );
              final matches = query.isEmpty || _slotMatches(slot, query);
              final visible = Opacity(opacity: matches ? 1 : .32, child: card);
              return station['radio'] == 1 && i == 0
                  ? visible.tourAnchor('board-end')
                  : visible;
            },
          ),
        );
      },
    );
  }

  Widget _pool(bool busy, bool locked) {
    final rm = context.rm, visible = _visibleAssets;
    final visibleIds = visible.map((a) => '${a['id']}').toList();
    final selected = visibleIds.where(_selection.ids.contains).toList();
    final header = Row(
      children: [
        Expanded(
          child: PlaylistPoolHeader(
            count: _assets.length,
            title: '池子',
            subtitle: '台呼素材',
          ),
        ),
        const SizedBox(width: 6),
        RmButton(
          key: const ValueKey('stinger-import'),
          label: '导入台呼',
          leading: const RmIcon('plus', size: 12),
          size: RmButtonSize.sm,
          onPressed: locked ? null : _import,
        ),
      ],
    );
    final controls = Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: RmSelect<String>(
                  value: _sort,
                  items: const {'name': '素材名称', 'duration': '音频时长'},
                  onChanged: (v) => setState(() => _sort = v),
                ),
              ),
              const SizedBox(width: 6),
              SizedBox(
                width: 90,
                child: RmButton(
                  label: _reverse ? '倒序' : '正序',
                  leading: Icon(_reverse ? Icons.south : Icons.north, size: 12),
                  onPressed: () => setState(() => _reverse = !_reverse),
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Row(
            children: [
              Expanded(
                child: RmSelect<String>(
                  value: _status,
                  items: const {'all': '全部状态', 'used': '已分配', 'unused': '未分配'},
                  onChanged: (v) => setState(() => _status = v),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: RmSelect<String>(
                  value: _radioFilter,
                  items: {
                    'all': '全部电台',
                    for (final s in _stations)
                      'R${s['radio']}': 'R${s['radio']}',
                  },
                  onChanged: (v) => setState(() => _radioFilter = v),
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Row(
            children: [
              Expanded(
                child: Text(
                  _selecting || _activeAsset == null
                      ? 'Ctrl 多选 · Shift 连选'
                      : 'Ctrl + D 分配到电台',
                  style: RmText.sans(10, color: rm.fg3),
                ),
              ),
              if (_selecting && selected.isNotEmpty) ...[
                RmButton.icon(
                  icon: const RmIcon('trash', size: 13),
                  tooltip: '移除所选素材',
                  onPressed: locked ? null : () => _removeAssets(selected),
                ),
                const SizedBox(width: 6),
              ],
              SizedBox(
                width: 90,
                child: RmButton(
                  key: const ValueKey('stinger-pool-multiselect'),
                  label: _selecting ? '退出多选' : '多选',
                  onPressed: locked
                      ? null
                      : () => setState(() {
                          _selecting = !_selecting;
                          if (!_selecting) {
                            _selection = SongSelection();
                            _activeAsset = null;
                          }
                        }),
                ),
              ),
            ],
          ),
          if (_selecting)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: PoolSelectionActions(
                key: const ValueKey('stinger-selection-actions'),
                count: selected.length,
                onSelectAll: locked
                    ? null
                    : () => setState(() {
                        _selection = SongSelection(
                          ids: visible.map((a) => '${a['id']}').toSet(),
                        );
                      }),
                onClear: locked
                    ? null
                    : () => setState(() {
                        _selection = SongSelection();
                        _activeAsset = null;
                      }),
                actions: [
                  RmButton(
                    key: const ValueKey('stinger-batch-assign'),
                    label: '分配至电台',
                    size: RmButtonSize.sm,
                    horizontalPadding: 8,
                    variant: RmButtonVariant.primary,
                    onPressed: locked || selected.isEmpty
                        ? null
                        : () => _chooseTarget(selected),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
    return ExternalAudioDropTarget(
      label: '松开以导入台呼素材',
      enabled: !locked,
      onDrop: _importPaths,
      child: DragTarget<StingerDrag>(
        onWillAcceptWithDetails: (d) => !locked && d.data.sourceSlot != null,
        onAcceptWithDetails: (d) => _mutate('set-assignments', {
          'changes': {d.data.sourceSlot!: null},
        }),
        builder: (context, candidates, rejected) => DecoratedBox(
          decoration: BoxDecoration(
            border: candidates.isEmpty
                ? null
                : Border.all(color: rm.accent.base, width: 2),
            borderRadius: BorderRadius.circular(RmTokens.rLg),
          ),
          child: PlaylistColumn.builder(
            key: const ValueKey('stinger-pool'),
            kind: ColumnKind.pool,
            header: header,
            metadata: Text(
              '${_assets.length} 个素材${visible.length == _assets.length ? '' : ' · 筛选 ${visible.length} 个'}',
              style: RmText.mono(10.5, color: rm.fg3),
            ),
            filterControls: controls,
            itemCount: visible.length,
            emptyText: _assets.isEmpty ? '导入音频后可编辑并分配' : '没有符合条件的素材',
            itemBuilder: (context, i) {
              final asset = visible[i],
                  id = '${asset['id']}',
                  edit = stingerMap(asset['edit']);
              final used = _slots
                  .where((s) => stingerMap(s['assignment'])['asset_id'] == id)
                  .map((s) => '${s['id']}'.split(':').first)
                  .toSet();
              final ids = _selection.ids.contains(id) ? selected : [id];
              final card = StingerCard(
                dragBuilder: (body) => PlaylistDraggable<StingerDrag>(
                  data: StingerDrag(ids),
                  maxSimultaneousDrags: locked ? 0 : 1,
                  feedback: _feedback(ids),
                  childWhenDragging: Opacity(opacity: .35, child: body),
                  child: body,
                ),
                key: ValueKey('stinger-asset-$id'),
                onActivate: () {
                  _focus.requestFocus();
                  setState(() => _activeAsset = id);
                },
                title: '${asset['name']}',
                order: _assets.indexWhere((a) => a['id'] == id) + 1,
                numberOnly: true,
                subtitle: used.isEmpty ? '未分配' : used.join(' · '),
                duration: stingerEditedDuration(edit),
                accent: true,
                selected: _selection.ids.contains(id),
                selectionMode: _selecting,
                onSelect: (ctrl, shift) {
                  if (_selecting || ctrl || shift) {
                    setState(() {
                      _selecting = true;
                      _selection = _selection.click(
                        id,
                        visibleIds,
                        range: shift,
                      );
                    });
                  }
                },
                playing: _previewKey == 'asset:$id',
                onPlay: busy
                    ? null
                    : () =>
                          _quickPlay('asset:$id', stingerMap(asset['preview'])),
                onEdit: locked ? null : () => _edit(asset: asset),
                onAssign: locked ? null : () => _chooseTarget([id]),
                onRemove: locked ? null : () => _removeAssets([id]),
              );
              return card;
            },
          ),
        ),
      ),
    );
  }

  Widget _feedback(List<String> ids) => PlaylistDragPreview(
    itemNoun: '个台呼',
    cards: [
      for (final id in ids)
        if (_assets.where((a) => a['id'] == id).firstOrNull case final asset?)
          StingerCard(
            title: '${asset['name']}',
            subtitle: '台呼素材',
            order: _assets.indexWhere((a) => a['id'] == id) + 1,
            numberOnly: true,
            duration: stingerEditedDuration(
              stingerMap(asset['edit']),
              stingerNumber(asset['duration']),
            ),
            accent: true,
            dragging: true,
          ),
    ],
  );
}
