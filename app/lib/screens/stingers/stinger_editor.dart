import '../../widgets/editor_controls.dart';
import '../../widgets/feature_tour.dart';
import '../../widgets/editor_columns.dart';
import '../../widgets/audio_editor_dialog.dart';
import '../../core/waveform_zoom.dart';
import 'dart:convert';
import '../../widgets/timing_dialog_frame.dart';
import '../../state/app_state.dart';
import '../../widgets/time_input_field.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../state/editor_shortcuts.dart';
import '../../widgets/rm_icon.dart';
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import '../../domain/replacement_models.dart';
import '../../theme/app_theme.dart';
import '../../theme/text_styles.dart';
import '../../theme/tokens.dart';
import '../../widgets/rm_banner.dart';
import '../../widgets/rm_button.dart';
import '../../widgets/rm_chip.dart';
import '../../widgets/rm_select.dart';
import '../../widgets/rm_slider.dart';
import '../replace_editor/manual_focus_waveform.dart';
import '../replace_editor/waveform_overview.dart';
import '../../core/playback_window.dart';
import 'stinger_models.dart';

const stingerNudgeMs = 300;

typedef StingerPlay =
    Future<void> Function(
      Map<String, dynamic> audio, {
      double? start,
      double? end,
      double gain,
    });
typedef StingerCall =
    Future<Map<String, dynamic>> Function(
      String action,
      Map<String, dynamic> input,
    );

Future<bool?> showStingerEditor(
  BuildContext context, {
  Map<String, dynamic>? station,
  Map<String, dynamic>? slot,
  Map<String, dynamic>? asset,
  required List<Map<String, dynamic>> assets,
  required List<Map<String, dynamic>> songs,
  required Player player,
  required double preferredWidth,
  required int usedCount,
  bool readOnly = false,
  bool deferSave = false,
  required StingerPlay play,
  required StingerCall call,
  ValueChanged<Map<String, dynamic>>? onSaved,
  String contextKey = '',
  List<String> preferredSongs = const [],
}) => showAudioEditorDialog<bool>(
  context: context,
  backdrop: false,
  builder: (context) => StingerEditor(
    station: station,
    slot: slot,
    asset: asset,
    assets: assets,
    songs: songs,
    player: player,
    preferredWidth: preferredWidth,
    usedCount: usedCount,
    readOnly: readOnly,
    deferSave: deferSave,
    play: play,
    call: call,
    onSaved: onSaved,
    contextKey: contextKey,
    preferredSongs: preferredSongs,
    featureTour: true,
  ),
);

class StingerEditor extends ConsumerStatefulWidget {
  const StingerEditor({
    super.key,
    this.station,
    this.slot,
    this.asset,
    required this.assets,
    required this.songs,
    required this.player,
    required this.preferredWidth,
    required this.usedCount,
    this.readOnly = false,
    this.deferSave = false,
    required this.play,
    required this.call,
    this.onSaved,
    this.contextKey = '',
    this.preferredSongs = const [],
    this.featureTour = false,
  });
  final Map<String, dynamic>? station, slot, asset;
  final bool featureTour;
  final List<Map<String, dynamic>> assets, songs;
  final Player player;
  final double preferredWidth;
  final int usedCount;
  final bool readOnly;
  final bool deferSave;
  final StingerPlay play;
  final StingerCall call;
  final String contextKey;
  final List<String> preferredSongs;
  final ValueChanged<Map<String, dynamic>>? onSaved;
  @override
  ConsumerState<StingerEditor> createState() => _StingerEditorState();
}

class _StingerEditorState extends ConsumerState<StingerEditor> {
  final _start = TextEditingController(),
      _end = TextEditingController(),
      _next = TextEditingController(),
      _name = TextEditingController();
  String? _assetId, _before, _after, _opened;
  String _mode = 'source', _active = 'next';
  List<Map<String, dynamic>> _materialEdits = [];
  bool get _hasMaterialEdits => _materialEdits.isNotEmpty;
  bool _busy = false;
  String? _error;
  double _gain = 0, _windowStart = 0, _span = 0, _offset = 0;
  double _idlePlayhead = 0;
  StreamSubscription<Duration>? _positionSubscription;
  Map<String, dynamic>? _seamWave;
  String? _seamKey;
  bool _seamWasOriginal = false;
  bool _beforeInputValid = true, _afterInputValid = true;
  double _beforeSeconds = 6, _afterSeconds = 4;
  String get _preferenceKey => 'rm.stinger.audition.${widget.contextKey}';
  void _restoreAudition() {
    final choices = widget.songs.map((song) => '${song['path']}').toSet();
    final preferred = widget.preferredSongs.where(choices.contains).toList();
    final fallback = preferred.isNotEmpty ? preferred : choices.toList();
    Map saved = {};
    try {
      saved =
          jsonDecode(
                ref.read(sharedPreferencesProvider).getString(_preferenceKey) ??
                    '{}',
              )
              as Map;
    } on Object catch (_) {
      /* Ignore obsolete preferences. */
    }
    _before = choices.contains(saved['before'])
        ? saved['before'] as String
        : fallback.firstOrNull;
    _after = choices.contains(saved['after'])
        ? saved['after'] as String
        : (fallback.length > 1 ? fallback[1] : fallback.firstOrNull);
    _beforeSeconds = stingerNumber(saved['before_seconds'], 6).clamp(0, 30);
    _afterSeconds = stingerNumber(saved['after_seconds'], 4).clamp(0, 60);
    if (saved['timing_version'] != 2 &&
        _beforeSeconds == 3 &&
        _afterSeconds == 6) {
      _beforeSeconds = 6;
      _afterSeconds = 4;
    }
  }

  void _storeAudition() {
    unawaited(
      ref
          .read(sharedPreferencesProvider)
          .setString(
            _preferenceKey,
            jsonEncode({
              'before': _before,
              'after': _after,
              'before_seconds': _beforeSeconds,
              'after_seconds': _afterSeconds,
              'timing_version': 2,
            }),
          )
          .catchError((Object _) => false),
    );
  }

  Timer? _prepareTimer;
  final _prepared = <String, Future<Map<String, dynamic>>>{};
  final _editUndo = <Map<String, dynamic>>[],
      _editRedo = <Map<String, dynamic>>[];
  Map<String, dynamic>? _lastEdit;
  DateTime? _lastCheckpoint;
  Map<String, dynamic> get _snapshot => {..._edit(), 'name': _name.text};
  void _remember() {
    final now = DateTime.now(), current = _snapshot;
    if (_lastEdit != null && current.toString() != _lastEdit.toString()) {
      if (_lastCheckpoint == null ||
          now.difference(_lastCheckpoint!).inMilliseconds > 350) {
        _editUndo.add(_lastEdit!);
        if (_editUndo.length > 60) _editUndo.removeAt(0);
      }
      _editRedo.clear();
      _lastCheckpoint = now;
    }
    _lastEdit = current;
    _schedulePreview();
  }

  void _restoreEdit(bool redo) {
    final from = redo ? _editRedo : _editUndo,
        to = redo ? _editUndo : _editRedo;
    if (from.isEmpty || _busy) return;
    to.add(_snapshot);
    final value = from.removeLast();
    unawaited(widget.player.pause());
    setState(() {
      _assetId = value['asset_id'] as String?;
      _reset(value);
      _name.text = '${value['name'] ?? _asset?['name'] ?? ''}';
      _mode = 'source';
      _lastEdit = _snapshot;
      _lastCheckpoint = null;
    });
    _schedulePreview();
  }

  String _previewIdentity(bool original) =>
      '$original|$_before|$_after|$_assetId|$_a|$_b|$_n|$_gain|$_beforeSeconds|$_afterSeconds';
  Future<Map<String, dynamic>> _prepareSeam(bool original) {
    final key = _previewIdentity(original);
    final input = {
      ..._edit(),
      'original': original,
      'before': _before,
      'after': _after,
      'before_seconds': _beforeSeconds,
      'after_seconds': _afterSeconds,
    };
    return _prepared.putIfAbsent(
      key,
      () => widget.call('seam', input).catchError((Object error) {
        _prepared.remove(key);
        throw error;
      }),
    );
  }

  void _schedulePreview() {
    _prepareTimer?.cancel();
    if (_before == null || _after == null) return;
    _prepareTimer = Timer(const Duration(milliseconds: 250), () async {
      try {
        if (_invalid == null) await _prepareSeam(false);
        if (mounted && _hasOriginal) await _prepareSeam(true);
      } on Object catch (_) {
        /* A later click reports an actionable error. */
      }
    });
  }

  bool get _pool => widget.slot == null;
  bool get _hasOriginal =>
      widget.slot?['additional'] != true &&
      widget.slot?['original_preview'] != null;
  bool get _wide =>
      math.min(widget.preferredWidth, MediaQuery.sizeOf(context).width - 48) >=
      820;
  Map<String, dynamic>? get _asset =>
      widget.assets.where((a) => a['id'] == _assetId).firstOrNull;
  double get _a => stingerNumber(_start.text);
  double get _b => stingerNumber(_end.text);
  double get _n => stingerNumber(_next.text);
  double get _length => stingerNumber(_asset?['duration']);
  bool get _showsOriginal =>
      _mode == 'original' || _mode == 'seam' && _seamWasOriginal;
  // The mixed audition buffer has its own clock. It never becomes the editing
  // timeline: A/B and the overview always use the original material's seconds.
  Map<String, dynamic> get _wave => _showsOriginal
      ? stingerMap(widget.slot?['original_preview'])
      : stingerMap(
          stingerMap(_asset)[_hasMaterialEdits ? 'preview' : 'source_preview'],
        );
  double get _duration => stingerNumber(_wave['duration'], _length);
  double get _clipStart => _showsOriginal || _hasMaterialEdits ? 0 : _a;
  double get _clipEnd => _showsOriginal || _hasMaterialEdits ? _duration : _b;
  double get _clipNext => _showsOriginal
      ? stingerNumber(_wave['next_track'])
      : (_hasMaterialEdits ? _n : _a + _n);
  double get _viewSpan =>
      _span <= 0 ? _duration : _span.clamp(.05, math.max(.05, _duration));
  double _playhead(Duration position) {
    if (_opened == null) return _idlePlayhead.clamp(0, _duration);
    final time = position.inMicroseconds / 1e6 + _offset;
    return _mode == 'seam'
        ? time.clamp(_clipStart, _clipEnd)
        : time.clamp(0, _duration);
  }

  String _clock(Duration position) {
    final time = _playhead(position);
    final raw = position.inMicroseconds / 1e6 + _offset;
    final phase = _mode != 'seam'
        ? ''
        : raw < _clipStart
        ? ' · 台呼前音乐'
        : raw > _clipEnd
        ? ' · 台呼后音乐'
        : ' · 台呼';
    return '${stingerTime(time)} / ${stingerTime(_duration)}$phase';
  }

  void _followPlayback(Duration position) {
    if (!mounted ||
        _opened == null ||
        _span <= 0 ||
        !widget.player.state.playing) {
      return;
    }
    final view = pagedPlaybackWindow(
      duration: _duration,
      start: _windowStart,
      end: _windowStart + _viewSpan,
      playhead: _playhead(position),
    );
    if ((view.start - _windowStart).abs() > .000001) {
      setState(() {
        _windowStart = view.start;
        _span = view.end - view.start;
      });
    }
  }

  Map<String, dynamic> _edit() => {
    'asset_id': _assetId,
    'start': _a,
    'end': _b,
    'gain_db': _gain,
    'next_track': _n,
    if (_hasMaterialEdits) 'audio_edits': _materialEdits,
    if (widget.slot != null) 'slot_id': widget.slot!['id'],
  };
  String? get _invalid {
    if (_asset == null) return '选择台呼素材后可保存替换。';
    for (final c in [_start, _end, _next]) {
      final n = double.tryParse(c.text);
      if (n == null || !n.isFinite) return '请输入有效的秒数。';
    }
    if (_a < 0 || _b > _length + .002 || _b - _a < .05) {
      return '裁剪需在素材内，台呼长度至少为 0.05 秒。';
    }
    if (_n < 0 || _n >= stingerEditedDuration(_edit())) {
      return '下一首开始位置需位于裁剪后的台呼内。';
    }
    if (_pool && _name.text.trim().isEmpty) return '素材名称不能为空。';
    return null;
  }

  @override
  void initState() {
    super.initState();
    _assetId = widget.readOnly
        ? ''
        : '${widget.asset?['id'] ?? stingerMap(widget.slot?['assignment'])['asset_id'] ?? ''}';
    _restoreAudition();
    _reset(
      stingerMap(
        widget.asset?['edit'] ?? widget.slot?['assignment'] ?? _asset?['edit'],
      ),
    );
    if (_asset == null) _mode = _hasOriginal ? 'original' : 'source';
    _lastEdit = _snapshot;
    _positionSubscription = widget.player.stream.position.listen(
      _followPlayback,
    );
    _schedulePreview();
  }

  @override
  void dispose() {
    _prepareTimer?.cancel();
    unawaited(_positionSubscription?.cancel());
    unawaited(widget.player.pause());
    _start.dispose();
    _end.dispose();
    _next.dispose();
    _name.dispose();
    super.dispose();
  }

  void _reset(Map<String, dynamic> edit) {
    _materialEdits = stingerMaps(edit['audio_edits']);
    _start.text = stingerNumber(edit['start']).toString();
    _end.text = stingerNumber(edit['end'], math.min(_length, 12)).toString();
    _next.text = stingerNumber(
      edit['next_track'],
      math.max(0, _b - _a - 1.2),
    ).toString();
    _gain = stingerNumber(edit['gain_db']);
    _name.text = '${_asset?['name'] ?? ''}';
    _span = 0;
    _windowStart = 0;
    _opened = null;
    _idlePlayhead = 0;
    _offset = 0;
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = '$error'.replaceFirst('FormatException: ', ''));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _changed() {
    setState(() {
      _idlePlayhead = _playhead(widget.player.state.position);
      _mode = 'source';
      _opened = null;
      _error = null;
      _remember();
    });
  }

  void _seekPointer(double time) {
    setState(() => _idlePlayhead = time.clamp(0, _duration));
    if (_opened != null) {
      unawaited(
        widget.player.seek(
          Duration(
            microseconds: ((time - _offset).clamp(0, double.infinity) * 1e6)
                .round(),
          ),
        ),
      );
    }
  }

  void _place(double time, {required bool isMove}) {
    if (_mode != 'source') {
      final bufferTime = (time - _offset).clamp(
        0.0,
        _mode == 'seam' ? stingerNumber(_seamWave?['duration']) : _duration,
      );
      unawaited(
        widget.player.seek(Duration(microseconds: (bufferTime * 1e6).round())),
      );
      return;
    }
    if (_asset == null) return;
    if (!isMove) {
      final points = _hasMaterialEdits
          ? {'next': _n}
          : {'start': _a, 'end': _b, 'next': _a + _n};
      _active = points.keys.reduce(
        (a, b) => (points[a]! - time).abs() < (points[b]! - time).abs() ? a : b,
      );
    }
    _setActive(time);
  }

  void _setActive(double time) {
    setState(() {
      final a = _a, b = _b, n = _n;
      if (_hasMaterialEdits) {
        _next.text = time.clamp(0, math.max(0, _duration - .001)).toString();
      } else if (_active == 'start') {
        final next = time.clamp(0, math.max(0, b - .05));
        _start.text = next.toString();
        _next.text = (a + n - next)
            .clamp(0, math.max(0, b - next - .001))
            .toString();
      } else if (_active == 'end') {
        final next = time.clamp(math.min(_length, a + .05), _length);
        _end.text = next.toString();
        _next.text = n.clamp(0, math.max(0, next - a - .001)).toString();
      } else {
        _next.text = (time - a).clamp(0, math.max(0, b - a - .001)).toString();
      }
      _idlePlayhead = _activeTime;
      _mode = 'source';
      _opened = null;
      _error = null;
      _remember();
    });
  }

  double get _activeTime => _active == 'start'
      ? _a
      : _active == 'end'
      ? _b
      : (_hasMaterialEdits ? _n : _a + _n);
  double _waveWidth = 800;
  void _zoom(double factor) {
    if (_duration <= 0) return;
    setState(() {
      final next = (_viewSpan * factor).clamp(
        minimumWaveformSpan(
          duration: _duration,
          bins: (_wave['bins'] as List?)?.length ?? 512,
          width: _waveWidth,
        ),
        _duration,
      );
      final center = _playhead(widget.player.state.position);
      _span = next.toDouble();
      _windowStart = (center - next / 2)
          .clamp(0.0, math.max(0.0, _duration - next))
          .toDouble();
    });
  }

  Future<void> _audition([String? mode]) async {
    if (_busy) return;
    try {
      final next = mode ?? _mode;
      final wasOriginal = _showsOriginal;
      final key = '$next|$_assetId|$_a|$_b|$_gain|$_n';
      if (_opened == key) {
        if (widget.player.state.playing) {
          await widget.player.pause();
          return;
        }
        final finished =
            widget.player.state.completed ||
            (next == 'source'
                ? _playhead(widget.player.state.position) >= _clipEnd - .002
                : widget.player.state.duration > Duration.zero &&
                      widget.player.state.position >=
                          widget.player.state.duration -
                              const Duration(milliseconds: 2));
        if (!finished) {
          await widget.player.play();
          return;
        }
        // Restart through the same cropped audition path. Native play() after
        // EOF can reopen the full source at zero and lose the chosen A point.
        _idlePlayhead = next == 'source' ? _clipStart : 0;
      }
      if (next == 'original') {
        if (!_hasOriginal) return;
        await widget.play(stingerMap(widget.slot!['original_preview']));
        _offset = 0;
      } else if (next == 'seam' && _seamWave != null) {
        await widget.play(_seamWave!);
        _offset =
            (_seamWasOriginal ? 0 : _a) -
            stingerNumber(_seamWave!['stinger_start']);
      } else {
        if (_invalid != null) throw FormatException(_invalid!);
        final cached = stingerMap(
          widget.slot?['preview'] ?? _asset?['preview'],
        );
        final edit = stingerMap(cached['edit']);
        final exact = [
          'asset_id',
          'start',
          'end',
          'gain_db',
          'next_track',
          if (_hasMaterialEdits) 'audio_edits',
        ].every((k) => edit[k] == _edit()[k]);
        final beginning = _hasMaterialEdits ? 0.0 : _a;
        final finish = _hasMaterialEdits ? _duration : _b;
        final start = _idlePlayhead >= finish - .002
            ? beginning
            : _idlePlayhead.clamp(beginning, finish);
        if (exact && cached['path'] != null) {
          await widget.play(
            cached,
            start: math.max(0, start - beginning),
            gain: stingerNumber(cached['clip_gain']),
          );
          _offset = _hasMaterialEdits ? 0 : _a;
        } else if (_hasMaterialEdits) {
          final renderedGain = stingerNumber(
            stingerMap(_wave['edit'])['gain_db'],
          );
          await widget.play(_wave, start: start, gain: _gain - renderedGain);
          _offset = 0;
        } else {
          await widget.play(
            stingerMap(_asset!['source_preview']),
            start: start,
            end: _b,
            gain: _gain,
          );
          _offset = 0;
        }
      }
      if (mounted) {
        setState(() {
          final showsOriginal =
              next == 'original' || next == 'seam' && _seamWasOriginal;
          if (showsOriginal != wasOriginal) {
            _span = 0;
            _windowStart = 0;
          }
          _mode = next;
          _opened = key;
        });
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = '试听未开始：$error');
    }
  }

  Future<void> _persist() async {
    TimeInputValidation.flush();
    if (TimeInputValidation.invalid.isNotEmpty) {
      throw const FormatException('请检查时间格式。');
    }
    if (_invalid != null) throw FormatException(_invalid!);
    final preview = widget.deferSave
        ? null
        : await widget.call(_pool ? 'asset-preview' : 'preview', _edit());
    if (!mounted) return;
    await widget.call(_pool ? 'update-asset' : 'update', {
      ..._edit(),
      if (_pool) 'name': _name.text.trim(),
    });
    widget.onSaved?.call({
      'asset_id': _assetId,
      'pool': _pool,
      'preview': preview,
    });
  }

  Future<void> _save() => _run(() async {
    await _persist();
    if (mounted) Navigator.pop(context, true);
  });
  Future<void> _seam() async {
    final original =
        _mode == 'original' ||
        _asset == null ||
        _mode == 'seam' && _seamWasOriginal;
    final key = _previewIdentity(original);
    if (_mode == 'seam' && _seamKey == key) {
      await _audition();
      return;
    }
    await _run(() async {
      if (!original && _invalid != null) throw FormatException(_invalid!);
      final data = await _prepareSeam(original);
      if (!mounted) return;
      _seamWave = data;
      _seamKey = key;
      _seamWasOriginal = original;
      _offset = (original ? 0 : _a) - stingerNumber(data['stinger_start']);
      await widget.play(data);
      if (!mounted) return;
      setState(() {
        _mode = 'seam';
        _opened = 'seam|$_assetId|$_a|$_b|$_gain|$_n';
      });
    });
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent || ModalRoute.of(context)?.isCurrent == false) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (!_busy) Navigator.pop(context);
      return KeyEventResult.handled;
    }
    if (_busy) return KeyEventResult.ignored;
    final keys = ref.read(editorShortcutsProvider);
    final keyboard = HardwareKeyboard.instance;
    bool matches(EditorAction action) => keys[action]!.matches(
      event,
      ctrl: keyboard.isControlPressed,
      shift: keyboard.isShiftPressed,
      alt: keyboard.isAltPressed,
      meta: keyboard.isMetaPressed,
    );
    if (matches(EditorAction.undo) || matches(EditorAction.redo)) {
      _restoreEdit(matches(EditorAction.redo));
      return KeyEventResult.handled;
    }
    if (matches(EditorAction.save)) {
      if (_invalid == null) unawaited(_save());
      return KeyEventResult.handled;
    }
    final typing =
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorStateOfType<EditableTextState>() !=
        null;
    if (typing) return KeyEventResult.ignored;
    if (matches(EditorAction.play)) {
      unawaited(_audition());
      return KeyEventResult.handled;
    }
    if (matches(EditorAction.confirm)) {
      if (_invalid == null) unawaited(_save());
      return KeyEventResult.handled;
    }
    if (_asset == null || _mode != 'source') return KeyEventResult.ignored;
    if (matches(EditorAction.markPlayback)) {
      _setActive(_playhead(widget.player.state.position));
      return KeyEventResult.handled;
    }
    final coarse = stingerNudgeMs / 1000;
    for (final entry in {
      EditorAction.beatBack: -coarse,
      EditorAction.beatForward: coarse,
      EditorAction.tenBack: -.01,
      EditorAction.tenForward: .01,
      EditorAction.oneBack: -.001,
      EditorAction.oneForward: .001,
    }.entries) {
      if (matches(entry.key)) {
        _setActive(_activeTime + entry.value);
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final viewport = MediaQuery.sizeOf(context);
    final title = _pool
        ? '台呼素材'
        : 'R${widget.station?['radio']} · 台呼 ${widget.slot?['number']}';
    final editor = PopScope(
      canPop: !_busy,
      child: Focus(
        autofocus: true,
        onKeyEvent: _key,
        child: Material(
          type: MaterialType.transparency,
          child: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _busy ? null : () => Navigator.pop(context),
                  child: BackdropFilter(
                    filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                    child: const ColoredBox(color: RmTokens.modalBackdrop),
                  ),
                ),
              ),
              Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: math.min(
                      widget.preferredWidth,
                      viewport.width - 48,
                    ),
                    maxHeight: math.min(
                      widget.readOnly ? 480 : (_wide ? 720 : 760),
                      viewport.height - 48,
                    ),
                  ),
                  child: Container(
                    key: const ValueKey('stinger-editor-panel'),
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
                        Container(
                          padding: const EdgeInsets.fromLTRB(16, 13, 14, 12),
                          decoration: BoxDecoration(
                            border: Border(
                              bottom: BorderSide(color: rm.border),
                            ),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 34,
                                height: 34,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: rm.accent.bg,
                                  border: Border.all(color: rm.accent.ring),
                                  borderRadius: BorderRadius.circular(
                                    RmTokens.rMd,
                                  ),
                                ),
                                child: Icon(
                                  Icons.graphic_eq,
                                  size: 19,
                                  color: rm.accent.base,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: RmText.sans(
                                        17,
                                        weight: FontWeight.w700,
                                        color: rm.fg,
                                      ),
                                    ),
                                    const SizedBox(height: 3),
                                    Text(
                                      widget.readOnly
                                          ? '游戏内台呼仅供试听，无法在此修改。'
                                          : _asset == null
                                          ? (_hasOriginal
                                                ? '原有台呼无法直接编辑；选择替换素材后可调整。'
                                                : '此位置尚未分配音频，请选择素材。')
                                          : _mode != 'source'
                                          ? '当前为试听模式；返回编辑后可调整替换素材。'
                                          : '左键定位播放；右键调整选点和下一首进入位置。',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: RmText.sans(12.5, color: rm.fg3),
                                    ),
                                  ],
                                ),
                              ),
                              if (widget.readOnly || _asset == null)
                                RmChip(
                                  label: _hasOriginal ? '原有 · 只读' : '待分配音频',
                                  variant: _hasOriginal
                                      ? RmChipVariant.muted
                                      : RmChipVariant.warn,
                                  leading: RmIcon(
                                    _hasOriginal ? 'lock' : 'music',
                                    size: 10,
                                  ),
                                ),
                              const SizedBox(width: 6),
                              RmButton.icon(
                                icon: const RmIcon('zoom-out', size: 12),
                                tooltip: '缩小',
                                onPressed: _busy ? null : () => _zoom(1.55),
                              ),
                              const SizedBox(width: 6),
                              RmButton.icon(
                                icon: const RmIcon('zoom-in', size: 12),
                                tooltip: '放大 · Ctrl+滚轮',
                                onPressed: _busy ? null : () => _zoom(.65),
                              ),
                              const SizedBox(width: 6),
                              RmButton.icon(
                                icon: const RmIcon('x', size: 13),
                                tooltip: '返回',
                                onPressed: _busy
                                    ? null
                                    : () => Navigator.pop(context),
                              ),
                            ],
                          ),
                        ),
                        Flexible(child: _editorBody()),
                        _footer(),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return widget.featureTour
        ? editor.withFeatureTour(
            TourPage.stingerEditor,
            enabled: !_busy && _duration > 0,
          )
        : editor;
  }

  Widget _assetPicker() => _pool
      ? _nameField()
      : SizedBox(
          height: 32,
          child: RmSelect<String>(
            value: _assetId ?? '',
            items: {
              '': '选择替换素材',
              for (final asset in widget.assets)
                '${asset['id']}': '${asset['name']}',
            },
            onChanged: _busy
                ? null
                : (value) {
                    unawaited(widget.player.pause());
                    setState(() {
                      _assetId = value;
                      _reset(stingerMap(_asset?['edit']));
                      _mode = _asset == null ? 'original' : 'source';
                      _remember();
                    });
                  },
          ),
        );

  Widget _hint() => Text(
    widget.deferSave
        ? (_pool && widget.usedCount > 0
              ? '应用后更新使用该素材的 ${widget.usedCount} 个位置；请在台呼页保存。'
              : '设置下一首进入位置；应用选段后，请在台呼页保存。')
        : _pool && widget.usedCount > 0
        ? '保存后同步更新使用该素材的 ${widget.usedCount} 个台呼位置。'
        : '设置下一首进入位置，让台呼尾音与歌曲自然衔接。',
    style: RmText.sans(11.5, color: context.rm.fg3),
  );

  Widget _editorBody() => Padding(
    padding: const EdgeInsets.all(12),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final side = constraints.maxWidth >= 860;
        final transportWidth = constraints.maxWidth - (side ? 276 : 0);
        final waveHeight = widget.readOnly
            ? 132.0
            : (constraints.maxHeight -
                      (side ? 385 : 430) -
                      (transportWidth < 600 ? 40 : 0))
                  .clamp(48.0, 132.0);
        final rm = context.rm;
        final main = Column(
          key: const ValueKey('stinger-main-column'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _wavePanel(canvasHeight: waveHeight).tourAnchor('wave'),
            const SizedBox(height: 10),
            _transport().tourAnchor('transport'),
            const SizedBox(height: 10),
            if (!widget.readOnly)
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!_hasMaterialEdits)
                    _timeRow('start', 'A · 音频开始', _start).tourAnchor('trim'),
                  const SizedBox(height: 6),
                  if (!_hasMaterialEdits)
                    _timeRow('end', 'B · 音频结束', _end).tourAnchor('trim-end'),
                  const SizedBox(height: 6),
                  _timeRow('next', '下一首开始', _next),
                ],
              ).tourAnchor('timing'),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: RmBanner(
                  kind: RmBannerKind.danger,
                  title: '请调整后重试',
                  body: _error!,
                ),
              ),
            if (_busy)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: LinearProgressIndicator(minHeight: 2),
              ),
          ],
        );
        final settings = Container(
          key: const ValueKey('stinger-settings-panel'),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: rm.raised,
            border: Border.all(color: rm.border),
            borderRadius: BorderRadius.circular(RmTokens.rLg),
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  widget.readOnly ? '原有台呼 · 只读' : '台呼设置',
                  style: RmText.sans(13, color: rm.fg, weight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                if (!widget.readOnly) ...[
                  _assetPicker(),
                  const SizedBox(height: 12),
                  _compactVolume(),
                  Divider(height: 24, color: rm.border),
                ],
                if (widget.songs.isNotEmpty) ...[
                  Text('歌曲衔接', style: RmText.sans(12, color: rm.fg2)),
                  const SizedBox(height: 8),
                  _seamControls().tourAnchor('seam'),
                  const SizedBox(height: 12),
                ],
                _hint(),
              ],
            ),
          ),
        ).tourAnchor('settings');
        return SingleChildScrollView(
          child: side
              ? EditorColumns(main: main, side: settings)
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [main, const SizedBox(height: 10), settings],
                ),
        );
      },
    ),
  );

  Widget _nameField() {
    final rm = context.rm;
    return SizedBox(
      height: 34,
      child: TextField(
        controller: _name,
        enabled: !_busy,
        style: RmText.sans(12, color: rm.fg),
        onChanged: (_) => setState(_remember),
        decoration: InputDecoration(
          labelText: '素材名称',
          labelStyle: RmText.sans(11, color: rm.fg3),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 11,
            vertical: 8,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(RmTokens.rSm),
            borderSide: BorderSide(color: rm.border),
          ),
        ),
      ),
    );
  }

  Widget _wavePanel({double canvasHeight = 132}) {
    final rm = context.rm;
    final wave = _wave;
    final values = (wave['bins'] as List? ?? [])
        .map((v) => stingerNumber(v))
        .toList();
    final bars = WaveformBars.fromValues(values);
    final duration = math.max(.05, _duration);
    final start = _windowStart.clamp(0, math.max(0, duration - _viewSpan));
    final end = math.min(duration, start + _viewSpan);
    return EditorWaveformPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _asset == null && !_hasOriginal
                      ? '尚未分配音频'
                      : _mode == 'original'
                      ? '原有台呼'
                      : _mode == 'seam'
                      ? '歌曲衔接预览 · 近似游戏混音'
                      : '素材波形 · Ctrl+滚轮缩放',
                  style: RmText.sans(11.5, color: rm.fg3),
                ),
              ),
              RmChip(
                label: _asset == null && !_hasOriginal
                    ? '待分配'
                    : stingerTime(duration),
                dense: true,
                variant: RmChipVariant.muted,
              ),
            ],
          ),
          const SizedBox(height: 4),
          StreamBuilder<Duration>(
            stream: widget.player.stream.position,
            builder: (context, p) => ManualFocusWaveform(
              key: const ValueKey('stinger-editor-waveform'),
              bars: bars,
              beats: const [],
              segments: const [],
              duration: duration,
              accent: rm.accent.base,
              handles: [
                if (!_hasMaterialEdits)
                  FocusHandle(
                    key: 'start',
                    t: _clipStart,
                    label: 'A',
                    active: _mode == 'source' && _active == 'start',
                  ),
                if (!_hasMaterialEdits)
                  FocusHandle(
                    key: 'end',
                    t: _clipEnd,
                    label: 'B',
                    active: _mode == 'source' && _active == 'end',
                  ),
                FocusHandle(
                  key: 'next',
                  t: _clipNext,
                  label: 'N',
                  active: _mode == 'source' && _active == 'next',
                ),
              ],
              free: _mode == 'source' && _asset != null,
              locked: _busy,
              playhead: _playhead(p.data ?? widget.player.state.position),
              canvasHeight: canvasHeight,
              windowStart: start.toDouble(),
              windowEnd: end,
              onZoom: _zoom,
              onViewportWidth: (width) => _waveWidth = width,
              onPlace: _place,
              onSeek: _seekPointer,
              timeGrid: true,
            ),
          ),
          const SizedBox(height: 8),
          WaveformOverview(
            key: const ValueKey('stinger-waveform-overview'),
            height: 32,
            bars: bars,
            duration: duration,
            windowStart: start.toDouble(),
            windowEnd: end,
            onWindowStart: (value) => setState(() => _windowStart = value),
          ),
        ],
      ),
    );
  }

  Widget _transport() => StreamBuilder<bool>(
    stream: widget.player.stream.playing,
    builder: (context, p) => StreamBuilder<Duration>(
      stream: widget.player.stream.position,
      builder: (context, position) => EditorTransport(
        inlineBreakpoint: 600,
        playKey: const ValueKey('stinger-editor-play'),
        playing: p.data == true,
        onPlay: _busy || _duration <= 0 ? null : () => _audition(),
        position: Text(
          _duration <= 0 && _asset == null && !_hasOriginal
              ? '尚未分配音频'
              : _clock(position.data ?? widget.player.state.position),
          style: RmText.mono(13, color: context.rm.fg2),
        ),
        onUndo: _busy || widget.readOnly || _editUndo.isEmpty
            ? null
            : () => _restoreEdit(false),
        onRedo: _busy || widget.readOnly || _editRedo.isEmpty
            ? null
            : () => _restoreEdit(true),
        actions: [
          RmButton(
            key: const ValueKey('stinger-use-playhead'),
            label: '取播放位置',
            onPressed:
                _busy || widget.readOnly || _mode != 'source' || _asset == null
                ? null
                : () => _setActive(_playhead(widget.player.state.position)),
          ),
          if (_hasOriginal || _mode != 'source')
            RmButton(
              key: const ValueKey('stinger-original-toggle'),
              label: _mode == 'source' || _asset == null ? '原有台呼' : '返回编辑',
              onPressed: _busy
                  ? null
                  : () {
                      if (_mode == 'source' || _asset == null) {
                        _audition('original');
                        return;
                      }
                      unawaited(widget.player.pause());
                      setState(() {
                        _idlePlayhead = _playhead(widget.player.state.position);
                        if (_showsOriginal) {
                          _span = 0;
                          _windowStart = 0;
                        }
                        _mode = 'source';
                        _opened = null;
                        _offset = 0;
                      });
                    },
            ),
          if (widget.songs.isNotEmpty)
            RmButton(
              key: const ValueKey('stinger-editor-seam'),
              label: '试听歌曲衔接',
              variant: RmButtonVariant.primary,
              leading: const RmIcon('play', size: 12),
              onPressed:
                  _busy ||
                      !_beforeInputValid ||
                      !_afterInputValid ||
                      (_asset == null && !_hasOriginal) ||
                      (_asset != null &&
                          _mode != 'original' &&
                          _invalid != null) ||
                      _before == null ||
                      _after == null
                  ? null
                  : _seam,
            ),
        ],
      ),
    ),
  );

  Widget _compactVolume() {
    final rm = context.rm;
    return Row(
      children: [
        Text('音量', style: RmText.sans(11, color: rm.fg3)),
        Expanded(
          child: SizedBox(
            height: 28,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
              ),
              child: RmSlider(
                value: _gain.clamp(-6, 6),
                min: -6,
                max: 6,
                padding: const EdgeInsets.symmetric(horizontal: 9),
                activeColor: rm.accent.base,
                onChanged: _busy || _asset == null || _mode != 'source'
                    ? null
                    : (v) {
                        _gain = v;
                        _changed();
                      },
              ),
            ),
          ),
        ),
        SizedBox(
          width: 49,
          child: Text(
            '${_gain >= 0 ? '+' : ''}${_gain.toStringAsFixed(1)} dB',
            style: RmText.mono(10, color: rm.fg3),
          ),
        ),
        RmButton.icon(
          key: const ValueKey('stinger-gain-reset'),
          icon: const RmIcon('undo', size: 12),
          tooltip: '恢复默认音量 · 0 dB',
          onPressed: _busy || _asset == null || _mode != 'source'
              ? null
              : () {
                  _gain = 0;
                  _changed();
                },
        ),
      ],
    ).tourAnchor('volume');
  }

  Widget _timeRow(String key, String title, TextEditingController controller) {
    final rm = context.rm;
    final active = _active == key;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: 14,
        vertical: MediaQuery.sizeOf(context).height < 740 ? 5 : 8,
      ),
      decoration: BoxDecoration(
        color: active ? rm.accent.bg : rm.raised,
        border: Border.all(color: active ? rm.accent.base : rm.border),
        borderRadius: BorderRadius.circular(RmTokens.rSm),
      ),
      child: LayoutBuilder(
        builder: (context, c) {
          final controls = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              RmButton(
                label: '−10',
                size: RmButtonSize.sm,
                repeat: true,
                tooltip: '减少 10 ms',
                onPressed: _busy || _asset == null || _mode != 'source'
                    ? null
                    : () {
                        _active = key;
                        _setActive(_activeTime - .01);
                      },
              ),
              const SizedBox(width: 4),
              RmButton(
                label: '+10',
                size: RmButtonSize.sm,
                repeat: true,
                tooltip: '增加 10 ms',
                onPressed: _busy || _asset == null || _mode != 'source'
                    ? null
                    : () {
                        _active = key;
                        _setActive(_activeTime + .01);
                      },
              ),
              const SizedBox(width: 4),
              Text('ms', style: RmText.mono(10, color: rm.fg4)),
            ],
          );
          final field = Focus(
            onFocusChange: (focused) {
              if (focused) setState(() => _active = key);
            },
            child: TimeInputField(
              key: ValueKey('stinger-time-$key'),
              seconds: key == 'start'
                  ? _clipStart
                  : key == 'end'
                  ? _clipEnd
                  : _showsOriginal
                  ? _clipNext
                  : _n,
              fontSize: 20,
              fontWeight: FontWeight.w600,
              textAlign: TextAlign.center,
              onCommit: _busy || _asset == null || _mode != 'source'
                  ? null
                  : (seconds) {
                      controller.text = seconds.toString();
                      _changed();
                    },
            ),
          );
          return Row(
            children: [
              SizedBox(
                width: c.maxWidth < 600 ? 105 : 145,
                child: GestureDetector(
                  onTap: () => setState(() => _active = key),
                  child: Text(
                    title,
                    style: RmText.mono(
                      11.5,
                      color: active ? rm.accent.base : rm.fg3,
                    ),
                  ),
                ),
              ),
              Expanded(child: field),
              const SizedBox(width: 10),
              controls,
            ],
          );
        },
      ),
    );
  }

  Widget _seamControls() {
    final rm = context.rm;
    Widget song(bool before) => RmSelect<String>(
      value: (before ? _before : _after) ?? '',
      selectedPrefix: before ? '上一首' : '下一首',
      items: {
        if (widget.songs.isEmpty) '': '尚无项目歌曲',
        for (final song in widget.songs) '${song['path']}': '${song['name']}',
      },
      onChanged: _busy
          ? null
          : (v) => setState(() {
              if (before) {
                _before = v;
              } else {
                _after = v;
              }
              _storeAudition();
              _schedulePreview();
            }),
    );
    Widget seconds(bool before) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            before ? '台呼前音乐' : '下一首试听',
            style: RmText.sans(11.5, color: rm.fg3),
          ),
          const SizedBox(height: 6),
          TextFormField(
            key: ValueKey(
              'stinger-seam-${before ? 'before' : 'after'}-seconds',
            ),
            initialValue: (before ? _beforeSeconds : _afterSeconds).toString(),
            enabled: !_busy,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: RmText.mono(12, color: rm.fg),
            decoration: InputDecoration(
              isDense: true,
              suffixText: '秒',
              filled: true,
              fillColor: rm.raised,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 8,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(RmTokens.rSm),
                borderSide: BorderSide(color: rm.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(RmTokens.rSm),
                borderSide: BorderSide(color: rm.accent.base),
              ),
              errorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(RmTokens.rSm),
                borderSide: BorderSide(color: rm.danger),
              ),
            ),
            autovalidateMode: AutovalidateMode.onUserInteraction,
            validator: (text) {
              final value = double.tryParse(text ?? '');
              return value == null ||
                      !value.isFinite ||
                      value < 0 ||
                      value > (before ? 30 : 60)
                  ? (before ? '请输入 0–30 秒' : '请输入 0–60 秒')
                  : null;
            },
            onChanged: (text) {
              final value = double.tryParse(text);
              if (value == null ||
                  !value.isFinite ||
                  value < 0 ||
                  value > (before ? 30 : 60)) {
                setState(() {
                  if (before) {
                    _beforeInputValid = false;
                  } else {
                    _afterInputValid = false;
                  }
                });
                return;
              }
              setState(() {
                if (before) {
                  _beforeSeconds = value;
                  _beforeInputValid = true;
                } else {
                  _afterSeconds = value;
                  _afterInputValid = true;
                }
              });
              _storeAudition();
              _schedulePreview();
            },
          ),
        ],
      ),
    );
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: rm.raised,
        border: Border.all(color: rm.border),
        borderRadius: BorderRadius.circular(RmTokens.rMd),
      ),
      child: LayoutBuilder(
        builder: (context, c) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (c.maxWidth > 650)
              Row(
                children: [
                  Expanded(child: song(true)),
                  const SizedBox(width: 8),
                  Expanded(child: song(false)),
                ],
              )
            else ...[
              song(true),
              const SizedBox(height: 8),
              song(false),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                seconds(true),
                const SizedBox(width: 8),
                seconds(false),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '默认前 6 秒、后 4 秒；仅影响试听长度。',
              style: RmText.sans(10.5, color: rm.fg3),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _clearReplacement() async {
    final confirmed = await showDialog<bool>(
      context: context,
      useRootNavigator: false,
      builder: (ctx) => TimingDialogFrame(
        title: '清除此位置的替换？',
        icon: 'info',
        busy: false,
        width: 440,
        body: Text(
          'R${widget.station?['radio']} · 台呼 ${widget.slot?['number']}${widget.slot?['additional'] == true ? '将变为待分配位置，构建前需重新分配音频或移除此位置。' : '将恢复原有台呼。'}素材仍保留在池中；应用后还需在台呼页保存。',
          style: RmText.body(color: ctx.rm.fg3),
        ),
        actions: [
          RmButton(
            key: const ValueKey('stinger-clear-cancel'),
            label: '取消',
            onPressed: () => Navigator.pop(ctx, false),
          ),
          RmButton(
            key: const ValueKey('stinger-clear-confirm'),
            label: '清除替换',
            variant: RmButtonVariant.dangerPrimary,
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _run(() async {
      await widget.call('update', {
        'slot_id': widget.slot!['id'],
        'asset_id': null,
      });
      widget.onSaved?.call({'clear': true});
      if (mounted) Navigator.pop(context, true);
    });
  }

  Widget _footer() {
    final rm = context.rm;
    return Container(
      key: const ValueKey('stinger-editor-footer'),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: rm.border)),
      ),
      child: LayoutBuilder(
        builder: (context, c) {
          final actions = Wrap(
            spacing: 8,
            runSpacing: 6,
            alignment: WrapAlignment.end,
            children: [
              if (!widget.readOnly && widget.slot?['assignment'] != null)
                RmButton(
                  key: const ValueKey('stinger-clear-replacement'),
                  label: '清除替换',
                  variant: RmButtonVariant.dangerOutline,
                  onPressed: _busy ? null : _clearReplacement,
                ),
              RmButton(
                key: const ValueKey('stinger-editor-cancel'),
                label: '取消',
                onPressed: _busy ? null : () => Navigator.pop(context),
              ).tourAnchor('confirm'),
              if (!widget.readOnly)
                RmButton(
                  key: const ValueKey('stinger-editor-save'),
                  label: widget.deferSave
                      ? '应用选段'
                      : _pool
                      ? '保存素材'
                      : '保存分配',
                  leading: const Icon(Icons.check, size: 14),
                  variant: RmButtonVariant.primary,
                  onPressed: _busy || _invalid != null ? null : _save,
                ).tourAnchor('confirm-end'),
            ],
          );
          final keys = ref.watch(editorShortcutsProvider);
          final help = Row(
            children: [
              RmIcon('info', size: 14, color: rm.fg3),
              const SizedBox(width: 8),
              Expanded(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final hint in [
                      '${keys[EditorAction.play]!.label} 播放 / 暂停',
                      'Ctrl + 滚轮缩放',
                      if (!widget.readOnly && _asset != null) ...[
                        '${keys[EditorAction.beatBack]!.label} / ${keys[EditorAction.beatForward]!.label} ${stingerNudgeMs}ms',
                        '${keys[EditorAction.tenBack]!.label} / ${keys[EditorAction.tenForward]!.label} 10ms',
                        '${keys[EditorAction.oneBack]!.label} / ${keys[EditorAction.oneForward]!.label} 1ms',
                        '${keys[EditorAction.markPlayback]!.label} 取播放位置',
                        '${keys[EditorAction.undo]!.label} 撤销',
                        '${keys[EditorAction.redo]!.label} 重做',
                        '${keys[EditorAction.confirm]!.label} 确认',
                        '${keys[EditorAction.save]!.label} ${widget.deferSave ? '应用选段' : '保存'}',
                      ],
                      'Esc 返回',
                    ])
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: rm.raised,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          hint,
                          style: RmText.sans(11, color: rm.fg2),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          );
          return c.maxWidth > 760
              ? Row(
                  children: [
                    Expanded(child: help),
                    const SizedBox(width: 12),
                    actions,
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    help,
                    const SizedBox(height: 8),
                    Align(alignment: Alignment.centerRight, child: actions),
                  ],
                );
        },
      ),
    );
  }
}
