import '../widgets/external_audio_drop_target.dart';
import '../core/audio_import_error.dart';
import '../widgets/editor_controls.dart';
import '../widgets/audio_import_feedback.dart';
import '../widgets/feature_tour.dart';
import '../core/song_selection.dart';
import 'playlist/track_card.dart';
import 'playlist/playlist_draggable.dart';
import 'playlist/playlist_drag_preview.dart';
import '../widgets/rm_tooltip.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import '../core/fh_radio_studio_cli.dart';
import '../core/studio_audio_players.dart';
import '../core/atomic_file.dart';
import '../core/voice_audition.dart';
import '../widgets/open_package_folder_button.dart';
import '../core/deployment_preview.dart';
import '../widgets/deployment_dialog.dart';
import '../state/studio_state.dart';
import '../state/app_state.dart';
import '../state/library_columns.dart';
import '../theme/app_theme.dart';
import '../theme/text_styles.dart';
import '../theme/tokens.dart';
import '../widgets/playlist_search_field.dart';
import '../widgets/rm_button.dart';
import '../widgets/rm_field.dart';
import '../widgets/rm_icon.dart';
import '../widgets/rm_chip.dart';
import '../widgets/rm_select.dart';
import '../widgets/timing_dialog_frame.dart';
import 'stingers/stinger_models.dart';
import 'voices/voice_clip_editor.dart';
import 'stingers/stinger_session.dart';
import '../state/layout_options.dart';
import '../widgets/audio_editor_dialog.dart';
import 'voices/voice_text_export_dialog.dart';

part 'voices/voice_view.dart';
part 'voices/voice_browser.dart';
part 'voices/voice_table.dart';
part 'voices/voice_pool.dart';
part 'voices/voice_dialogs.dart';
part 'voices/voice_export.dart';
part 'voices/voice_session.dart';

typedef VoiceRequest =
    Future<Map<String, dynamic>> Function(
      String action,
      Map<String, dynamic> options,
    );

class VoiceReplacementScreen extends ConsumerStatefulWidget {
  const VoiceReplacementScreen({super.key, this.request, this.auditionPlayer});
  final VoiceRequest? request;
  final Player? auditionPlayer;
  @override
  ConsumerState<VoiceReplacementScreen> createState() =>
      _VoiceReplacementState();
}

class _VoiceReplacementState extends ConsumerState<VoiceReplacementScreen> {
  final _fileSearch = TextEditingController(),
      _entrySearch = TextEditingController(),
      _assetSearch = TextEditingController();
  final _workspaceFocus = FocusNode();
  List<Map<String, dynamic>> _files = [], _assets = [], _entries = [];
  Map<String, dynamic> _edits = {}, _saved = {}, _bank = {};
  Map<String, dynamic>? _pending;
  final _expanded = <String>{'电台 DJ', '活动与播报'};
  final _undo = <Map<String, dynamic>>[], _redo = <Map<String, dynamic>>[];
  String _language = '当前语言', _assetCategory = '全部分类';
  String? _selectedAsset, _error, _notice, _playing;
  String? _preferredBank;
  int _index = 0;
  bool _busy = false, _packageReady = false;
  int _importCount = 0;
  bool _layoutReady = false, _initialLoadStarted = false;
  String? _textLanguages, _requestedTextLanguages;
  String get _currentTextLanguages {
    final studio = ref.read(studioProvider);
    return jsonEncode([studio.targetLang, studio.sourceLang]);
  }

  void _refreshTextLanguages() {
    if (!mounted ||
        !_session.loaded ||
        _locked ||
        _requestedTextLanguages == _currentTextLanguages) {
      return;
    }
    unawaited(_scan());
  }

  bool _selectingExport = false, _selectingAssets = false;
  int? _entryAnchor;
  String? _assetAnchor;
  final _exportEntries = <int>{};
  List<Map<String, dynamic>>? _filteredSource;
  List<Map<String, dynamic>> _filteredEntries = [];
  Object? _filteredEdits, _filteredAssets;
  String _filteredQuery = '';
  List<Map<String, dynamic>>? _resourceSource;
  String _resourceFilterKey = '';
  Map<String, List<Map<String, dynamic>>> _resourceGroups = {};
  ({double origin, double left, double right, double maxLeft, double maxRight})?
  _paneDrag;
  ({double origin, int column, List<double> widths})? _columnDrag;
  ({double origin, double width, double ratio})? _comparisonDrag;
  double _comparisonRatio = .62;
  String _busyText = '';
  final _catalogs = <String, Map<String, dynamic>>{};
  final _selectedAssets = <String>{};
  List<String> get _orderedSelectedAssets => _assets
      .where((a) => _selectedAssets.contains('${a['id']}'))
      .map((a) => '${a['id']}')
      .toList();
  final _assetFolders = <String>{'未分类'};
  final _openAssetFolders = <String>{'未分类', '试听素材'};
  final _entryScroll = ScrollController(), _tableScroll = ScrollController();
  final _fileScroll = ScrollController();
  final _previewPaths = <String, String>{};
  final _assetWaves = <String, Future<Map<String, dynamic>>>{};
  final _assetWaveData = <String, Map<String, dynamic>>{};
  double _leftWidth = 190, _rightWidth = 220;
  final _columns = <double>[38, 150, 180, 180, 74, 38, 145, 90, 74, 112];
  final _desiredColumns = <double>[34, 250, 220, 220, 66, 34, 220, 64, 66, 84];
  List<Map<String, dynamic>>? _columnContentSource;
  bool _hasContent = false, _hasTranslation = false;
  String? _renamingFolder, _hoverFolder;
  final _folderName = TextEditingController();
  void _update(VoidCallback fn) {
    if (mounted) setState(fn);
  }

  Future<void> _rememberLayout() async {
    final key = 'voices.layout.${ref.read(studioProvider).projectDir}';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      key,
      jsonEncode({
        'left': _leftWidth,
        'right': _rightWidth,
        'v3_columns': _desiredColumns,
        'comparison_ratio': _comparisonRatio,
        'bank': _preferredBank,
        'language': _language,
      }),
    );
  }

  void _readLayout() {
    final prefs = ref.read(sharedPreferencesProvider);
    final raw = prefs.getString(
      'voices.layout.${ref.read(studioProvider).projectDir}',
    );
    if (raw == null || !mounted) return;
    try {
      final data = stingerMap(jsonDecode(raw));
      {
        _preferredBank = data['bank'] as String?;
        if (_voiceLanguageFilters.containsKey(data['language'])) {
          _language = data['language'] as String;
        }
        _comparisonRatio = stingerNumber(
          data['comparison_ratio'],
          .62,
        ).clamp(0.0, 1.0);
        _leftWidth = stingerNumber(data['left'], 190).clamp(125, 2500);
        _rightWidth = stingerNumber(data['right'], 220).clamp(145, 2500);
        final cols = data['v3_columns'];
        if (cols is List && cols.length == _columns.length) {
          for (var i = 0; i < cols.length; i++) {
            _desiredColumns[i] = stingerNumber(
              cols[i],
              _desiredColumns[i],
            ).clamp(24, 1600);
          }
        }
      }
    } on Object {
      /* Ignore an obsolete local layout preference. */
    }
  }

  late final VoiceWorkspaceSession _session;
  late final String _project;
  StingerSession? _materialWorker;
  int _playGeneration = 0;
  int? _activePlayGeneration;
  Player? _auditionPlayer;
  Player get _voicePlayer =>
      _auditionPlayer ??= widget.auditionPlayer ?? StudioAudioPlayers.voice;
  StreamSubscription<bool>? _completed;
  bool get _dirty => jsonEncode(_edits) != jsonEncode(_saved);
  bool get _locked => !mounted || _busy || ref.read(studioProvider).busy;

  Future<void> _loadInitialWorkspace() async {
    if (!mounted ||
        !_layoutReady ||
        _initialLoadStarted ||
        _session.loaded ||
        _locked) {
      return;
    }
    _initialLoadStarted = true;
    await _scan();
    if (mounted && _session.loaded) {
      await _recoverDraft();
    }
  }

  @override
  void initState() {
    super.initState();
    final studio = ref.read(studioProvider);
    _project = studio.projectDir;
    _session = ref.read(
      voiceWorkspaceSessionProvider(
        jsonEncode([
          _project,
          studio.gameDir,
          localDevelopmentConfig()['audio_scan_root'] as String? ??
              studio.gameDir,
        ]),
      ),
    );
    if (_session.view case final data?) _restoreWorkspace(data);
    if (_textLanguages != _currentTextLanguages) _session.loaded = false;
    ref.listenManual(studioProvider, (previous, next) {
      if (!next.busy) {
        unawaited(_loadInitialWorkspace());
        _refreshTextLanguages();
      }
    });
    if (widget.request == null) {
      _materialWorker = StingerSession(
        FhRadioStudioCli(repoRoot: studio.repoRoot),
        studio.projectDir,
        studio.gameDir,
        command: 'voices',
      );
      unawaited(_materialWorker!.warmUp().catchError((Object _) {}));
    }
    _readLayout();
    _layoutReady = true;
    Future.microtask(() async {
      if (!mounted) return;
      _layoutReady = true;
      await _loadInitialWorkspace();
    });
  }

  @override
  void dispose() {
    _cacheWorkspace();
    _materialWorker?.dispose();
    _playGeneration++;
    _completed?.cancel();
    if (_auditionPlayer != null) unawaited(_auditionPlayer!.pause());
    _entryScroll.dispose();
    _tableScroll.dispose();
    _fileScroll.dispose();
    _fileSearch.dispose();
    _entrySearch.dispose();
    _assetSearch.dispose();
    _folderName.dispose();
    _workspaceFocus.dispose();
    super.dispose();
  }

  Future<Map<String, dynamic>> _call(
    String action, [
    Map<String, dynamic> options = const {},
  ]) async {
    if (!mounted) return {};
    if (const {'scan', 'prepare', 'export-text'}.contains(action)) {
      final studio = ref.read(studioProvider);
      options = {
        ...options,
        'input': {
          ...stingerMap(options['input']),
          'voice_language': studio.targetLang,
          'display_language': studio.sourceLang,
        },
      };
    }
    if (widget.request != null) return widget.request!(action, options);
    if (_materialWorker != null &&
        const {'asset', 'asset-info'}.contains(action)) {
      return _materialWorker!.call(
        action,
        asset: options['asset'] as String?,
        input: options['input'] as Map<String, dynamic>?,
      );
    }
    final s = ref.read(studioProvider);
    final result = await FhRadioStudioCli(repoRoot: s.repoRoot).run(
      [
        'voices',
        action,
        '--project-dir',
        s.projectDir,
        '--game-dir',
        const {'scan', 'prepare', 'inspect', 'export-text'}.contains(action)
            ? (localDevelopmentConfig()['audio_scan_root'] as String? ??
                  s.gameDir)
            : s.gameDir,
        if (options['source'] != null) ...['--source', '${options['source']}'],
        if (options['bank'] != null) ...['--bank-id', '${options['bank']}'],
        if (options['index'] != null) ...['--index', '${options['index']}'],
        if (options['asset'] != null) ...['--asset-id', '${options['asset']}'],
        if (options['paths'] != null) ...[
          '--paths',
          ...List<String>.from(options['paths']),
        ],
        if (options['input'] != null) ...['--input-json', '-'],
      ],
      stdinInput: options['input'] == null
          ? null
          : jsonEncode(options['input']),
    );
    if (!result.ok) {
      throw FormatException(
        result.stderr.trim().isEmpty
            ? result.stdout.trim()
            : result.stderr.trim(),
      );
    }
    return stingerMap(jsonDecode(result.stdout));
  }

  Future<void> _guard(Future<void> Function() action) async {
    if (_locked) return;
    setState(() {
      _busy = true;
      _error = null;
      _busyText = '';
    });
    try {
      await action();
    } on Object catch (e) {
      if (mounted) {
        setState(() => _error = '$e'.replaceFirst('FormatException: ', ''));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _refreshTextLanguages();
      }
    }
  }

  void _hydrate(Map<String, dynamic> plan, {bool initial = false}) {
    final previousFolders = Set<String>.of(_assetFolders);
    _assets = stingerMaps(plan['assets']);
    _assetFolders.addAll((plan['folders'] as List? ?? []).map((v) => '$v'));
    _assetFolders.addAll(_assets.map((a) => '${a['category']}'));
    _openAssetFolders.addAll(
      _assetFolders.where(
        (f) => !f.contains('/') && !previousFolders.contains(f),
      ),
    );
    final banks = stingerMap(plan['banks']);
    if (initial) {
      _edits = {
        for (final e in banks.entries)
          e.key: stingerMap(stingerMap(e.value)['replacements']),
      };
      _saved = stingerClone(_edits);
    } else {
      for (final e in banks.entries) {
        _edits.putIfAbsent(
          e.key,
          () => stingerMap(stingerMap(e.value)['replacements']),
        );
        _saved.putIfAbsent(
          e.key,
          () => stingerMap(stingerMap(e.value)['replacements']),
        );
      }
    }
  }

  Future<void> _scan() => _guard(() async {
    final languages = _requestedTextLanguages = _currentTextLanguages;
    final data = await _session.readScan(() => _call('scan'), key: languages);
    if (!mounted) return;
    setState(() {
      _files = stingerMaps(data['files']);
      _session.loaded = true;
      _textLanguages = languages;
      _hydrate(stingerMap(data['plan']), initial: _edits.isEmpty);
      _packageReady = data['package_ready'] == true;
      for (final item in stingerMap(data['catalogs']).entries) {
        _catalogs[item.key] = stingerMap(item.value);
      }
      final catalog = _catalogs['${_bank['id']}'];
      if (_bank.isNotEmpty && catalog != null) {
        _entries = stingerMaps(catalog['entries']);
      }
      final active = stingerMap(_catalogs[_preferredBank] ?? data['active']);
      if (_bank.isEmpty && active.isNotEmpty) {
        _bank = stingerMap(active['bank']);
        _entries = stingerMaps(
          _catalogs['${_bank['id']}']?['entries'] ?? active['entries'],
        );
        _pending =
            _files
                .where((f) => f['relative_path'] == _bank['relative_path'])
                .firstOrNull ??
            {'name': _bank['name'], 'relative_path': _bank['relative_path']};
      }
      // A legacy remembered file can be in another voice language. Keep that
      // selected file visible instead of showing an unrelated filtered tree.
      final name = '${_pending?['name'] ?? ''}';
      final language = RegExp(
        r'_(BR|CN|DE|EN|ES|IT|JP|KO|MX|TW)(?:\.assets)?\.bank$',
      ).firstMatch(name)?.group(1);
      final locale = ref.read(studioProvider).targetLang;
      final expected = locale == 'CHS'
          ? 'CN'
          : locale == 'CHT'
          ? 'TW'
          : locale;
      if (_language == '当前语言' && language != null && language != expected) {
        _language = '全部语言';
      }
    });
  });
  Future<bool> _confirm(String title, String message, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => TimingDialogFrame(
          title: title,
          busy: false,
          width: 470,
          body: Text(
            message,
            style: RmText.sans(12.5, color: ctx.rm.fg2, height: 1.6),
          ),
          actions: [
            RmButton(label: '取消', onPressed: () => Navigator.pop(ctx, false)),
            RmButton(
              key: const ValueKey('voice-confirm-action'),
              label: action,
              variant:
                  action.startsWith('删除') ||
                      action.startsWith('清除') ||
                      action.startsWith('移除')
                  ? RmButtonVariant.dangerOutline
                  : RmButtonVariant.primary,
              onPressed: () => Navigator.pop(ctx, true),
            ),
          ],
        ),
      ) ??
      false;
  Future<void> _prepare() => _prepareSelected();

  Future<void> _choose() async {
    if (_locked) return;
    final result = await FilePicker.pickFiles(
      type: FileType.any,
      dialogTitle: '选择游戏音频资源',
    );
    final path = result?.files.single.path;
    if (path == null || !mounted) return;
    setState(
      () => _pending = {
        'path': path,
        'name': result!.files.single.name,
        'relative_path': result.files.single.name,
        'category': '自选文件',
        'custom': true,
      },
    );
    await _prepare();
  }

  Future<void> _import() async {
    if (_locked) return;
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['wav', 'mp3', 'ogg', 'flac', 'm4a', 'aac', 'aiff'],
      allowMultiple: true,
      dialogTitle: '导入语音素材',
    );
    if (result == null) return;
    await _importPaths(result.paths.whereType<String>().toList());
  }

  Future<void> _importPaths(List<String> paths, {int? at}) async {
    if (_locked || paths.isEmpty) return;
    final ids = <String>[];
    setState(() => _importCount = paths.length);
    try {
      await _guard(() async {
        final data = await _call('import', {
          'paths': paths,
          'input': {
            'category': _assetCategory == '全部分类' ? '未分类' : _assetCategory,
          },
        });
        ids.addAll((data['asset_ids'] as List? ?? []).map((v) => '$v'));
        _update(() => _hydrate(stingerMap(data['plan'])));
      });
    } finally {
      if (mounted) setState(() => _importCount = 0);
    }
    if (!mounted) return;
    if (_error != null) {
      setState(() => _error = audioImportErrorDetail(_error!));
      showAudioImportResult(context, '语音导入未完成：$_error');
      return;
    }
    if (at != null && ids.isNotEmpty) _replaceDroppedAssets(ids, index: at);
    final message = _error != null
        ? '素材已导入，但未替换：$_error'
        : '语音导入完成，已准备 ${ids.toSet().length} 个素材${at == null ? '' : '并应用到对应条目'}；已有素材会复用。';
    _update(() => _notice = message);
    showAudioImportResult(context, message);
  }

  Future<bool> _save() async {
    if (_locked) return false;
    var ok = false;
    await _guard(() async {
      await _call('save', {
        'input': {'banks': _edits},
      });
      if (!mounted) return;
      setState(() {
        _saved = stingerClone(_edits);
        _packageReady = false;
        _notice = '语音替换已保存，构建准备包后生效。';
      });
      ok = true;
    });
    if (ok) await _persistDraft();
    return ok;
  }

  void _change(Map<String, dynamic> next) {
    _undo.add(stingerClone(_edits));
    _redo.clear();
    setState(() {
      _edits = next;
      _notice = null;
      _error = null;
    });
    unawaited(_persistDraft());
  }

  void _history(bool redo) {
    if (_locked) return;
    final from = redo ? _redo : _undo, to = redo ? _undo : _redo;
    if (from.isEmpty) return;
    to.add(stingerClone(_edits));
    setState(() {
      _edits = from.removeLast();
      _notice = null;
      _error = null;
    });
    unawaited(_persistDraft());
  }

  Map<String, dynamic> get _replacements =>
      stingerMap(_edits['${_bank['id']}']);
  Map<String, dynamic>? get _entry =>
      _entries.where((e) => e['index'] == _index).firstOrNull;
  Future<void> _clear() async {
    if (_locked || !_replacements.containsKey('$_index')) return;
    final next = stingerClone(_edits),
        replacements = _replacements..remove('$_index');
    next['${_bank['id']}'] = replacements;
    _change(next);
  }

  Future<void> _restoreFile() async {
    if (_locked || _replacements.isEmpty) return;
    if (!await _confirm(
      '恢复此文件的原有语音？',
      '将清除此文件的 ${_replacements.length} 条替换，其他资源保持不变。保存并构建后生效，可撤销。',
      '恢复原音',
    )) {
      return;
    }
    final next = stingerClone(_edits);
    next['${_bank['id']}'] = <String, dynamic>{};
    _change(next);
  }

  Future<Map<String, dynamic>> _loadAssetWave(Map<String, dynamic> asset) {
    final id = '${asset['id']}';
    final ready = stingerMap(asset['source_preview']);
    if (ready['path'] != null) return Future.value(ready);
    if (_assetWaveData[id] case final cached?) return Future.value(cached);
    return _assetWaves.putIfAbsent(
      id,
      () => _call('asset-info', {'asset': id})
          .then((wave) {
            if (wave['path'] != null &&
                (wave['bins'] as List?)?.isNotEmpty == true) {
              _assetWaveData[id] = wave;
            }
            return wave;
          })
          .whenComplete(() {
            _assetWaves.remove(id);
          }),
    );
  }

  Future<void> _edit() async {
    final original = _replacements['$_index'];
    if (original == null || _locked) return;
    final edit = stingerMap(original),
        asset = _assets.firstWhere((a) => a['id'] == edit['asset_id']);
    final bankId = '${_bank['id']}', index = _index;
    _playGeneration++;
    if (_playing != null) await _voicePlayer.pause();
    _update(() => _playing = null);
    if (!mounted) return;
    final accepted = await showAudioEditorDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => VoiceClipEditor(
        featureTour: true,
        preferredWidth: ref.read(layoutOptionsProvider).manualRefineWidth,
        asset: asset,
        initial: edit,
        folders: _assetFolders.toList(),
        metadata: false,
        targetDuration: stingerNumber(_entry?['duration']),
        load: () => _loadAssetWave(asset),
        render: (data) => _call('asset', {
          'asset': asset['id'],
          'input': {...data, 'wave': true},
        }),
      ),
    );
    if (accepted == null || !mounted) return;
    final next = stingerClone(_edits), changes = stingerMap(next[bankId]);
    changes['$index'] = {
      ...edit,
      'start': accepted['start'],
      'end': accepted['end'],
      'gain_db': accepted['gain_db'],
      'keep_duration': accepted['keep_duration'] == true,
      'audio_edits': accepted['audio_edits'] ?? [],
    };
    next[bankId] = changes;
    _previewPaths[_audioCacheKey(asset, changes['$index'])] =
        '${stingerMap(accepted['wave'])['path']}';
    _change(next);
  }

  Future<void> _assetInfo(Map<String, dynamic> asset) => _editMaterial(asset);

  String _audioCacheKey(
    Map<String, dynamic> asset,
    Map<String, dynamic> edit,
  ) =>
      'material:${asset['id']}:${jsonEncode([edit['start'] ?? 0, edit['end'] ?? asset['duration'], edit['audio_edits'] ?? []])}';

  Future<Map<String, dynamic>> _quickAudio(
    Map<String, dynamic> asset,
    Map<String, dynamic> edit,
  ) async {
    final key = _audioCacheKey(asset, edit);
    final operations = edit['audio_edits'] as List? ?? [];
    if (operations.isEmpty) {
      final wave = await _loadAssetWave(asset);
      return {
        ...wave,
        'clip_start': stingerNumber(edit['start']),
        'clip_end': stingerNumber(
          edit['end'],
          stingerNumber(asset['duration']),
        ),
        'clip_gain': stingerNumber(edit['gain_db']),
      };
    }
    final path = _previewPaths[key];
    if (path != null && path != 'null') {
      return {'path': path, 'clip_gain': stingerNumber(edit['gain_db'])};
    }
    final defaultPreview = stingerMap(asset['quick_preview']);
    if (defaultPreview['path'] != null && _audioCacheKey(asset, asset) == key) {
      return {...defaultPreview, 'clip_gain': stingerNumber(edit['gain_db'])};
    }
    final wave = await _call('asset', {
      'asset': asset['id'],
      'input': {...edit, 'wave': true},
    });
    _previewPaths[key] = '${wave['path']}';
    return {...wave, 'clip_gain': stingerNumber(edit['gain_db'])};
  }

  Future<void> _play(String kind, {String? asset}) async {
    final key = kind == 'asset'
        ? 'asset:$asset'
        : '$kind:${_bank['id']}:$_index';
    if (_playing == key) {
      _playGeneration++;
      await _voicePlayer.pause();
      _update(() => _playing = null);
      return;
    }
    final generation = ++_playGeneration;
    _activePlayGeneration = null;
    _update(() {
      _playing = key;
      _error = null;
    });
    try {
      Map<String, dynamic> audio;
      if (kind == 'original') {
        final cached = _entry?['preview_path'];
        audio = cached == null
            ? await _call('original', {'bank': _bank['id'], 'index': _index})
            : {'path': cached};
        if (_entry != null) _entry!['preview_path'] = audio['path'];
      } else {
        final edit = kind == 'asset'
            ? _assets.firstWhere((a) => a['id'] == asset)
            : stingerMap(_replacements['$_index']);
        final material = _assets.firstWhere(
          (a) => a['id'] == (kind == 'asset' ? asset : edit['asset_id']),
        );
        if (kind != 'asset' && edit['keep_duration'] == true) {
          final cacheKey = '$key:${jsonEncode(edit)}';
          audio = _previewPaths[cacheKey] == null
              ? await _call('preview', {
                  'bank': _bank['id'],
                  'index': _index,
                  'input': edit,
                })
              : {'path': _previewPaths[cacheKey]};
          _previewPaths[cacheKey] = '${audio['path']}';
        } else {
          audio = await _quickAudio(material, edit);
        }
      }
      if (!mounted || generation != _playGeneration) return;
      final player = _voicePlayer;
      _completed ??= player.stream.completed.listen((done) {
        if (done &&
            _activePlayGeneration == _playGeneration &&
            player.state.completed) {
          _update(() => _playing = null);
        }
      });
      await StudioAudioPlayers.pauseOthers(player);
      await startVoiceAudition(
        player,
        '${audio['path']}',
        start: stingerNumber(audio['clip_start']),
        end: (audio['clip_end'] as num?)?.toDouble(),
        gainDb: stingerNumber(audio['clip_gain']),
        isCurrent: () => mounted && generation == _playGeneration,
      );
      if (mounted && generation == _playGeneration) {
        _activePlayGeneration = generation;
        _update(() => _playing = player.state.completed ? null : key);
      }
    } on Object catch (e) {
      if (mounted && generation == _playGeneration) {
        _update(() {
          _playing = null;
          _error = '试听失败：$e';
        });
      }
    }
  }

  Future<void> _build() => _buildVoicePackage();

  @override
  Widget build(BuildContext context) => _view();
}
