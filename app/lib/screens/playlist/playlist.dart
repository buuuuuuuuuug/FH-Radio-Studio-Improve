import '../../widgets/pool_selection_actions.dart';
import '../../widgets/playlist_toolbar_row.dart';
import '../../widgets/playlist_search_field.dart';
import '../../state/unsaved_edits.dart';
import 'playlist_view_switch.dart';
import '../../widgets/cross_radio_assignment_notice.dart';
import '../../widgets/feature_tour.dart';
import '../../widgets/package_publication_recovery.dart';
import 'playlist_draggable.dart';
import 'playlist_drag_preview.dart';
import '../../widgets/open_package_folder_button.dart';
import '../../core/playlist_capacity.dart';
import '../../core/playlist_action_errors.dart';
import '../../widgets/quick_assign_dialog.dart';
import '../../widgets/split_playlist_setting.dart';
import '../../core/track_timing_config.dart';
import '../../core/playlist_timing_requirements.dart';
import '../../state/editor_navigation.dart';
import '../../core/song_selection.dart';
import '../../widgets/batch_assignment_dialog.dart';
import 'package:go_router/go_router.dart';
import '../../state/router.dart';
import '../../state/editor_options.dart';
import 'dart:async';
import 'package:flutter/services.dart';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import '../../widgets/contained_scroll.dart';
import '../../widgets/playlist_layout_controls.dart';
import '../../state/layout_options.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/playlist_plan.dart';
import '../../core/song_browse.dart';
import '../../widgets/song_browse_controls.dart';
import '../../domain/radio_library.dart';
import '../../state/studio_state.dart';
import '../../state/playlist_catalog_state.dart';
import '../../state/playlist_plan_state.dart';
import '../../state/track_timing_state.dart';
import '../../theme/app_theme.dart';
import '../../theme/text_styles.dart';
import '../../theme/tokens.dart';
import '../../widgets/package_build_notice_dialog.dart';
import '../../widgets/package_loudness_dialog.dart';
import '../../widgets/rm_banner.dart';
import '../../widgets/rm_button.dart';
import '../../widgets/rm_chip.dart';
import '../../widgets/rm_icon.dart';
import '../../widgets/rm_panel.dart';
import '../../widgets/rm_segmented.dart';
import 'playlist_state.dart';
import 'radio_column.dart';
import 'switch_mode_modal.dart';
import 'track_card.dart';

const double _playlistPageMaxWidth = 1280;

class PlaylistScreen extends ConsumerStatefulWidget {
  const PlaylistScreen({super.key});

  @override
  ConsumerState<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends ConsumerState<PlaylistScreen> {
  final _boardScroll = ScrollController();
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
        ref.read(layoutOptionsProvider).heightMode != RadioHeightMode.oneRow) {
      return false;
    }
    _rowSnapTimer?.cancel();
    _rowSnapTimer = Timer(const Duration(milliseconds: 450), () async {
      if (!mounted ||
          !_boardScroll.hasClients ||
          _boardScroll.position.isScrollingNotifier.value ||
          _rowExtent <= 0 ||
          ref.read(layoutOptionsProvider).heightMode !=
              RadioHeightMode.oneRow) {
        return;
      }
      final target = (_boardScroll.offset / _rowExtent).round() * _rowExtent;
      final offset = target.clamp(0.0, _boardScroll.position.maxScrollExtent);
      if ((offset - _boardScroll.offset).abs() < 1) return;
      await _boardScroll.animateTo(
        offset,
        duration: const Duration(milliseconds: 190),
        curve: Curves.easeOutCubic,
      );
    });
    return false;
  }

  void _restorePlaylistHistory({required bool redo}) {
    final history = ref.read(playlistPlanProvider.notifier);
    try {
      if (redo) {
        history.redo();
      } else {
        history.undo();
      }
    } on PlaylistCapacityException catch (error) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error.toString()),
          duration: const Duration(seconds: 7),
        ),
      );
    }
  }

  void _savePlaylist() {
    final cli = ref.read(studioProvider);
    if (cli.busy ||
        cli.projectEditingLocked ||
        ref.read(playlistCatalogViewProvider) != PlaylistCatalogView.package) {
      return;
    }
    try {
      ref.read(playlistPlanProvider.notifier).save();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('歌曲分配与顺序已保存。')));
    } on Object catch (error) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(playlistActionFailure('保存播放列表', error)),
          duration: const Duration(seconds: 8),
        ),
      );
    }
  }

  KeyEventResult _onPlaylistKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || ModalRoute.of(context)?.isCurrent == false) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    if (event.logicalKey == LogicalKeyboardKey.escape &&
        (_selecting || _selection.ids.isNotEmpty)) {
      setState(() {
        _selecting = false;
        _selection = SongSelection();
      });
      return KeyEventResult.handled;
    }
    final typing =
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorStateOfType<EditableTextState>() !=
        null;
    if (!keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyS &&
        !keyboard.isShiftPressed) {
      _savePlaylist();
      return KeyEventResult.handled;
    }
    if (typing ||
        ref.read(playlistCatalogViewProvider) != PlaylistCatalogView.package) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyZ &&
        !keyboard.isShiftPressed) {
      _restorePlaylistHistory(redo: false);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyY &&
        !keyboard.isShiftPressed) {
      _restorePlaylistHistory(redo: true);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Object? _radioWidgetInputs,
      _poolWidgetInputs,
      _poolPlanInputs,
      _displayPoolInputs;
  List<Widget> _cachedRadioWidgets = const [];
  Widget? _cachedPoolWidget;
  PlaylistPlan? _cachedPoolPlan;
  List<PoolTrack> _cachedDisplayPool = const [];

  late final TextEditingController _search;
  @override
  void initState() {
    super.initState();
    _search = TextEditingController(text: ref.read(playlistProvider).search);
  }

  @override
  void dispose() {
    _selectionSignal.dispose();
    _rowSnapTimer?.cancel();
    _boardScroll.dispose();
    _search.dispose();
    super.dispose();
  }

  SongBrowse _browse = const SongBrowse();
  final _selectionSignal = ValueNotifier(SongSelection());
  SongSelection get _selection => _selectionSignal.value;
  set _selection(SongSelection value) => _selectionSignal.value = value;
  bool _selecting = false;
  String _selectionProject = '';
  String _selectionScope = 'pool';
  void _toggleSelection(String scope) {
    setState(() {
      _selecting = !_selecting || _selectionScope != scope;
      _selectionScope = scope;
      _selection = SongSelection();
    });
  }

  void _selectPoolTrack(
    PoolTrack track,
    List<PoolTrack> visible, {
    bool control = false,
    bool range = false,
    String scope = 'pool',
  }) {
    if (!_selecting && !control && !range) return;
    final selection = (_selectionScope == scope ? _selection : SongSelection())
        .click(track.id, visible.map((t) => t.id).toList(), range: range);
    if (!_selecting) {
      setState(() => _selecting = true);
    }
    _selectionScope = scope;
    _selection = selection;
  }

  Future<void> _assignSelected(List<PoolTrack> visible) async {
    final state = ref.read(playlistProvider);
    final ids = _selection.ids;
    final tracks = [
      for (final t in visible)
        if (ids.contains(t.id)) t,
      for (final t in state.pool)
        if (ids.contains(t.id) && !visible.any((v) => v.id == t.id)) t,
    ];
    if (tracks.isEmpty) return;
    final catalog = ref.read(playlistCatalogProvider);
    final baseline = ref.read(baselinePlaylistCatalogProvider);
    final radios = catalog.radios
        .where((r) => isUiSupportedRadio(name: r.name))
        .toList();
    if (radios.isEmpty) return;
    final project = ref.read(studioProvider).projectDir;
    final plan = ref.read(effectivePlaylistPlanProvider);
    final expansion = ref.read(editorOptionsProvider).expansionEnabled;
    final choice = await showDialog<({String radio, String type, int limit})>(
      context: context,
      builder: (_) => BatchAssignmentDialog(
        radios: radios,
        tracks: tracks,
        splitTypes: state.splitPlaylistTypes,
        initialType: state.splitPlaylistTypes ? 'Event' : 'FreeRoam',
        info: (radio, type) {
          var base = plan;
          if (!base.hasDraft &&
              !ref.read(playlistPlanProvider.notifier).hasUserPlan) {
            base = playlistPlanFromCatalog(
              catalog,
              state.pool,
              projectDir: project,
              includeBuiltinTargets: false,
            );
          }
          if (!state.splitPlaylistTypes) {
            base = base.syncPlaylistTypesFrom(type);
          }
          final current = base.assignmentsForRadio(radio.code, type).length;
          final added = tracks
              .where(
                (t) =>
                    base.assignmentFor(
                      source: t.source,
                      radioCode: radio.code,
                      playlistType: type,
                    ) ==
                    null,
              )
              .length;
          final original =
              baseline?.tracksOfRadio(radio.code, type).length ?? 0;
          return BatchAssignmentInfo(
            total: current + added,
            added: added,
            limit: expansion ? 4096 : (original > 0 ? original : radio.slot),
            crossRadioCount: tracks
                .where(
                  (track) => base
                      .assignmentsForPath(track.source)
                      .any((a) => a.radioCode != radio.code),
                )
                .length,
            replacesBuiltin:
                current == 0 &&
                catalog.modeOfList(radio.code, type) != StationMode.custom,
          );
        },
      ),
    );
    if (choice == null ||
        !mounted ||
        ref.read(studioProvider).projectDir != project) {
      return;
    }
    final success = ref
        .read(playlistProvider.notifier)
        .assignManyToRadio(
          tracks.map((t) => t.id).toList(),
          choice.radio,
          choice.type,
          maxSlots: choice.limit,
        );
    if (success) _selection = SongSelection();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          success
              ? '已分配到 ${choice.radio}，可撤销此次批量操作。'
              : ref.read(playlistProvider.notifier).lastEditBlockedReason ??
                    '分配未完成：容量或项目状态已变化，未部分写入。',
        ),
      ),
    );
  }

  bool _matches(PlaylistState s, PoolTrack t) {
    final q = s.search.trim().toLowerCase();
    if (q.isEmpty) return true;
    return t.title.toLowerCase().contains(q) ||
        t.artist.toLowerCase().contains(q) ||
        t.source.toLowerCase().contains(q);
  }

  bool _matchesRef(PlaylistState s, TrackRef t) {
    final q = s.search.trim().toLowerCase();
    if (q.isEmpty) return true;
    return t.title.toLowerCase().contains(q) ||
        t.artist.toLowerCase().contains(q);
  }

  Future<void> _assign(
    _PlaylistDragData data,
    RadioStation radio,
    String playlistType,
    bool isCustom,
    int maxSlots,
    List<TrackRef> originalTracks,
  ) async {
    if (data.originRadioCode == radio.code &&
        data.originPlaylistType == playlistType &&
        isCustom) {
      ref
          .read(playlistProvider.notifier)
          .reorderMany(
            data.tracks.map((t) => t.source).toList(),
            '',
            radio.code,
            playlistType,
          );
      return;
    }
    final project = ref.read(studioProvider).projectDir;
    bool assignTrack() {
      if (!mounted || ref.read(studioProvider).projectDir != project) {
        return false;
      }
      final assigned = ref
          .read(playlistProvider.notifier)
          .assignManyToRadio(
            data.tracks.map((t) => t.id).toList(),
            radio.code,
            playlistType,
            maxSlots: maxSlots,
            originRadioCode: data.originRadioCode,
            originPlaylistType: data.originPlaylistType,
          );
      if (!assigned && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              ref.read(playlistProvider.notifier).lastEditBlockedReason ??
                  '${radio.name} 容量不足（上限 $maxSlots 首），整批 ${data.tracks.length} 首均未移动。',
            ),
          ),
        );
      }
      if (assigned) _selection = SongSelection();
      return assigned;
    }

    if (!isCustom) {
      await SwitchModeModal.show(
        context,
        radio: radio,
        track: data.track,
        trackCount: data.tracks.length,
        originalTracks: originalTracks,
        onConfirm: assignTrack,
      );
      return;
    }
    assignTrack();
  }

  Future<void> _restoreBuiltin(
    RadioStation radio,
    String playlistType,
    List<PoolTrack> assignedTracks,
  ) async {
    final ok = await _confirmRestoreBuiltin(
      context,
      radio: radio,
      playlistType: playlistType,
      assignedTracks: assignedTracks,
    );
    if (!ok || !mounted) return;
    ref
        .read(playlistProvider.notifier)
        .restoreBuiltin(radio.code, playlistType);
  }

  Future<void> _useOtherScenePlaylist(
    RadioStation radio,
    String playlistType,
  ) async {
    final fromType = playlistType == 'Event' ? 'FreeRoam' : 'Event';
    final project = ref.read(studioProvider).projectDir;
    final plan = ref.read(effectivePlaylistPlanProvider);
    final confirmed = await _confirmRestoreBuiltin(
      context,
      radio: radio,
      playlistType: playlistType,
      assignedTracks: ref
          .read(playlistProvider)
          .tracksOfRadio(radio.code, playlistType, plan),
      copyFromType: fromType,
    );
    if (!confirmed || !mounted) return;
    if (ref.read(studioProvider).projectDir != project ||
        ref.read(effectivePlaylistPlanProvider).encodeForStorage() !=
            plan.encodeForStorage()) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('歌单已变化，请重新打开窗口确认。')));
      return;
    }
    final notifier = ref.read(playlistProvider.notifier);
    try {
      final copied = notifier.copyScenePlaylist(
        radio.code,
        fromType: fromType,
        toType: playlistType,
      );
      if (copied) _selection = SongSelection();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            copied
                ? '已在 ${radio.code} 的${_playlistLabel(playlistType)}中使用${_playlistLabel(fromType)}歌单；来源歌单保留，可撤销或保存。'
                : notifier.lastEditBlockedReason ?? '当前无法套用另一场景的歌单。',
          ),
        ),
      );
    } on Object catch (error) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(playlistActionFailure('套用场景歌单', error))),
      );
    }
  }

  Future<void> _handlePoolDrop(
    BuildContext context,
    PlaylistState s,
    PlaylistCatalog catalog,
    PlaylistPlan plan,
    _PlaylistDragData data,
  ) async {
    final originRadio = data.originRadioCode;
    final originType = data.originPlaylistType;
    if (originRadio == null || originType == null) return;

    plan = editableAssignmentPlan(ref);
    final assignments = plan.assignmentsForRadio(originRadio, originType);
    if (assignments.length <= data.tracks.length) {
      final radio = _radioByCode(catalog, originRadio);
      if (radio == null) return;
      final assignedTracks = s.tracksOfRadio(originRadio, originType, plan);
      await _restoreBuiltin(radio, originType, assignedTracks);
      return;
    }

    ref
        .read(playlistProvider.notifier)
        .unassignMany(
          data.tracks.map((t) => t.id).toList(),
          radioCode: originRadio,
          playlistType: originType,
        );
    _selection = SongSelection();
  }

  RadioStation? _radioByCode(PlaylistCatalog catalog, String code) {
    for (final radio in catalog.radios) {
      if (radio.code == code) return radio;
    }
    return null;
  }

  String _playlistLabel(String playlistType) {
    return PlaylistAssignment.playlistLabel(playlistType);
  }

  Future<bool> _confirmRestoreBuiltin(
    BuildContext context, {
    required RadioStation radio,
    required String playlistType,
    required List<PoolTrack> assignedTracks,
    String? copyFromType,
  }) async {
    final otherType = playlistType == 'Event' ? 'FreeRoam' : 'Event';
    final blockedMixedRestore =
        copyFromType == null &&
        ref.read(playlistProvider).splitPlaylistTypes &&
        (ref
                .read(effectivePlaylistPlanProvider)
                .hasAssignmentsForRadio(radio.code, otherType) ||
            ref
                    .read(playlistCatalogProvider)
                    .modeOfList(radio.code, otherType) ==
                StationMode.custom);
    final result = await showDialog<bool>(
      context: context,
      barrierColor: RmTokens.modalBackdrop,
      builder: (context) {
        final rm = context.rm;
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(40),
          child: Container(
            width: 500,
            constraints: const BoxConstraints(maxHeight: 620),
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
                  padding: const EdgeInsets.fromLTRB(24, 22, 24, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        copyFromType == null ? '恢复游戏原版' : '套用另一场景歌单',
                        style: RmText.microLabel(color: rm.warn),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        copyFromType == null
                            ? '把 ${radio.name} 的${_playlistLabel(playlistType)}列表恢复为 builtin？'
                            : '在 ${radio.name} 的${_playlistLabel(playlistType)}中使用${_playlistLabel(copyFromType)}歌单？',
                        style: RmText.modalH2(color: rm.fg),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        copyFromType != null
                            ? '这会替换当前场景的歌曲与顺序，来源歌单保留，可撤销。不支持一边原版、一边自建。'
                            : blockedMixedRestore
                            ? '两场景共用曲库，暂不支持一边原版、一边自建。请先关闭分场景编辑，合并列表后恢复整台。'
                            : '这会清空当前列表里的自建曲目分配；下次生成包时，这个列表不再参与替换。',
                        style: RmText.sans(13, color: rm.fg3, height: 1.45),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(24, 18, 24, 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          copyFromType == null ? '将移出的自建曲目' : '将替换的当前歌单',
                          style: RmText.microLabel(color: rm.fg3),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final track in assignedTracks)
                              RmChip(
                                label: track.title,
                                variant: RmChipVariant.danger,
                                showDot: true,
                              ),
                          ],
                        ),
                        if (copyFromType != null) ...[
                          const SizedBox(height: 16),
                          Text(
                            '将使用的${_playlistLabel(copyFromType)}歌单',
                            style: RmText.microLabel(color: rm.fg3),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (final track
                                  in ref
                                      .read(playlistProvider)
                                      .tracksOfRadio(
                                        radio.code,
                                        copyFromType,
                                        ref.read(effectivePlaylistPlanProvider),
                                      ))
                                RmChip(
                                  label: track.title,
                                  variant: RmChipVariant.accent,
                                  showDot: true,
                                ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.fromLTRB(24, 14, 24, 22),
                  decoration: BoxDecoration(
                    border: Border(top: BorderSide(color: rm.border)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      RmButton(
                        onPressed: () => Navigator.of(context).pop(false),
                        label: '取消',
                      ),
                      const SizedBox(width: 10),
                      RmButton(
                        onPressed: blockedMixedRestore
                            ? null
                            : () => Navigator.of(context).pop(true),
                        variant: RmButtonVariant.primary,
                        leading: copyFromType == null
                            ? const RmIcon('undo', size: 12)
                            : const Icon(Icons.swap_horiz, size: 14),
                        label: copyFromType == null
                            ? '恢复 builtin'
                            : '使用${_playlistLabel(copyFromType)}歌单',
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
    return result == true;
  }

  Future<void> _copyGameLayoutToPackage(BuildContext context) async {
    final catalog = ref.read(gamePlaylistCatalogProvider);
    final sceneState = ref.read(playlistProvider);
    final unifiedType = sceneState.mode == PlaylistMode.event
        ? 'Event'
        : 'FreeRoam';
    final unifiedLabel = PlaylistAssignment.playlistLabel(unifiedType);
    final messenger = ScaffoldMessenger.of(context);
    if (catalog.failed) {
      messenger.showSnackBar(
        SnackBar(content: Text(catalog.error ?? '没有找到可读取的游戏内播放列表。')),
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      barrierColor: RmTokens.modalBackdrop,
      builder: (dialogContext) => Dialog(
        backgroundColor: context.rm.panel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(RmTokens.rLg),
          side: BorderSide(color: context.rm.border),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '复制游戏内排布？',
                  style: RmText.sans(
                    18,
                    weight: FontWeight.w600,
                    color: context.rm.fg,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '这会替换准备包中当前的歌曲分配与顺序，包括尚未保存的修改。歌曲和时间点不会删除；复制后可撤销。'
                  '${sceneState.splitPlaylistTypes ? '' : '\n当前为统一编辑：采用游戏内$unifiedLabel列表，并同时用于漫游和比赛；已保留的分场景列表不变。'}',
                  style: RmText.body(color: context.rm.fg2),
                ),
                const SizedBox(height: 20),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    RmButton(
                      label: '取消',
                      onPressed: () => Navigator.pop(dialogContext, false),
                    ),
                    RmButton(
                      key: const ValueKey('confirm-copy-game-layout'),
                      label: '确认替换',
                      variant: RmButtonVariant.primary,
                      onPressed: () => Navigator.pop(dialogContext, true),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!mounted || confirmed != true) return;
    try {
      final copied = ref
          .read(playlistProvider.notifier)
          .copyGameLayout(catalog, unifiedType: unifiedType);
      ref.read(playlistCatalogViewProvider.notifier).state =
          PlaylistCatalogView.package;
      messenger.showSnackBar(
        SnackBar(content: Text('已复制当前游戏内排布：$copied 首自建曲目。')),
      );
    } on Object catch (error) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(playlistActionFailure('复制游戏内排布', error)),
          duration: const Duration(seconds: 8),
        ),
      );
    }
  }

  Future<void> _preparePackageFromUi(BuildContext context) async {
    try {
      await _preparePackage(context);
    } on Object catch (error) {
      if (!mounted || !context.mounted) return;
      await showPackageBuildNoticeDialog(
        context,
        message: playlistActionFailure('构建准备包', error),
        languageChanged: false,
        showPlaylistAction: false,
      );
    }
  }

  Future<void> _preparePackage(BuildContext context) async {
    if (!await ref.read(unsavedEditsProvider).confirmForBuild(context) ||
        !context.mounted) {
      return;
    }
    final plan = editableAssignmentPlan(ref);
    final radiosMissingScene =
        {
              for (final assignment in plan.assignments.values)
                if (assignment.isAssigned) assignment.radioCode,
            }
            .where(
              (radio) =>
                  plan.assignmentsForRadio(radio, 'FreeRoam').isEmpty ||
                  plan.assignmentsForRadio(radio, 'Event').isEmpty,
            )
            .toList();
    if (radiosMissingScene.isNotEmpty) {
      await showPackageBuildNoticeDialog(
        context,
        message:
            '${radiosMissingScene.join('、')} 的漫游或比赛列表为空。两场景共用曲库，目前必须都安排至少一首自建歌曲，暂不支持一边原版、一边自建。请补齐另一场景，或关闭分场景编辑后使用统一列表。',
        languageChanged: false,
        showPlaylistAction: false,
      );
      return;
    }
    final timings = ref.read(trackTimingProvider);
    final pool = ref.read(playlistProvider).pool;
    final incomplete = plan.assignments.values
        .where(
          (a) =>
              a.isAssigned &&
              !isFreeRoamOnlySource(plan, a.source) &&
              timings[TrackTimingConfig.keyForPath(a.source)]?.allConfirmed !=
                  true,
        )
        .toList();
    if (incomplete.isNotEmpty) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: context.rm.panel,
          title: Text(
            '还有歌曲未完成配置',
            style: RmText.modalH2(color: context.rm.warn),
          ),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '分配可以保留；以下比赛歌曲需完成 6 个节点并保存。仅漫游歌曲无需人工确认，构建时自动补全有效点位。',
                    style: RmText.sans(12, color: context.rm.fg2),
                  ),
                  const SizedBox(height: 10),
                  for (final source in incomplete.map((a) => a.source).toSet())
                    Builder(
                      builder: (context) {
                        final track = pool
                            .where(
                              (t) =>
                                  TrackTimingConfig.keyForPath(t.source) ==
                                  TrackTimingConfig.keyForPath(source),
                            )
                            .firstOrNull;
                        final radios = incomplete
                            .where((a) => a.source == source)
                            .map((a) => a.radioCode)
                            .toSet()
                            .join(' / ');
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            track?.title ?? source,
                            maxLines: 2,
                            style: RmText.sans(12, color: context.rm.fg),
                          ),
                          subtitle: Text(
                            '$radios · 未完成',
                            style: RmText.sans(11, color: context.rm.warn),
                          ),
                          trailing: track == null
                              ? null
                              : RmButton(
                                  label: '配置',
                                  onPressed: () {
                                    Navigator.pop(context);
                                    _openTrackEditor(track);
                                  },
                                ),
                        );
                      },
                    ),
                ],
              ),
            ),
          ),
          actions: [
            RmButton(label: '返回播放列表', onPressed: () => Navigator.pop(context)),
          ],
        ),
      );
      return;
    }
    final cli = ref.read(studioProvider.notifier);
    final preview = cli.buildPackageLoudnessPreview();
    final buildPlan = ref.read(effectivePlaylistPlanProvider);
    var buildQuality = 50;
    final loudnessOffsetLu = await showPackageLoudnessDialog(
      context,
      referenceMedianLufs: preview.referenceMedianLufs,
      initialOffsetLu: preview.initialOffsetLu,
      previewInputLufs: preview.previewInputLufs,
      previewTracks: cli.buildPackageLoudnessPreviews(),
      assignmentPlan: buildPlan,
      previewSource: preview.source,
      previewTitle: preview.previewTitle,
      previewArtist: preview.previewArtist,
      currentPackageOffsetLu: preview.currentPackageOffsetLu,
      sizeEstimate: cli.estimatePackageSizes(buildPlan),
      onQualityChanged: (quality) => buildQuality = quality,
    );
    if (loudnessOffsetLu == null) return;
    if (!mounted) return;
    if (!context.mounted) return;
    final built = await cli.buildPackage(
      loudnessOffsetLu: loudnessOffsetLu,
      quality: buildQuality,
      plan: buildPlan,
    );
    if (!mounted) return;
    if (!context.mounted) return;
    final latest = ref.read(studioProvider);
    if (latest.packageBuildCancelled) return;
    if (built) {
      ref.read(playlistPlanProvider.notifier).save();
      final summary = latest.lastPackageSummary;
      await showPackageBuildSuccessDialog(
        context,
        detail: summary?.detail ?? '准备包已生成。',
        trackPreview: summary?.trackPreview ?? '未读取到曲目信息',
        packageDir: latest.lastPackageDir,
      );
      return;
    }
    final handledMissing = await _handleMissingPlaylistSources(context, latest);
    if (!mounted) return;
    if (!context.mounted || handledMissing) return;
    await showPackageBuildNoticeDialog(
      context,
      message: _latestBuildPackageMessage(latest),
      languageChanged: !latest.languageSelectionMatchesGame,
      showPlaylistAction: false,
    );
  }

  Future<bool> _handleMissingPlaylistSources(
    BuildContext context,
    StudioState latest,
  ) async {
    final missing = ref.read(effectivePlaylistPlanProvider).missingSources();
    if (missing.isEmpty) return false;
    final action = await showMissingPlaylistSourcesDialog(
      context,
      sources: missing,
    );
    if (!mounted || !context.mounted) return true;
    if (action != MissingPlaylistSourcesAction.cleanup) return true;
    final cleaned = await ref
        .read(studioProvider.notifier)
        .cleanupMissingPlaylistSources(missing);
    if (!mounted || !context.mounted) return true;
    ref.read(playlistPlanProvider.notifier).removeDeletedSources(missing);
    ref.read(trackTimingProvider.notifier).reload();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(cleaned > 0 ? '已删除 $cleaned 首失效歌曲。' : '没有发现需要删除的失效歌曲。'),
      ),
    );
    return true;
  }

  String _latestBuildPackageMessage(StudioState state) {
    for (final line in state.log.reversed) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (trimmed.startsWith('==')) continue;
      if (trimmed.startsWith('执行：')) continue;
      if (trimmed.startsWith('退出码：')) continue;
      return trimmed;
    }
    return '准备包没有生成。';
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(playlistProvider);
    final project = ref.watch(studioProvider.select((s) => s.projectDir));
    if (_selectionProject != project) {
      _selectionProject = project;
      _selection = SongSelection();
      _selecting = false;
    }
    final poolIds = s.pool.map((t) => t.id).toSet();
    _selection.ids.removeWhere((id) => !poolIds.contains(id));

    if (_search.text != s.search) {
      _search.value = TextEditingValue(
        text: s.search,
        selection: TextSelection.collapsed(offset: s.search.length),
      );
    }
    final cli = ref.watch(studioProvider);
    final view = ref.watch(playlistCatalogViewProvider);
    final catalog = ref.watch(playlistCatalogProvider);
    final baselineCatalog = ref.watch(baselinePlaylistCatalogProvider);
    final plan = ref.watch(effectivePlaylistPlanProvider);
    final poolPlan = _poolAssignmentPlan(catalog, plan, s.pool);
    final editingPlan =
        ref.read(playlistPlanProvider.notifier).hasUserPlan || plan.hasDraft
        ? plan
        : poolPlan;
    final displayInputs = (s.pool, editingPlan, s.search);
    if (_displayPoolInputs != displayInputs) {
      _displayPoolInputs = displayInputs;
      _cachedDisplayPool = s
          .poolForDisplay(editingPlan)
          .where((t) => _matches(s, t))
          .toList();
    }
    final pool = _cachedDisplayPool;

    return Focus(
      autofocus: true,
      onKeyEvent: _onPlaylistKey,
      child: ContainedScroll(
        controller: _boardScroll,
        child: Center(
          child: Consumer(
            builder: (context, layoutRef, child) => ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: layoutRef.watch(
                  layoutOptionsProvider.select(
                    (o) => o.pageWidth(_playlistPageMaxWidth),
                  ),
                ),
              ),
              child: child,
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(40, 24, 40, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _pageHead(context, cli, view).tourAnchor('build'),
                  const PackagePublicationRecovery(),
                  if (cli.projectEditingLocked) ...[
                    const SizedBox(height: 12),
                    RmBanner(
                      kind: RmBannerKind.warn,
                      title: cli.projectEditingLockTitle,
                      body:
                          '${cli.projectEditingLockMessage} 播放列表拖拽、恢复、复制和写包暂时不可用。',
                    ),
                  ],
                  const SizedBox(height: 14),
                  if (catalog.failed)
                    Expanded(
                      child: SingleChildScrollView(
                        child: _catalogError(context, catalog, cli, view),
                      ),
                    )
                  else ...[
                    if ((view == PlaylistCatalogView.package
                            ? editingPlan
                            : poolPlan)
                        .crossRadioAssignments
                        .isNotEmpty) ...[
                      CrossRadioAssignmentNotice(
                        plan: view == PlaylistCatalogView.package
                            ? editingPlan
                            : poolPlan,
                        titleForSource: (source) =>
                            s.pool
                                .where(
                                  (t) =>
                                      PlaylistAssignment.keyForPath(t.source) ==
                                      PlaylistAssignment.keyForPath(source),
                                )
                                .firstOrNull
                                ?.title ??
                            source,
                      ),
                      const SizedBox(height: 12),
                    ],
                    _toolbar(context, s, catalog, view, editingPlan, cli),
                    const SizedBox(height: 14),
                    Expanded(
                      child: _board(
                        context,
                        s,
                        pool,
                        catalog,
                        baselineCatalog,
                        editingPlan,
                        editingPlan,
                        view,
                        cli,
                      ).tourAnchor('board'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    ).withFeatureTour(TourPage.playlist, enabled: !cli.busy && !catalog.failed);
  }

  Widget _pageHead(
    BuildContext context,
    StudioState cli,
    PlaylistCatalogView view,
  ) {
    final rm = context.rm;
    final description = view == PlaylistCatalogView.package
        ? '在“准备包”编辑下一次构建的排布，双击自建曲目进入编辑；在“游戏内”查看当前 RadioInfo。'
        : '查看当前游戏内 RadioInfo，只读确认 custom / builtin；切换到“准备包”编辑下一次构建的排布。';
    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '播放列表',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: RmText.pageH1(color: rm.fg),
        ),
        const SizedBox(height: 6),
        Tooltip(
          message: description,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: Text(
              description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: RmText.body(color: rm.fg3),
            ),
          ),
        ),
      ],
    );
    final actions = Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        OpenPackageFolderButton(path: cli.lastPackageDeployDir),
        RmButton(
          key: const ValueKey('playlist-save'),
          label: '保存播放列表',
          leading: const RmIcon('check', size: 12),
          onPressed:
              cli.busy ||
                  cli.projectEditingLocked ||
                  view != PlaylistCatalogView.package ||
                  (!ref.read(playlistPlanProvider.notifier).dirty &&
                      ref.read(playlistPlanProvider.notifier).hasUserPlan)
              ? null
              : _savePlaylist,
        ),
        RmButton(
          key: const ValueKey('playlist-build'),
          onPressed:
              cli.busy ||
                  cli.projectEditingLocked ||
                  view != PlaylistCatalogView.package
              ? null
              : () => unawaited(_preparePackageFromUi(context)),
          variant: RmButtonVariant.primary,
          leading: const RmIcon('music', size: 12),
          label: '构建准备包',
          tooltip: cli.projectEditingLocked
              ? cli.projectEditingLockMessage
              : null,
        ),
      ],
    );
    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth > 850) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(child: heading),
              const SizedBox(width: 16),
              actions,
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            heading,
            const SizedBox(height: 12),
            Align(alignment: Alignment.centerLeft, child: actions),
          ],
        );
      },
    );
  }

  Widget _toolbar(
    BuildContext context,
    PlaylistState s,
    PlaylistCatalog catalog,
    PlaylistCatalogView view,
    PlaylistPlan plan,
    StudioState cli,
  ) {
    final rm = context.rm;
    final editingLocked = cli.projectEditingLocked;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: rm.panel,
        border: Border.all(color: rm.border),
        borderRadius: BorderRadius.circular(RmTokens.rLg),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final viewSwitch = PlaylistViewSwitch(
            value: view,
            onChanged: (value) {
              ref.read(playlistCatalogViewProvider.notifier).state = value;
            },
          );
          final segmented = RmSegmented<PlaylistMode>(
            value: s.mode,
            onChanged: ref.read(playlistProvider.notifier).setMode,
            options: const [
              RmSegmentedOption(
                value: PlaylistMode.freeroam,
                label: 'FreeRoam · 漫游',
              ),
              RmSegmentedOption(value: PlaylistMode.event, label: 'Event · 比赛'),
            ],
          );
          final baseChip = Tooltip(
            message: catalog.badgeTooltip,
            child: RmChip(
              label: catalog.badgeLabel,
              variant: switch (catalog.origin) {
                PlaylistCatalogOrigin.package => RmChipVariant.accent,
                PlaylistCatalogOrigin.failed => RmChipVariant.warn,
                PlaylistCatalogOrigin.game => RmChipVariant.defaultC,
              },
              showDot: true,
            ),
          );
          final search = SizedBox(
            height: 38,
            width: (constraints.maxWidth - 260).clamp(
              0.0,
              constraints.maxWidth,
            ),
            child: PlaylistSearchField(
              controller: _search,
              fieldKey: const ValueKey('playlist-search'),
              clearKey: const ValueKey('playlist-clear-search'),
              onChanged: ref.read(playlistProvider.notifier).setSearch,
            ),
          ).tourAnchor('search');
          final Widget? copyAction = view == PlaylistCatalogView.package
              ? RmButton(
                  onPressed: editingLocked
                      ? null
                      : () => unawaited(_copyGameLayoutToPackage(context)),
                  leading: const RmIcon('copy', size: 12),
                  label: '复制游戏内排布',
                  tooltip: editingLocked ? cli.projectEditingLockMessage : null,
                )
              : null;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PlaylistToolbarRow(
                leading: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    viewSwitch,
                    baseChip,
                    ?copyAction,
                    const SplitPlaylistSetting(),
                  ],
                ),
                trailing: Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (view == PlaylistCatalogView.package)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          RmButton(
                            key: const ValueKey('playlist-undo'),
                            label: '撤销',
                            size: RmButtonSize.sm,
                            leading: const RmIcon('undo', size: 12),
                            onPressed:
                                editingLocked ||
                                    cli.busy ||
                                    !ref
                                        .read(playlistPlanProvider.notifier)
                                        .canUndo
                                ? null
                                : () => _restorePlaylistHistory(redo: false),
                          ),
                          const SizedBox(width: 6),
                          RmButton(
                            key: const ValueKey('playlist-redo'),
                            label: '重做',
                            size: RmButtonSize.sm,
                            leading: const RmIcon('redo', size: 12),
                            onPressed:
                                editingLocked ||
                                    cli.busy ||
                                    !ref
                                        .read(playlistPlanProvider.notifier)
                                        .canRedo
                                ? null
                                : () => _restorePlaylistHistory(redo: true),
                          ),
                        ],
                      ),
                    RmChip(
                      key: const ValueKey('playlist-save-status'),
                      showDot: true,
                      label: view != PlaylistCatalogView.package
                          ? '只读查看'
                          : '${plan.assignments.values.where((a) => a.playlistType == (s.mode == PlaylistMode.event ? 'Event' : 'FreeRoam')).length} 首分配 · ${ref.watch(playlistPlanProvider.notifier).dirty ? '未保存' : '已保存'}',
                      variant: view != PlaylistCatalogView.package
                          ? RmChipVariant.muted
                          : ref.read(playlistPlanProvider.notifier).dirty
                          ? RmChipVariant.warn
                          : RmChipVariant.accent,
                    ),
                  ],
                ),
              ).tourAnchor('view'),
              if (s.splitPlaylistTypes) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    segmented,
                    Text(
                      '分场景编辑 · 实验功能；分别安排漫游和比赛，关闭后保留两套排布。',
                      style: RmText.sans(11.5, color: rm.fg3),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 10),
              PlaylistSearchRow(search: search),
              PlaylistLayoutControls(
                topSpacing: 2,
                availableRadioWidth: LayoutOptions.radioWidthFor(
                  constraints.maxWidth + 30,
                  withPool: view == PlaylistCatalogView.package,
                ),
              ).tourAnchor('layout'),
            ],
          );
        },
      ),
    );
  }

  Widget _catalogError(
    BuildContext context,
    PlaylistCatalog catalog,
    StudioState cli,
    PlaylistCatalogView view,
  ) {
    final rm = context.rm;
    return RmPanel(
      title: '播放列表读取失败',
      subtitle: '没有可用的真实 RadioInfo 文件',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            catalog.error ?? '没有找到可读取的 RadioInfo_*.xml。',
            style: RmText.body(color: rm.fg2),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              RmButton(
                onPressed: cli.busy
                    ? null
                    : ref.read(studioProvider.notifier).refreshStatus,
                leading: const RmIcon('search', size: 12),
                label: '刷新状态',
              ),
              if (view == PlaylistCatalogView.package)
                RmButton(
                  onPressed: cli.busy || cli.projectEditingLocked
                      ? null
                      : () => unawaited(_preparePackageFromUi(context)),
                  variant: RmButtonVariant.primary,
                  leading: const RmIcon('music', size: 12),
                  label: '构建准备包',
                  tooltip: cli.projectEditingLocked
                      ? cli.projectEditingLockMessage
                      : null,
                ),
            ],
          ),
        ],
      ),
    );
  }

  PlaylistPlan _poolAssignmentPlan(
    PlaylistCatalog catalog,
    PlaylistPlan plan,
    List<PoolTrack> pool,
  ) {
    if (ref.read(playlistPlanProvider.notifier).hasUserPlan ||
        plan.hasDraft ||
        catalog.failed) {
      return plan;
    }
    final inputs = (catalog, plan, pool);
    if (_poolPlanInputs != inputs) {
      _poolPlanInputs = inputs;
      final detected = playlistPlanFromCatalog(
        catalog,
        pool,
        includeBuiltinTargets: false,
      );
      _cachedPoolPlan = detected.assignments.isEmpty ? plan : detected;
    }
    return _cachedPoolPlan!;
  }

  Widget _board(
    BuildContext context,
    PlaylistState s,
    List<PoolTrack> pool,
    PlaylistCatalog catalog,
    PlaylistCatalog? baselineCatalog,
    PlaylistPlan plan,
    PlaylistPlan poolPlan,
    PlaylistCatalogView view,
    StudioState cli,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = LayoutOptions.gap;
        final showPool = view == PlaylistCatalogView.package;
        final poolWidth = LayoutOptions.poolWidthFor(constraints.maxWidth);
        final available = LayoutOptions.radioWidthFor(
          constraints.maxWidth,
          withPool: showPool,
        );
        if (showPool &&
            constraints.maxWidth < LayoutOptions.minColumnWidth + gap + 160) {
          // If one radio and the pool cannot fit side by side, stack them rather
          // than violate either column's minimum width or add horizontal overflow.
          return SingleChildScrollView(
            controller: _boardScroll,
            primary: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _radioBoard(
                  context,
                  s,
                  catalog,
                  baselineCatalog,
                  plan,
                  view,
                  cli,
                  viewportHeight: constraints.maxHeight,
                ),
                const SizedBox(height: gap),
                SizedBox(
                  key: const ValueKey('playlist-pool-side-panel'),
                  height: 480,
                  child: _poolColumn(context, s, pool, catalog, poolPlan, cli),
                ),
              ],
            ),
          );
        }
        final canvasWidth = available;
        final board = SizedBox(
          width: canvasWidth,
          height: constraints.maxHeight,
          child: _radioBoard(
            context,
            s,
            catalog,
            baselineCatalog,
            plan,
            view,
            cli,
            viewportHeight: constraints.maxHeight,
          ),
        );
        if (!showPool) return board;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: board),
            const SizedBox(width: gap),
            SizedBox(
              key: const ValueKey('playlist-pool-side-panel'),
              width: poolWidth,
              child: _poolColumn(context, s, pool, catalog, poolPlan, cli),
            ),
          ],
        );
      },
    );
  }

  Widget _radioBoard(
    BuildContext context,
    PlaylistState s,
    PlaylistCatalog catalog,
    PlaylistCatalog? baselineCatalog,
    PlaylistPlan plan,
    PlaylistCatalogView view,
    StudioState cli, {
    required double viewportHeight,
  }) {
    // Station contents depend on songs/filter/plan, not on slider position.
    final inputs = (
      s,
      catalog,
      baselineCatalog,
      plan,
      view,
      cli.projectEditingLocked,
      _selecting,
      ref.watch(editorOptionsProvider).expansionEnabled,
      ref.read(playlistPlanProvider.notifier).hasUserPlan,
      context.rm,
    );
    if (_radioWidgetInputs != inputs) {
      _radioWidgetInputs = inputs;
      _cachedRadioWidgets = [
        for (final radio in catalog.radios)
          _radioColumn(
            context,
            s,
            radio,
            catalog,
            baselineCatalog,
            plan,
            view,
            cli,
          ),
      ];
    }
    final columns = _cachedRadioWidgets;
    return Consumer(
      builder: (context, layoutRef, _) {
        final options = layoutRef.watch(layoutOptionsProvider);
        return LayoutBuilder(
          builder: (context, constraints) {
            const gap = 12.0;
            final count = options.columnsFor(constraints.maxWidth);
            final height = options.heightFor(
              viewportHeight,
              catalog.radios.length,
              count,
            );
            final width = (constraints.maxWidth - gap * (count - 1)) / count;
            if (constraints.hasBoundedHeight) {
              _rowExtent = height + gap;
              return NotificationListener<ScrollNotification>(
                onNotification: _snapOnScroll,
                child: GridView.builder(
                  key: const ValueKey('playlist-radio-board'),
                  controller: _boardScroll,
                  primary: false,
                  padding: EdgeInsets.zero,
                  scrollCacheExtent: const ScrollCacheExtent.pixels(40),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: count,
                    mainAxisSpacing: gap,
                    crossAxisSpacing: gap,
                    mainAxisExtent: height,
                  ),
                  itemCount: columns.length,
                  itemBuilder: (context, i) => _KeepStationState(
                    key: ValueKey('station-${catalog.radios[i].code}'),
                    child: SizedBox(
                      key: ValueKey(
                        'playlist-radio-column-${catalog.radios[i].code}',
                      ),
                      width: width,
                      height: height,
                      child: columns[i],
                    ),
                  ),
                ),
              );
            }
            return Wrap(
              key: const ValueKey('playlist-radio-board'),
              spacing: gap,
              runSpacing: gap,
              children: [
                for (var i = 0; i < columns.length; i++)
                  SizedBox(
                    key: ValueKey(
                      'playlist-radio-column-${catalog.radios[i].code}',
                    ),
                    width: width,
                    height: height,
                    child: columns[i],
                  ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _radioColumn(
    BuildContext context,
    PlaylistState s,
    RadioStation r,
    PlaylistCatalog catalog,
    PlaylistCatalog? baselineCatalog,
    PlaylistPlan plan,
    PlaylistCatalogView view,
    StudioState cli,
  ) {
    final playlistType = _displayPlaylistType(s, r, catalog, plan);
    final readOnly = view == PlaylistCatalogView.game;
    final editingLocked = cli.projectEditingLocked;
    final draftBuiltin =
        !readOnly && plan.hasBuiltinOverride(r.code, playlistType);
    final draftCustom =
        !readOnly &&
        !draftBuiltin &&
        (plan.hasAssignmentsForRadio(r.code, playlistType) ||
            (ref.read(playlistPlanProvider.notifier).hasUserPlan &&
                catalog.modeOfList(r.code, playlistType) ==
                    StationMode.custom));
    final catalogCustom =
        catalog.modeOfList(r.code, playlistType) == StationMode.custom;
    final isCustom = readOnly
        ? catalogCustom
        : draftCustom || (!draftBuiltin && catalogCustom);
    final customTracks = s.tracksOfRadio(r.code, playlistType, plan);
    final assignedTracks = customTracks.where((t) => _matches(s, t)).toList();
    final originalCatalog = draftBuiltin
        ? (baselineCatalog ?? catalog)
        : catalog;
    final originalTrackRefs = originalCatalog.tracksOfRadio(
      r.code,
      playlistType,
    );
    final originalTracks = originalTrackRefs
        .where((t) => _matchesRef(s, t))
        .toList();
    final originalTrackCount = originalTrackRefs.length;
    final count =
        !readOnly && isCustom && (customTracks.isNotEmpty || draftCustom)
        ? customTracks.length
        : originalTrackCount;
    final expansion = ref.watch(editorOptionsProvider).expansionEnabled;
    final originalCapacity =
        baselineCatalog?.tracksOfRadio(r.code, playlistType).length ?? 0;
    final replaceableCapacity = expansion
        ? 4096
        : (originalCapacity > 0 ? originalCapacity : r.slot);
    final capacity = readOnly
        ? originalTrackCount
        : isCustom
        ? replaceableCapacity
        : originalTrackCount;
    final sharedBankCount = readOnly
        ? {
            for (final type in const ['FreeRoam', 'Event'])
              for (final track in catalog.tracksOfRadio(r.code, type))
                track.soundName ?? track.id,
          }.length
        : plan.sourcesForRadio(r.code).length;

    final bySource = {
      for (final t in s.pool) PlaylistAssignment.keyForPath(t.source): t,
    };
    PoolTrack? localTrack(TrackRef track) {
      final source = originalCatalog.sourceForTrack(track);
      return source == null
          ? null
          : bySource[PlaylistAssignment.keyForPath(source)];
    }

    Widget buildColumn() {
      final otherType = playlistType == 'Event' ? 'FreeRoam' : 'Event';
      final otherHasCustom =
          !plan.hasBuiltinOverride(r.code, otherType) &&
          plan.hasAssignmentsForRadio(r.code, otherType);
      final showSceneAction =
          s.splitPlaylistTypes && !readOnly && (isCustom || otherHasCustom);
      final editableCustom =
          isCustom && !readOnly && (customTracks.isNotEmpty || draftCustom);
      Widget item(BuildContext context, int index) {
        if (editableCustom) {
          final t = assignedTracks[index];
          return DragTarget<_PlaylistDragData>(
            onWillAcceptWithDetails: (details) =>
                details.data.originRadioCode == r.code &&
                details.data.originPlaylistType == playlistType,
            onAcceptWithDetails: (details) => ref
                .read(playlistProvider.notifier)
                .reorderMany(
                  details.data.tracks.map((t) => t.source).toList(),
                  t.source,
                  r.code,
                  playlistType,
                ),
            builder: (context, candidates, rejected) => Container(
              decoration: BoxDecoration(
                border: candidates.isEmpty
                    ? null
                    : Border(
                        top: BorderSide(
                          color: context.rm.accent.base,
                          width: 3,
                        ),
                      ),
              ),
              child: _draggableTrack(
                t,
                originRadioCode: r.code,
                originPlaylistType: playlistType,
                locked: editingLocked,
                order: customTracks.indexOf(t) + 1,
                editorSequence: customTracks,
                selectionMode: _selecting,
                onSelect: (control, shift) => _selectPoolTrack(
                  t,
                  assignedTracks,
                  control: control,
                  range: shift,
                  scope: '${r.code}|$playlistType',
                ),
              ),
            ),
          );
        }
        final t = originalTracks[index];
        final local = isCustom ? localTrack(t) : null;
        return TrackCard(
          notConfiguredProgress: local != null && !local.readyForBuild
              ? '${local.confirmed}/4'
              : null,
          order: originalTrackRefs.indexOf(t) + 1,
          title: t.title,
          artist: t.artist,
          durationSec: t.durationSec,
          locked: !isCustom || readOnly,
          custom: isCustom ? (t.modded || readOnly) : t.modded,
          onOpenEditor: editingLocked || readOnly || !isCustom
              ? null
              : _catalogEditorAction(t, catalog, s.pool, originalTracks),
        );
      }

      return PlaylistColumn.radioBuilder(
        radio: r,
        isCustom: isCustom,
        count: count,
        expanded: readOnly && catalog.hasExpandedBank(r.code, baselineCatalog),
        pendingCount: readOnly || !isCustom
            ? 0
            : editableCustom
            ? customTracks.where((t) => !t.readyForBuild).length
            : originalTrackRefs
                  .map(localTrack)
                  .whereType<PoolTrack>()
                  .where((t) => !t.readyForBuild)
                  .length,
        capacity: capacity,
        originalCount: baselineCatalog == null
            ? r.slot
            : baselineCatalog.tracksOfRadio(r.code, playlistType).length,
        onRestoreBuiltin:
            !s.splitPlaylistTypes && !readOnly && !editingLocked && isCustom
            ? () => unawaited(_restoreBuiltin(r, playlistType, customTracks))
            : null,
        headerActionLabel: showSceneAction
            ? '使用${_playlistLabel(playlistType == 'Event' ? 'FreeRoam' : 'Event')}歌单'
            : null,
        headerActionTooltip: '将另一场景的歌曲与顺序套用到当前场景，来源歌单保留。两场景不支持一边原版、一边自建。',
        onHeaderAction: showSceneAction && !editingLocked && otherHasCustom
            ? () => _useOtherScenePlaylist(r, playlistType)
            : null,
        itemCount: editableCustom
            ? assignedTracks.length
            : originalTracks.length,
        itemBuilder: item,
        filterControls: showSceneAction
            ? Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Tooltip(
                      message: '漫游和比赛共用一份曲库，相同歌曲只占一个位置。不同歌曲合计超过原版容量时，需要开启电台扩容。',
                      child: Text(
                        '共用曲库 $sharedBankCount 首',
                        style: RmText.mono(10.5, color: context.rm.fg3),
                      ),
                    ),
                  ],
                ),
              )
            : null,
      );
    }

    final column = buildColumn();
    if (readOnly || editingLocked) return column;

    return DragTarget<_PlaylistDragData>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (details) {
        _assign(
          details.data,
          r,
          playlistType,
          isCustom,
          replaceableCapacity,
          originalTrackRefs,
        );
      },
      builder: (context, candidate, rejected) {
        return _DragTargetHoverFrame(
          highlighted: candidate.isNotEmpty,
          color: isCustom ? context.rm.accent.base : context.rm.warn,
          child: column,
        );
      },
    );
  }

  String _displayPlaylistType(
    PlaylistState s,
    RadioStation radio,
    PlaylistCatalog catalog,
    PlaylistPlan plan,
  ) {
    if (s.splitPlaylistTypes) {
      return s.mode == PlaylistMode.event ? 'Event' : 'FreeRoam';
    }
    final freeAssignments = plan.assignmentsForRadio(radio.code, 'FreeRoam');
    final eventAssignments = plan.assignmentsForRadio(radio.code, 'Event');
    if (freeAssignments.isEmpty && eventAssignments.isNotEmpty) {
      return 'Event';
    }
    final freeMode = catalog.modeOfList(radio.code, 'FreeRoam');
    final eventMode = catalog.modeOfList(radio.code, 'Event');
    if (freeMode != StationMode.custom && eventMode == StationMode.custom) {
      return 'Event';
    }
    return 'FreeRoam';
  }

  Widget _poolColumn(
    BuildContext context,
    PlaylistState s,
    List<PoolTrack> pool,
    PlaylistCatalog catalog,
    PlaylistPlan plan,
    StudioState cli,
  ) {
    final inputs = (
      s,
      pool,
      catalog,
      plan,
      cli.projectEditingLocked,
      _selecting,
      _browse,
      context.rm,
    );
    if (_poolWidgetInputs != inputs) {
      _poolWidgetInputs = inputs;
      _cachedPoolWidget = ValueListenableBuilder<SongSelection>(
        valueListenable: _selectionSignal,
        builder: (context, selection, _) =>
            _poolColumnContent(context, s, pool, catalog, plan, cli),
      );
    }
    return _cachedPoolWidget!;
  }

  Widget _poolColumnContent(
    BuildContext context,
    PlaylistState s,
    List<PoolTrack> pool,
    PlaylistCatalog catalog,
    PlaylistPlan plan,
    StudioState cli,
  ) {
    final assignmentLabelsByTrackKey = _assignmentLabelsByTrackKey(plan, s);
    pool = browseSongs(
      pool,
      _browse,
      duplicates: duplicateSongs(s.pool),
      plan: plan,
      splitTypes: s.splitPlaylistTypes,
    );
    final column = PlaylistColumn.poolBuilder(
      count: pool.length,
      itemCount: pool.length,
      filterControls: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 2),
          SongBrowseControls(
            value: _browse,
            compact: true,
            showSearch: false,
            showScene: s.splitPlaylistTypes,
            onChanged: (v) => setState(() {
              if (v.scene != _browse.scene) _selection = SongSelection();
              _browse = v;
            }),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
            child: Row(
              children: [
                Expanded(
                  child: Tooltip(
                    message: 'Ctrl 多选 · Shift 连选 · Esc 退出 · 双击编辑',
                    child: Text(
                      'Ctrl 多选 · Shift 连选',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: RmText.sans(10, color: context.rm.fg3),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints.tightFor(
                    width: songBrowseActionWidth,
                  ),
                  child: RmButton(
                    key: const ValueKey('playlist-multiselect-toggle'),
                    size: RmButtonSize.md,
                    label: _selecting && _selectionScope == 'pool'
                        ? '退出多选'
                        : '多选',
                    onPressed: cli.projectEditingLocked
                        ? null
                        : () => _toggleSelection('pool'),
                  ),
                ),
              ],
            ),
          ),
          if (_selecting)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
              child: PoolSelectionActions(
                key: const ValueKey('playlist-selection-actions'),
                count: _selection.ids.length,
                label: _selectionScope == 'pool'
                    ? '已选 ${_selection.ids.length}'
                    : '电台已选 ${_selection.ids.length}',
                onSelectAll: () => setState(() {
                  _selectionScope = 'pool';
                  _selection = SongSelection(
                    ids: pool.map((t) => t.id).toSet(),
                  );
                }),
                onClear: () => setState(() => _selection = SongSelection()),
                actions: [
                  RmButton(
                    key: const ValueKey('playlist-batch-assign'),
                    size: RmButtonSize.sm,
                    label: '分配至电台',
                    horizontalPadding: 8,
                    variant: RmButtonVariant.primary,
                    onPressed:
                        _selectionScope != 'pool' ||
                            _selection.ids.isEmpty ||
                            cli.projectEditingLocked
                        ? null
                        : () => _assignSelected(pool),
                  ),
                ],
              ),
            ),
        ],
      ),
      itemBuilder: (context, index) {
        final track = pool[index];
        final trackKey = PlaylistAssignment.keyForPath(track.source);
        return _draggableTrack(
          track,
          assignmentLabels: assignmentLabelsByTrackKey[trackKey] ?? const [],
          locked: cli.projectEditingLocked,
          editorSequence: pool,
          selected: _selection.ids.contains(track.id),
          selectionMode: _selecting,
          onSelect: (control, shift) =>
              _selectPoolTrack(track, pool, control: control, range: shift),
        );
      },
    );
    if (cli.projectEditingLocked) return column;

    return DragTarget<_PlaylistDragData>(
      onWillAcceptWithDetails: (_) {
        return true;
      },
      onAcceptWithDetails: (details) {
        unawaited(_handlePoolDrop(context, s, catalog, plan, details.data));
      },
      builder: (context, candidate, rejected) {
        return _DragTargetHoverFrame(
          highlighted: candidate.isNotEmpty,
          color: context.rm.accent.base,
          child: column,
        );
      },
    );
  }

  Map<String, List<String>> _assignmentLabelsByTrackKey(
    PlaylistPlan plan,
    PlaylistState s,
  ) {
    final labelsByTrackKey = <String, List<String>>{};
    final seenByTrackKey = <String, Set<String>>{};
    final assignments =
        plan.assignments.values
            .where((assignment) => assignment.isAssigned)
            .toList()
          ..sort(_compareAssignmentsForDisplay);

    for (final assignment in assignments) {
      final label = s.splitPlaylistTypes
          ? assignment.listLabel
          : '${assignment.radioCode} · ${assignment.slot}';
      final dedupeKey = s.splitPlaylistTypes
          ? label
          : '${assignment.radioCode}|${assignment.slot}';
      for (final trackKey in _assignmentTrackKeys(assignment)) {
        final seen = seenByTrackKey.putIfAbsent(trackKey, () => <String>{});
        if (!seen.add(dedupeKey)) continue;
        labelsByTrackKey.putIfAbsent(trackKey, () => <String>[]).add(label);
      }
    }

    return labelsByTrackKey;
  }

  Set<String> _assignmentTrackKeys(PlaylistAssignment assignment) {
    final keys = <String>{};
    if (assignment.trackKey.isNotEmpty) keys.add(assignment.trackKey);
    if (assignment.source.trim().isNotEmpty) {
      keys.add(PlaylistAssignment.keyForPath(assignment.source));
    }
    return keys;
  }

  int _compareAssignmentsForDisplay(
    PlaylistAssignment a,
    PlaylistAssignment b,
  ) {
    final byRadio = a.radioCode.compareTo(b.radioCode);
    if (byRadio != 0) return byRadio;
    final byType = _playlistTypeSortKey(
      a.playlistType,
    ).compareTo(_playlistTypeSortKey(b.playlistType));
    if (byType != 0) return byType;
    final bySlot = a.slot.compareTo(b.slot);
    if (bySlot != 0) return bySlot;
    return a.source.toLowerCase().compareTo(b.source.toLowerCase());
  }

  int _playlistTypeSortKey(String type) {
    return PlaylistAssignment.normalizePlaylistType(type) == 'FreeRoam' ? 0 : 1;
  }

  PoolTrack? _mappedEditorSong(
    TrackRef track,
    PlaylistCatalog catalog,
    List<PoolTrack> pool,
  ) {
    final source = catalog.sourceBySoundName[track.soundName];
    if (source == null || source.isEmpty) return null;
    final key = PlaylistAssignment.keyForPath(source);
    for (final song in pool) {
      if (PlaylistAssignment.keyForPath(song.source) == key) return song;
    }
    return null;
  }

  VoidCallback? _catalogEditorAction(
    TrackRef track,
    PlaylistCatalog catalog,
    List<PoolTrack> pool,
    List<TrackRef> ordered,
  ) {
    final song = _mappedEditorSong(track, catalog, pool);
    if (song == null) return null;
    return () => _openTrackEditor(
      song,
      sequence: [
        for (final item in ordered)
          if (_mappedEditorSong(item, catalog, pool)
              case final PoolTrack mapped)
            mapped,
      ],
    );
  }

  void _openTrackEditor(PoolTrack song, {List<PoolTrack>? sequence}) {
    if (ref.read(studioProvider).projectEditingLocked) return;
    ref
        .read(editorSongQueueProvider.notifier)
        .begin(
          ref.read(studioProvider).projectDir,
          (sequence ?? ref.read(playlistProvider).pool).map((t) => t.id),
        );
    unawaited(context.push<void>(RmRoutes.editor(song.id, fromPlaylist: true)));
  }

  Widget _draggableTrack(
    PoolTrack t, {
    String? originRadioCode,
    String? originPlaylistType,
    List<String> assignmentLabels = const [],
    bool locked = false,
    int? order,
    List<PoolTrack>? editorSequence,
    void Function(bool control, bool shift)? onSelect,
    bool selected = false,
    bool selectionMode = false,
  }) {
    if (locked) {
      return TrackCard.fromPoolTrack(
        t,
        order: order,
        assignmentLabels: assignmentLabels,
        locked: true,
      );
    }
    return ValueListenableBuilder<SongSelection>(
      valueListenable: _selectionSignal,
      builder: (context, selection, _) {
        final scope = originRadioCode == null
            ? 'pool'
            : '$originRadioCode|$originPlaylistType';
        final isSelected =
            _selectionScope == scope && selection.ids.contains(t.id);
        final ordered = editorSequence ?? ref.read(playlistProvider).pool;
        final orderedIds = ordered.map((t) => t.id).toSet();
        final tracks = !isSelected
            ? [t]
            : [
                for (final track in ordered)
                  if (selection.ids.contains(track.id)) track,
                for (final track in ref.read(playlistProvider).pool)
                  if (selection.ids.contains(track.id) &&
                      !orderedIds.contains(track.id))
                    track,
              ];
        return PlaylistDraggable<_PlaylistDragData>(
          maxSimultaneousDrags: 1,
          data: _PlaylistDragData(
            tracks: tracks,
            originRadioCode: originRadioCode,
            originPlaylistType: originPlaylistType,
          ),
          feedback: PlaylistDragPreview(tracks: tracks),
          childWhenDragging: Opacity(
            opacity: 0.35,
            child: TrackCard.fromPoolTrack(
              t,
              order: order,
              assignmentLabels: assignmentLabels,
            ),
          ),
          child: TrackCard.fromPoolTrack(
            t,
            onOpenEditor: () => _openTrackEditor(t, sequence: editorSequence),
            onSelect: onSelect,
            selected: isSelected,
            selectionMode: selectionMode,
            order: order,
            assignmentLabels: assignmentLabels,
          ),
        );
      },
    );
  }
}

class _DragTargetHoverFrame extends StatelessWidget {
  const _DragTargetHoverFrame({
    required this.highlighted,
    required this.color,
    required this.child,
  });

  final bool highlighted;
  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        RepaintBoundary(child: child),
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: highlighted ? 1 : 0,
              duration: const Duration(milliseconds: 90),
              child: Container(
                decoration: BoxDecoration(
                  color: color.withAlpha(16),
                  border: Border.all(color: color, width: 1.5),
                  borderRadius: BorderRadius.circular(RmTokens.rLg),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

@immutable
class _PlaylistDragData {
  const _PlaylistDragData({
    required this.tracks,
    this.originRadioCode,
    this.originPlaylistType,
  });

  final List<PoolTrack> tracks;
  PoolTrack get track => tracks.first;
  final String? originRadioCode;
  final String? originPlaylistType;
}

/// Keep each station's inner scroll offset once it has first entered the viewport.
class _KeepStationState extends StatefulWidget {
  const _KeepStationState({super.key, required this.child});
  final Widget child;
  @override
  State<_KeepStationState> createState() => _KeepStationStateState();
}

class _KeepStationStateState extends State<_KeepStationState>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
