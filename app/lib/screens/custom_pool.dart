import '../core/demo_song.dart';
import '../widgets/feature_tour.dart';
import '../widgets/external_audio_drop_target.dart';
import '../widgets/audio_import_feedback.dart';
import '../widgets/quick_assign_dialog.dart';
import '../widgets/timing_export_dialog.dart';
import '../state/library_columns.dart';
import 'package:flutter/gestures.dart';
import '../widgets/timing_import_dialog.dart';
import '../core/seam_audition_player.dart';
import '../state/audition_preferences.dart';
import '../widgets/audition_settings_button.dart';
import '../state/editor_navigation.dart';
import '../state/seamless_batch_state.dart';
import '../widgets/seamless_batch_progress.dart';
import '../widgets/contained_scroll.dart';
import '../widgets/smooth_scroll_to_top.dart';
import 'dart:io';
import 'dart:async';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../state/layout_options.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit/media_kit.dart';

import '../core/playlist_plan.dart';
import 'playlist/playlist_state.dart';
import '../core/song_browse.dart';
import '../widgets/song_browse_controls.dart';
import '../core/studio_audio_players.dart';
import '../domain/radio_library.dart';
import '../state/studio_state.dart';
import '../state/editor_options.dart';
import '../state/waveform_batch_state.dart';
import '../widgets/waveform_batch_progress.dart';
import '../state/custom_pool_tracks.dart';
import '../state/playlist_plan_state.dart';
import '../state/router.dart';
import '../state/siren_import_queue_state.dart';
import '../state/track_timing_state.dart';
import '../theme/app_theme.dart';
import '../theme/text_styles.dart';
import '../theme/tokens.dart';
import '../widgets/progress_bars.dart';
import '../widgets/pending_gate.dart';
import '../widgets/rm_banner.dart';
import '../widgets/rm_button.dart';
import '../widgets/rm_chip.dart';
import '../widgets/rm_icon.dart';
import '../widgets/rm_panel.dart';
import '../widgets/rm_segmented.dart';
import '../widgets/stat_card.dart';
import '../state/game_playlist_membership.dart';

enum _PoolFilter { all, unconfigured, configured }

final _poolOffsets = <String, double>{};
final _poolFilters = <String, _PoolFilter>{};
final _poolBrowse = <String, SongBrowse>{};

class CustomPoolScreen extends ConsumerStatefulWidget {
  const CustomPoolScreen({super.key});

  @override
  ConsumerState<CustomPoolScreen> createState() => _CustomPoolScreenState();
}

class _CustomPoolScreenState extends ConsumerState<CustomPoolScreen> {
  _PoolFilter _filter = _PoolFilter.all;
  bool _msrOnly = false;
  late final ScrollController _scroll;
  Player? _preview;
  Timer? _previewTimer;
  int _previewGeneration = 0;
  String? _previewKey;
  SongBrowse _browse = const SongBrowse();

  @override
  void initState() {
    super.initState();
    final project = ref.read(studioProvider).projectDir;
    _filter = _poolFilters[project] ?? _PoolFilter.all;
    _browse = _poolBrowse[project] ?? const SongBrowse();
    _scroll = ScrollController(initialScrollOffset: _poolOffsets[project] ?? 0);
    _scroll.addListener(() {
      _poolOffsets[project] = _scroll.offset;
      _poolFilters[project] = _filter;
    });
  }

  @override
  void dispose() {
    _previewGeneration++;
    unawaited(_seamAudition?.cancel());
    _previewTimer?.cancel();
    final player = _preview;
    if (player != null) unawaited(player.pause());
    _scroll.dispose();
    super.dispose();
  }

  SeamAuditionPlayer? _seamAudition;

  Future<void> _stopPreview({int? request}) async {
    final generation = request ?? ++_previewGeneration;
    final audition = _seamAudition;
    await audition?.cancel();
    if (generation != _previewGeneration || !mounted) return;
    _seamAudition = null;
    _previewTimer?.cancel();
    if (_preview != null) await _preview!.pause();
    if (mounted && generation == _previewGeneration) {
      setState(() => _previewKey = null);
    }
  }

  Future<void> _quickPreview(PoolTrack track, String group) async {
    final key = '${track.id}:$group';
    final request = ++_previewGeneration;
    if (_previewKey == key) {
      await _stopPreview(request: request);
      return;
    }
    await _stopPreview(request: request);
    if (request != _previewGeneration || !mounted) return;
    final config = ref
        .read(trackTimingProvider.notifier)
        .configForPath(track.source);
    if (config == null) return;
    final markers = config.markersSec;
    final loop = group == 'tl' || group == 'pl';
    final prefix = group == 'pl' ? 'PostRaceLoop' : 'TrackLoop';
    final start = loop
        ? markers['${prefix}Start']
        : markers[group == 'td' ? 'TrackDrop' : 'PostDrop'];
    final end = loop ? markers['${prefix}End'] : null;
    if (start == null || start < 0 || (loop && (end == null || end <= start))) {
      return;
    }
    final generation = request;
    final player = _preview ??= StudioAudioPlayers.pool;
    try {
      // Load paused before seeking so point previews never start at zero.
      if (StudioAudioPlayers.poolSource != track.source) {
        await player.open(Media(track.source), play: false);
        if (player.state.duration == Duration.zero) {
          await player.stream.duration
              .firstWhere((duration) => duration > Duration.zero)
              .timeout(const Duration(seconds: 10));
        }
        if (generation != _previewGeneration || !mounted) return;
        StudioAudioPlayers.poolSource = track.source;
      }
      if (generation != _previewGeneration || !mounted) return;
      final diagnosticPreview =
          Platform.environment['FH_RADIO_STUDIO_PREVIEW_DIAGNOSTICS'] == '1';
      await player.setVolume(
        diagnosticPreview ? 0 : ref.read(auditionPreferencesProvider).volume,
      );
      if (loop) {
        late final SeamAuditionPlayer audition;
        audition = SeamAuditionPlayer(
          player: player,
          start: start,
          end: end!,
          options: ref.read(auditionPreferencesProvider),
          muted: diagnosticPreview,
          isCurrent: () =>
              mounted &&
              generation == _previewGeneration &&
              identical(_seamAudition, audition),
          onDone: () {
            if (mounted) setState(() => _previewKey = null);
          },
          onError: (error) {
            if (mounted) {
              setState(() => _previewKey = null);
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text('循环试听失败：$error')));
            }
          },
        );
        _seamAudition = audition;
        setState(() => _previewKey = key);
        await audition.start();
        return;
      }
      final previewSeconds = ref
          .read(auditionPreferencesProvider)
          .pointDuration(group == 'pd');
      final pointEnd = math.min(
        start + previewSeconds,
        player.state.duration.inMicroseconds / 1000000,
      );
      final native = player.platform;
      if (native is NativePlayer) {
        await (native as dynamic).setProperty(
          'end',
          pointEnd.toStringAsFixed(6),
        );
        await (native as dynamic).setProperty('ab-loop-a', 'no');
        await (native as dynamic).setProperty('ab-loop-b', 'no');
        if (loop) {
          await (native as dynamic).setProperty(
            'ab-loop-a',
            start.toStringAsFixed(6),
          );
          await (native as dynamic).setProperty(
            'ab-loop-b',
            end!.toStringAsFixed(6),
          );
        }
        final position = loop ? math.max(start, end! - 3) : start;
        await (native as dynamic).command([
          'seek',
          position.toStringAsFixed(6),
          'absolute+exact',
        ]);
        native.state = native.state.copyWith(completed: false);
      } else {
        await player.seek(
          Duration(
            microseconds: ((loop ? math.max(start, end! - 3) : start) * 1000000)
                .round(),
          ),
        );
      }
      if (generation != _previewGeneration || !mounted) return;
      setState(() => _previewKey = key);
      await player.play();
      _previewTimer = Timer(
        Duration(
          microseconds: ((pointEnd - start).clamp(0, previewSeconds) * 1000000)
              .round(),
        ),
        () => unawaited(_stopPreview()),
      );
      if (diagnosticPreview) {
        await Future<void>.delayed(const Duration(milliseconds: 600));
        if (generation != _previewGeneration || !mounted) return;
        final actual = native is NativePlayer
            ? await (native as dynamic).getProperty('time-pos')
            : '${player.state.position.inMicroseconds / 1000000}';
        stderr.writeln(
          'QUICK_PREVIEW group=$group marker=$start loop_end=$end position=$actual',
        );
      }
    } on Object catch (error) {
      if (mounted && generation == _previewGeneration) {
        await _stopPreview();
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('试听失败：$error')));
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AuditionPreferences>(auditionPreferencesProvider, (_, next) {
      if (_preview != null &&
          Platform.environment['FH_RADIO_STUDIO_PREVIEW_DIAGNOSTICS'] != '1') {
        unawaited(_preview!.setVolume(next.volume));
      }
    });
    final all = ref.watch(realPoolTracksProvider);
    final cli = ref.watch(studioProvider);
    final sirenImport = ref.watch(sirenImportQueueProvider);
    final sirenImporting = sirenImport.importing || cli.busyLabel == '导入塞壬唱片';
    final playlistPlan = ref.watch(effectivePlaylistPlanProvider);
    final splitTypes = ref.watch(
      playlistProvider.select((state) => state.splitPlaylistTypes),
    );
    final membership = ref.watch(gamePlaylistMembershipProvider).asData?.value;
    final gameAssignmentPlan = membership?.plan ?? const PlaylistPlan.empty();
    final gameAssignmentsKnown = membership != null;
    final latestPackage = cli.pendingPackageSummary ?? cli.lastPackageSummary;
    final configured = all.where((t) => t.readyForBuild).toList();
    final unconfigured = all.where((t) => !t.readyForBuild).toList();
    final unassigned = all.where((t) => t.assignedTo == null).toList();
    final msrTracks = all.where((t) => t.isSiren).toList();
    final panelTracks = _msrOnly ? msrTracks : all;
    final panelConfigured = panelTracks.where((t) => t.readyForBuild).toList();
    final panelUnconfigured = panelTracks
        .where((t) => !t.readyForBuild)
        .toList();
    final possibleDuplicates = duplicateSongs(all);
    final visible = browseSongs(
      _sortForEditing(switch (_filter) {
        _PoolFilter.all => panelTracks,
        _PoolFilter.unconfigured => panelUnconfigured,
        _PoolFilter.configured => panelConfigured,
      }),
      _browse,
      duplicates: possibleDuplicates,
      plan: playlistPlan,
      splitTypes: splitTypes,
    );
    final customRadios = kRadios
        .where((r) => kStationModes[r.code] == StationMode.custom)
        .toList();
    final importing = cli.busy && cli.busyLabel == '导入自建歌曲';

    return ExternalAudioDropTarget(
      enabled: !cli.busy && !sirenImport.importing,
      label: '松开以导入自建歌曲',
      onDrop: _importMusicFiles,
      child: PendingGate(
        pending: importing,
        label: '正在导入自建歌曲',
        detail: '正在导入音频到项目 sources，必要时转换到 48 kHz，并刷新曲目信息。',
        overlayKey: const ValueKey('custom-pool-import-gate'),
        childOpacity: 0.42,
        borderRadius: BorderRadius.zero,
        child: ContainedScroll(
          controller: _scroll,
          child: SizedBox.expand(
            child: Center(
              child: _LibraryCanvas(
                constraints: BoxConstraints(
                  maxWidth: ref
                      .watch(layoutOptionsProvider)
                      .pageWidth(RmTokens.pageDefault),
                ),
                child: SmoothScrollToTop(
                  controller: _scroll,
                  child: Stack(
                    children: [
                      CustomScrollView(
                        controller: _scroll,
                        scrollCacheExtent: const ScrollCacheExtent.pixels(200),
                        slivers: [
                          SliverPadding(
                            padding: const EdgeInsets.fromLTRB(40, 24, 40, 64),
                            sliver: SliverMainAxisGroup(
                              slivers: [
                                SliverToBoxAdapter(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      _pageHead(
                                        context,
                                        cli,
                                        sirenImporting: sirenImporting,
                                      ),
                                      const SizedBox(height: 8),
                                      _sourceDirectories(context, all, cli),
                                      if (DemoSong.sourceFor(cli.projectDir) !=
                                          null)
                                        const Padding(
                                          padding: EdgeInsets.only(top: 12),
                                          child: RmBanner(
                                            kind: RmBannerKind.info,
                                            title: '功能演示曲',
                                            body:
                                                '用于练习歌曲编辑与人工精修。完成介绍后，可用演示曲右侧的删除按钮移除。',
                                          ),
                                        ),
                                      const WaveformBatchProgress(),
                                      const SeamlessBatchProgress(),
                                      const SizedBox(height: 16),
                                      _statRow(
                                        context,
                                        total: all.length,
                                        configured: configured.length,
                                        unconfigured: unconfigured.length,
                                        unassigned: unassigned.length,
                                      ),
                                      const SizedBox(height: 16),
                                      if (possibleDuplicates.isNotEmpty) ...[
                                        RmButton(
                                          size: RmButtonSize.sm,
                                          onPressed: () => setState(() {
                                            _filter = _PoolFilter.all;
                                            _browse = _browse.copyWith(
                                              filter: SongFilter.duplicates,
                                            );
                                            _poolBrowse[cli.projectDir] =
                                                _browse;
                                          }),
                                          leading: const RmIcon(
                                            'copy',
                                            size: 12,
                                          ),
                                          label:
                                              '发现 ${possibleDuplicates.length} 组可能重复的歌曲，点击查看',
                                        ),
                                        const SizedBox(height: 8),
                                      ],
                                    ],
                                  ),
                                ),
                                _tracksPanel(
                                  context,
                                  totalCount: panelTracks.length,
                                  visible: visible,
                                  cli: cli,
                                  unconfiguredCount: panelUnconfigured.length,
                                  configuredCount: panelConfigured.length,
                                  msrCount: msrTracks.length,
                                  latestPackage: latestPackage,
                                  playlistPlan: playlistPlan,
                                  splitTypes: splitTypes,
                                  gameAssignmentPlan: gameAssignmentPlan,
                                  uncertainGameSources:
                                      membership?.uncertainSources ?? const {},
                                  gameAssignmentsKnown: gameAssignmentsKnown,
                                  sirenImporting: sirenImporting,
                                ),
                                SliverToBoxAdapter(
                                  child: Padding(
                                    padding: const EdgeInsets.only(top: 14),
                                    child: _infoBanner(
                                      context,
                                      customRadios: customRadios,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ).withFeatureTour(
      TourPage.library,
      enabled: !cli.busy,
      onComplete: () {
        if (ref.read(featureToursProvider).seen(TourPage.song)) return;
        final demos = all.where(
          (track) => DemoSong.matches(cli.projectDir, track.source),
        );
        if (demos.isNotEmpty && mounted) {
          ref
              .read(editorSongQueueProvider.notifier)
              .begin(cli.projectDir, all.map((t) => t.id));
          context.go(RmRoutes.editor(demos.first.id));
        }
      },
    );
  }

  Widget _pageHead(
    BuildContext context,
    StudioState cli, {
    required bool sirenImporting,
  }) {
    final rm = context.rm;
    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('自建歌曲', style: RmText.pageH1(color: rm.fg)),
        const SizedBox(height: 6),
        Text(
          '先分配歌曲：仅漫游可直接使用；用于比赛时需确认四组时间点。',
          style: RmText.body(color: rm.fg3),
        ),
      ],
    );
    final actions = KeyedSubtree(
      key: const ValueKey('pool-library-actions'),
      child: _libraryActions(context, cli, sirenImporting),
    ).tourAnchor('import');
    return LayoutBuilder(
      builder: (context, box) => box.maxWidth >= 900
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(child: title),
                const SizedBox(width: 16),
                actions,
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                title,
                const SizedBox(height: 10),
                Align(alignment: Alignment.centerRight, child: actions),
              ],
            ),
    );
  }

  Wrap _libraryActions(
    BuildContext context,
    StudioState cli,
    bool sirenImporting,
  ) {
    final batch = ref.watch(waveformBatchProvider);
    final loopBatch = ref.watch(seamlessBatchProvider);
    final seamless = ref.watch(editorOptionsProvider).slmEnabled;
    final sirenEnabled = ref.watch(editorOptionsProvider).sirenEnabled;
    final tracks = ref.watch(realPoolTracksProvider);
    final localImporting = cli.busy && cli.busyLabel == '导入自建歌曲';
    final localImportLocked = cli.busy || sirenImporting;
    final sirenNavigationLocked =
        cli.busy && cli.busyLabel != '导入塞壬唱片' && !sirenImporting;
    return Wrap(
      alignment: WrapAlignment.end,
      spacing: 8,
      runSpacing: 8,
      children: [
        RmButton(
          onPressed: _openFirstInputFolder,
          leading: const RmIcon('folder', size: 12),
          label: '打开目录',
        ),
        RmButton(
          label: batch.running ? '分析波形 ${batch.done}/${batch.total}' : '分析全部波形',
          leading: batch.running
              ? const _ButtonSpinner()
              : const RmIcon('refresh', size: 12),
          tooltip: '只分析并缓存波形，不运行 AI，不修改歌曲点位',
          onPressed:
              batch.running || loopBatch.running || cli.busy || tracks.isEmpty
              ? null
              : () => unawaited(
                  ref.read(waveformBatchProvider.notifier).start(tracks),
                ),
        ),
        if (seamless)
          RmButton(
            label: loopBatch.running
                ? '分析循环 ${loopBatch.done}/${loopBatch.total}'
                : '分析全部循环',
            leading: loopBatch.running
                ? const _ButtonSpinner()
                : const RmIcon('loop', size: 12),
            tooltip: '分析全部歌曲，每首保留最多 10 个循环建议；不会自动修改或确认时间点',
            onPressed:
                batch.running || loopBatch.running || cli.busy || tracks.isEmpty
                ? null
                : () => unawaited(
                    ref.read(seamlessBatchProvider.notifier).start(tracks),
                  ),
          ),
        if (sirenEnabled || sirenImporting) ...[
          RmButton(
            onPressed: sirenNavigationLocked
                ? null
                : () => context.go(RmRoutes.siren),
            leading: sirenImporting
                ? const _ButtonSpinner()
                : const RmIcon('spark', size: 12),
            label: sirenImporting ? '塞壬导入中' : '塞壬唱片',
            tooltip: sirenImporting
                ? '塞壬唱片正在导入，点击查看进度'
                : sirenNavigationLocked
                ? '当前正在导入自建歌曲'
                : null,
          ),
        ],
        RmButton(
          onPressed: localImportLocked ? null : _pickMusicFiles,
          variant: RmButtonVariant.primary,
          leading: const RmIcon('import', size: 12),
          label: localImporting ? '导入中' : '导入新曲目',
          tooltip: sirenImporting ? '塞壬唱片正在导入，完成后可导入本地歌曲' : null,
        ),
      ],
    );
  }

  Widget _sourceDirectories(
    BuildContext context,
    List<PoolTrack> tracks,
    StudioState cli,
  ) {
    final dirs =
        tracks.isEmpty
              ? ['${cli.projectDir}\\sources']
              : tracks.map((t) => File(t.source).parent.path).toSet().toList()
          ..sort();
    final label = dirs.join(' · ');
    return Row(
      key: const ValueKey('pool-source-directory'),
      children: [
        RmIcon('folder', size: 12, color: context.rm.fg3),
        const SizedBox(width: 8),
        Expanded(
          child: Tooltip(
            message: label,
            child: Text(
              '来源目录 $label',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: RmText.mono(11, color: context.rm.fg3),
            ),
          ),
        ),
      ],
    );
  }

  Widget _statRow(
    BuildContext context, {
    required int total,
    required int configured,
    required int unconfigured,
    required int unassigned,
  }) {
    final rm = context.rm;
    return LayoutBuilder(
      builder: (context, c) {
        const minCellW = 180.0;
        final cols = (c.maxWidth / (minCellW + 12)).floor().clamp(1, 4);
        final cellW = (c.maxWidth - 12 * (cols - 1)) / cols;
        Widget cell(Widget w) => SizedBox(width: cellW, child: w);
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            cell(
              StatCard(
                label: '池子总数',
                value: '$total',
                delta: '来自 $total 个本地文件',
              ),
            ),
            cell(
              StatCard(
                label: '已配置 · 可用',
                value: '$configured  /  $total',
                delta: '比赛已配置 / 仅漫游可用',
              ),
            ),
            cell(
              StatCard(
                label: '待完成',
                value: '$unconfigured',
                valueColor: unconfigured > 0 ? rm.warn : null,
                delta: '需进入编辑器确认',
              ),
            ),
            cell(
              StatCard(label: '未分配', value: '$unassigned', delta: '不在任何电台中'),
            ),
          ],
        );
      },
    );
  }

  Widget _tracksPanel(
    BuildContext context, {
    required int totalCount,
    required List<PoolTrack> visible,
    required StudioState cli,
    required int unconfiguredCount,
    required int configuredCount,
    required int msrCount,
    required PackageArtifactSummary? latestPackage,
    required PlaylistPlan playlistPlan,
    required bool splitTypes,
    required PlaylistPlan gameAssignmentPlan,
    required Set<String> uncertainGameSources,
    required bool gameAssignmentsKnown,
    required bool sirenImporting,
  }) {
    final rm = context.rm;
    Widget row(int i) => _PoolRow(
      key: ValueKey('pool-row:${visible[i].id}'),
      track: visible[i],
      isLast: i == visible.length - 1,
      divider: rm.border,
      editingLocked: false,
      editLockMessage: '',
      latestPackage: latestPackage,
      stagedAssignment: playlistPlan.assignmentForPath(visible[i].source),
      gameAssignment: gameAssignmentPlan.assignmentForPath(visible[i].source),
      gameAssignmentsKnown:
          gameAssignmentsKnown &&
          !uncertainGameSources.contains(
            PlaylistAssignment.keyForPath(visible[i].source),
          ),
      onPreview: (group) => unawaited(_quickPreview(visible[i], group)),
      previewKey: _previewKey,
      onTap: () {
        _poolFilters[cli.projectDir] = _filter;
        unawaited(_stopPreview());
        ref
            .read(editorSongQueueProvider.notifier)
            .begin(cli.projectDir, visible.map((t) => t.id));
        context.go(RmRoutes.editor(visible[i].id));
      },
      onDelete: () => _confirmAndDeleteTrack(context, visible[i]),
    );
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: RmPanel(
            title: '曲目',
            titleTrailing: Wrap(
              spacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _MsrOnlySwitch(
                  value: _msrOnly,
                  count: msrCount,
                  onChanged: (value) => setState(() => _msrOnly = value),
                ),
                const RmChip(
                  label: '仅自建歌曲可编辑',
                  variant: RmChipVariant.muted,
                  showDot: true,
                ),
              ],
            ),
            noPad: true,
            headerTrailing: Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 8,
              children: [
                const TimingImportButton(),
                const TimingExportButton(),
                const AuditionSettingsButton(),
                RmSegmented<_PoolFilter>(
                  value: _filter,
                  onChanged: (v) => setState(() {
                    _filter = v;
                    _browse = _browse.copyWith(filter: SongFilter.all);
                    _poolBrowse[cli.projectDir] = _browse;
                  }),
                  options: [
                    RmSegmentedOption(
                      value: _PoolFilter.all,
                      label: '全部 · $totalCount',
                    ),
                    RmSegmentedOption(
                      value: _PoolFilter.unconfigured,
                      label: '待完成 · $unconfiguredCount',
                    ),
                    RmSegmentedOption(
                      value: _PoolFilter.configured,
                      label: '已完成 · $configuredCount',
                    ),
                  ],
                ),
              ],
            ).tourAnchor('browse'),
            child: Column(
              children: [
                SongBrowseControls(
                  value: _browse,
                  showScene: splitTypes,
                  onChanged: (v) => setState(() {
                    if (v.filter != _browse.filter) _filter = _PoolFilter.all;
                    _browse = v;
                    _poolBrowse[cli.projectDir] = v;
                  }),
                ).tourAnchor('browse-end'),
                _PoolHeaderRow(),
              ],
            ),
          ),
        ),
        if (visible.isEmpty)
          SliverToBoxAdapter(
            child: _empty(
              context,
              cli,
              msrOnly: _msrOnly,
              sirenImporting: sirenImporting,
              filtered: totalCount > 0,
            ),
          )
        else
          DecoratedSliver(
            decoration: BoxDecoration(
              color: rm.panel,
              border: Border(
                left: BorderSide(color: rm.border),
                right: BorderSide(color: rm.border),
                bottom: BorderSide(color: rm.border),
              ),
            ),
            sliver: SliverMainAxisGroup(
              slivers: [
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: 72 * MediaQuery.textScalerOf(context).scale(1),
                    child: row(0).tourAnchor('songs'),
                  ),
                ),
                SliverFixedExtentList.builder(
                  itemExtent: 72 * MediaQuery.textScalerOf(context).scale(1),
                  itemCount: visible.length - 1,
                  itemBuilder: (context, i) => row(i + 1),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _empty(
    BuildContext context,
    StudioState cli, {
    required bool msrOnly,
    required bool sirenImporting,
    bool filtered = false,
  }) {
    final rm = context.rm;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 80),
      child: Column(
        children: [
          Text(
            filtered ? '没有符合筛选的歌曲' : '这里空空的',
            style: RmText.emptyTitle(color: rm.fg),
          ),
          const SizedBox(height: 6),
          Text(
            filtered
                ? '切换为全部场景，或调整搜索、状态和电台筛选。'
                : msrOnly
                ? '从塞壬唱片导入歌曲后会显示在这里'
                : '导入 .mp3 / .flac / .wav 开始构建你的池子',
            style: RmText.body(color: rm.fg3),
          ),
          const SizedBox(height: 16),
          if (filtered)
            RmButton(
              label: '清除筛选',
              onPressed: () => setState(() {
                _filter = _PoolFilter.all;
                _browse = _browse.copyWith(
                  search: '',
                  filter: SongFilter.all,
                  station: '',
                  scene: SongSceneFilter.all,
                );
                _poolBrowse[cli.projectDir] = _browse;
              }),
            )
          else
            RmButton(
              onPressed:
                  cli.busy ||
                      (msrOnly &&
                          !ref.watch(editorOptionsProvider).sirenEnabled) ||
                      (!msrOnly && sirenImporting)
                  ? null
                  : (msrOnly
                        ? () => context.go(RmRoutes.siren)
                        : _pickMusicFiles),
              variant: RmButtonVariant.primary,
              leading: msrOnly && sirenImporting
                  ? const _ButtonSpinner()
                  : RmIcon(msrOnly ? 'spark' : 'import', size: 12),
              label: msrOnly && sirenImporting
                  ? '塞壬导入中'
                  : msrOnly
                  ? '前往 MSR'
                  : '导入曲目',
              tooltip: !msrOnly && sirenImporting
                  ? '塞壬唱片正在导入，完成后可导入本地歌曲'
                  : null,
            ),
        ],
      ),
    );
  }

  Widget _infoBanner(
    BuildContext context, {
    required List<RadioStation> customRadios,
  }) {
    final rm = context.rm;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: rm.panel,
        border: Border.all(color: rm.border),
        borderRadius: BorderRadius.circular(RmTokens.rMd),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: rm.info.withAlpha(36),
              borderRadius: BorderRadius.circular(RmTokens.rSm),
            ),
            alignment: Alignment.center,
            child: RmIcon('info', size: 14, color: rm.info),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 6,
              runSpacing: 6,
              children: [
                Text(
                  '怎么"用"这些歌？',
                  style: RmText.body(weight: FontWeight.w600, color: rm.fg),
                ),
                Text(
                  '每个电台是二选一：原版 (builtin) 或全部自建 (custom)。当前已切换为 custom 的电台：',
                  style: RmText.body(color: rm.fg2),
                ),
                if (customRadios.isEmpty)
                  Text('（无）', style: RmText.body(color: rm.fg3))
                else
                  for (final r in customRadios)
                    RmChip(
                      label: r.code,
                      variant: RmChipVariant.accent,
                      showDot: true,
                    ),
                Text(
                  '——这些电台原版 8 首已被替换。前往「播放列表」把池中曲目分配到 slot。',
                  style: RmText.body(color: rm.fg2),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickMusicFiles() async {
    if (ref.read(studioProvider).busy ||
        ref.read(sirenImportQueueProvider).importing) {
      return;
    }
    final result = await FilePicker.pickFiles(
      dialogTitle: '导入自建歌曲',
      type: FileType.custom,
      allowedExtensions: const ['flac', 'wav', 'mp3', 'm4a', 'ogg', 'aac'],
      allowMultiple: true,
    );
    final paths = result?.files
        .map((file) => file.path)
        .whereType<String>()
        .toList(growable: false);
    if (paths == null || paths.isEmpty) return;
    if (!mounted ||
        ref.read(studioProvider).busy ||
        ref.read(sirenImportQueueProvider).importing) {
      return;
    }
    await _importMusicFiles(paths);
  }

  Future<void> _importMusicFiles(List<String> paths) async {
    if (!mounted ||
        paths.isEmpty ||
        ref.read(studioProvider).busy ||
        ref.read(sirenImportQueueProvider).importing) {
      return;
    }
    try {
      final message = await ref
          .read(studioProvider.notifier)
          .importMusicPaths(paths);
      if (mounted && message != null) showAudioImportResult(context, message);
    } on Object catch (error) {
      if (mounted) showAudioImportResult(context, '歌曲导入失败：$error');
    }
  }

  void _openFirstInputFolder() {
    final dir = Directory(ref.read(studioProvider).sourcesDir);
    if (!dir.existsSync()) return;
    if (Platform.isWindows) {
      Process.start('explorer', [dir.path]);
    } else if (Platform.isMacOS) {
      Process.start('open', [dir.path]);
    } else if (Platform.isLinux) {
      Process.start('xdg-open', [dir.path]);
    }
  }

  Future<void> _confirmAndDeleteTrack(
    BuildContext context,
    PoolTrack track,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      barrierColor: RmTokens.modalBackdrop,
      builder: (context) => _DeleteTrackDialog(track: track),
    );
    if (ok != true || !mounted) return;
    try {
      final handled = await ref
          .read(studioProvider.notifier)
          .deleteMusicPath(track.source);
      if (!context.mounted) return;
      if (!handled) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('删除失败：项目当前不可编辑或文件无法处理。')));
        return;
      }
      ref.read(trackTimingProvider.notifier).reload();
      ref.read(playlistPlanProvider.notifier).removeDeletedSource(track.source);
    } on FileSystemException catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('删除失败：${error.message}')));
    }
  }
}

class _ButtonSpinner extends StatelessWidget {
  const _ButtonSpinner();

  @override
  Widget build(BuildContext context) {
    final color = IconTheme.of(context).color ?? context.rm.accent.base;
    return SizedBox(
      width: 12,
      height: 12,
      child: CircularProgressIndicator(
        strokeWidth: 1.8,
        valueColor: AlwaysStoppedAnimation<Color>(color),
      ),
    );
  }
}

class _PoolTableLayout {
  _PoolTableLayout(double width, [Map<String, double> saved = const {}])
    : compact = width < 1200,
      assignment = width >= 1000,
      details = width >= 760 {
    final columns =
        3 + (assignment ? 1 : 0) + (details ? (compact ? 2 : 3) : 0);
    final fixed = 36 + 48 + 16 * (columns - 1);
    final others =
        (assignment ? (compact ? 130 : 200) : 0) +
        (details ? ((compact ? 64 : 86) + (compact ? 0 : 144) + 144) : 0) +
        160 +
        124;
    specs = [
      LibraryColumnSpec('song', width < 660 ? 80 : 96, width - fixed - others),
      if (assignment) LibraryColumnSpec('assignment', 104, compact ? 130 : 200),
      if (details) ...[
        LibraryColumnSpec('configuration', 64, compact ? 64 : 86),
        if (!compact) const LibraryColumnSpec('added', 112, 126),
        const LibraryColumnSpec('modified', 112, 128),
      ],
      LibraryColumnSpec('preview', width < 660 ? 132 : 144, 160),
      LibraryColumnSpec('actions', 124, 124),
    ];
    widths = fitLibraryColumns(width - fixed, specs, saved);
  }
  final bool compact, assignment, details;
  late final List<LibraryColumnSpec> specs;
  late final Map<String, double> widths;
  double get songWidth => widths['song']!;
  double get assignmentWidth => widths['assignment'] ?? 0;
  double get configurationWidth => widths['configuration'] ?? 0;
  double get addedWidth => widths['added'] ?? 0;
  double get modifiedWidth => widths['modified'] ?? 0;
  double get previewWidth => widths['preview']!;
  double get previewButtonWidth => ((previewWidth - 16) / 4).clamp(29.0, 36.0);
  double get actionWidth => widths['actions']!;
}

class _PoolHeaderRow extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) => LayoutBuilder(
    builder: (context, c) {
      final rm = context.rm;
      final layout = _PoolTableLayout(
        c.maxWidth,
        ref.watch(libraryColumnsProvider),
      );
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: rm.border)),
        ),
        child: Row(
          children: [
            const SizedBox(width: 48),
            cell(context, ref, layout, 'song', _h(context, '曲目')),
            if (layout.assignment) ...[
              cell(context, ref, layout, 'assignment', _h(context, '分配至')),
            ],
            if (layout.details) ...[
              cell(context, ref, layout, 'configuration', _h(context, '配置')),
              if (!layout.compact)
                cell(context, ref, layout, 'added', _h(context, '添加')),
              cell(
                context,
                ref,
                layout,
                'modified',
                _h(context, layout.compact ? '添加 / 最后修改' : '最后修改'),
              ),
            ],
            cell(context, ref, layout, 'preview', _h(context, '快速试听')),
            cell(context, ref, layout, 'actions', _h(context, '操作')),
          ],
        ),
      );
    },
  );
  Widget cell(
    BuildContext context,
    WidgetRef ref,
    _PoolTableLayout layout,
    String id,
    Widget child,
  ) => SizedBox(
    width: layout.widths[id]! + (id == 'actions' ? 0 : 16),
    child: Stack(
      clipBehavior: Clip.none,
      children: [
        SizedBox(
          width: layout.widths[id],
          height: 22,
          child: Align(
            alignment: Alignment.centerLeft,
            child: KeyedSubtree(
              key: ValueKey('pool-column-title-$id'),
              child: child,
            ),
          ),
        ),
        if (id != 'actions')
          Positioned(
            right: 2,
            top: 0,
            bottom: 0,
            width: 12,
            child: Tooltip(
              message: '拖动调整列宽；双击恢复默认',
              child: MouseRegion(
                cursor: SystemMouseCursors.resizeColumn,
                child: GestureDetector(
                  key: ValueKey('pool-column-grip-$id'),
                  behavior: HitTestBehavior.opaque,
                  dragStartBehavior: DragStartBehavior.down,
                  onHorizontalDragStart: (d) => ref
                      .read(libraryColumnsProvider.notifier)
                      .beginResize(
                        layout.specs,
                        layout.widths,
                        layout.specs.indexWhere((s) => s.id == id),
                        d.globalPosition.dx,
                      ),
                  onHorizontalDragUpdate: (d) => ref
                      .read(libraryColumnsProvider.notifier)
                      .updateResize(d.globalPosition.dx),
                  onHorizontalDragEnd: (_) =>
                      ref.read(libraryColumnsProvider.notifier).endResize(),
                  onHorizontalDragCancel: () =>
                      ref.read(libraryColumnsProvider.notifier).endResize(),
                  onDoubleTap: () =>
                      ref.read(libraryColumnsProvider.notifier).reset(),
                  child: Center(
                    child: Container(
                      width: 1,
                      height: 14,
                      color: context.rm.borderStrong,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
  Widget _h(BuildContext context, String s) => Text(
    s,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: RmText.mono(10.5, color: context.rm.fg3, letterSpacing: 1.05),
  );
}

class _PoolRow extends ConsumerStatefulWidget {
  const _PoolRow({
    super.key,
    required this.track,
    required this.isLast,
    required this.divider,
    required this.editingLocked,
    required this.editLockMessage,
    required this.latestPackage,
    required this.stagedAssignment,
    required this.gameAssignment,
    required this.gameAssignmentsKnown,
    required this.onTap,
    required this.onDelete,
    required this.onPreview,
    required this.previewKey,
  });

  final PoolTrack track;
  final bool isLast;
  final Color divider;
  final bool editingLocked;
  final String editLockMessage;
  final PackageArtifactSummary? latestPackage;
  final PlaylistAssignment? stagedAssignment;
  final PlaylistAssignment? gameAssignment;
  final bool gameAssignmentsKnown;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final void Function(String) onPreview;
  final String? previewKey;

  @override
  ConsumerState<_PoolRow> createState() => _PoolRowState();
}

class _PoolRowState extends ConsumerState<_PoolRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final t = widget.track;
    final packageAssignment = widget.latestPackage?.assignmentForSource(
      t.source,
    );
    final gameAssignmentLabel = widget.gameAssignmentsKnown
        ? _playlistAssignmentLabel(widget.gameAssignment)
        : null;
    final preparedTag = _preparedTag(
      staged: widget.stagedAssignment,
      packaged: packageAssignment,
      hasPackage: widget.latestPackage != null,
    );
    final art = _hover ? rm.accent.base : rm.fg3;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
          decoration: BoxDecoration(
            color: _hover ? rm.raised : Colors.transparent,
            border: widget.isLast
                ? null
                : Border(bottom: BorderSide(color: widget.divider)),
          ),
          child: LayoutBuilder(
            builder: (context, c) {
              final layout = _PoolTableLayout(
                c.maxWidth + 36,
                ref.watch(libraryColumnsProvider),
              );
              return Row(
                children: [
                  _PoolArtwork(track: t, iconColor: art),
                  const SizedBox(width: 16),
                  SizedBox(
                    key: ValueKey('pool-value-song:${t.id}'),
                    width: layout.songWidth,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                t.title,
                                style: RmText.rowTitle(color: rm.fg),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (t.isSiren) ...[
                              const SizedBox(width: 8),
                              const RmChip(
                                label: 'MSR',
                                variant: RmChipVariant.accent,
                                showDot: true,
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          t.isSiren && t.albumName != null
                              ? '${t.artist} · ${t.albumName} · ${formatDurationShort(t.durationSec)} · ${t.bpm} BPM · ${t.key}'
                              : '${t.artist} · ${formatDurationShort(t.durationSec)} · ${t.bpm} BPM · ${t.key}',
                          style: RmText.mono(11.5, color: rm.fg3),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (!layout.assignment) ...[
                          const SizedBox(height: 2),
                          Tooltip(
                            message: preparedTag.tooltip,
                            child: Text(
                              preparedTag.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: RmText.mono(10.5, color: rm.fg3),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  if (layout.assignment) ...[
                    SizedBox(
                      key: ValueKey('pool-value-assignment:${t.id}'),
                      width: layout.assignmentWidth,
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          _assignmentChip(
                            prefix: '游戏',
                            assignmentLabel: gameAssignmentLabel,
                            known: widget.gameAssignmentsKnown,
                            assignedVariant: RmChipVariant.accent,
                          ),
                          Tooltip(
                            message: preparedTag.tooltip,
                            waitDuration: const Duration(milliseconds: 350),
                            child: RmChip(
                              label: preparedTag.label,
                              variant: preparedTag.variant,
                              showDot: true,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                  ],
                  if (layout.details) ...[
                    SizedBox(
                      key: ValueKey('pool-value-configuration:${t.id}'),
                      width: layout.configurationWidth,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (!t.freeRoamOnly) ProgressBars(value: t.confirmed),
                          const SizedBox(height: 4),
                          Text(
                            t.freeRoamOnly
                                ? '漫游可用'
                                : t.configured
                                ? '已配置'
                                : '${t.confirmed}/4',
                            style: RmText.mono(
                              10.5,
                              color: t.readyForBuild ? rm.accent.base : rm.fg3,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    if (!layout.compact) ...[
                      SizedBox(
                        key: ValueKey('pool-value-added:${t.id}'),
                        width: layout.addedWidth,
                        child: Text(
                          t.added,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: RmText.mono(11, color: rm.fg3),
                        ),
                      ),
                      const SizedBox(width: 16),
                    ],
                    SizedBox(
                      key: ValueKey('pool-value-modified:${t.id}'),
                      width: layout.modifiedWidth,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (layout.compact)
                            Text(
                              t.added,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: RmText.mono(11, color: rm.fg3),
                            ),
                          Text(
                            formatSongModifiedMinute(t.modifiedAt),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: RmText.mono(11, color: rm.fg3),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                  ],
                  SizedBox(
                    key: ValueKey('pool-value-preview:${t.id}'),
                    width: layout.previewWidth,
                    child: Row(
                      children: [
                        for (final group in const ['td', 'tl', 'pd', 'pl'])
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: SizedBox(
                              width: layout.previewButtonWidth,
                              child: RmButton(
                                key: ValueKey('pool-preview:${t.id}:$group'),
                                size: RmButtonSize.sm,
                                horizontalPadding: 3,
                                foregroundColor: rm.fg3,
                                tooltip: '试听 ${group.toUpperCase()}',
                                onPressed: t.configured
                                    ? () => widget.onPreview(group)
                                    : null,
                                label: widget.previewKey == '${t.id}:$group'
                                    ? null
                                    : group.toUpperCase(),
                                leading: widget.previewKey == '${t.id}:$group'
                                    ? const Icon(Icons.stop, size: 10)
                                    : null,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  SizedBox(
                    key: ValueKey('pool-value-actions:${t.id}'),
                    width: layout.actionWidth,
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 120),
                      opacity: _hover ? 1 : 0.4,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.start,
                        children: [
                          RmButton(
                            onPressed: widget.onTap,
                            size: RmButtonSize.sm,
                            label: t.readyForBuild ? '查看' : '配置',
                          ),
                          const SizedBox(width: 4),
                          RmButton.icon(
                            onPressed: widget.editingLocked
                                ? null
                                : () => showQuickAssign(context, t),
                            icon: const Icon(Icons.playlist_add, size: 14),
                            tooltip: '快速分配电台',
                          ),
                          const SizedBox(width: 4),
                          RmButton.icon(
                            onPressed: widget.editingLocked
                                ? null
                                : widget.onDelete,
                            icon: const RmIcon('trash', size: 12),
                            variant: RmButtonVariant.ghost,
                            tooltip: widget.editingLocked
                                ? widget.editLockMessage
                                : '删除',
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _assignmentChip({
    required String prefix,
    required String? assignmentLabel,
    required bool known,
    required RmChipVariant assignedVariant,
  }) {
    final label = assignmentLabel == null
        ? (known ? '$prefix 未包含' : '$prefix 未检测')
        : '$prefix $assignmentLabel';
    final tooltip = assignmentLabel == null
        ? (known
              ? '游戏中位置\n当前游戏 RadioInfo 可读取，但这首歌不在游戏播放列表里。'
              : '游戏中位置\n当前游戏文件还没有完成可靠校验，无法判断这首歌在游戏里的位置。')
        : '游戏中位置\n当前游戏 RadioInfo 中检测到：$assignmentLabel。';
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 350),
      child: RmChip(
        label: label,
        variant: assignmentLabel == null
            ? RmChipVariant.muted
            : assignedVariant,
        showDot: true,
      ),
    );
  }

  String? _playlistAssignmentLabel(PlaylistAssignment? assignment) {
    if (assignment == null || !assignment.isAssigned) return null;
    return '${assignment.radioCode} · ${PlaylistAssignment.playlistLabel(assignment.playlistType)} slot ${assignment.slot}';
  }

  _PreparedTag _preparedTag({
    required PlaylistAssignment? staged,
    required PackageTrackAssignment? packaged,
    required bool hasPackage,
  }) {
    if (staged != null) {
      final dirty = !_samePreparedTarget(staged, packaged);
      final target = staged.isAssigned
          ? '${staged.radioCode} · ${PlaylistAssignment.playlistLabel(staged.playlistType)} slot ${staged.slot}'
          : '未包含';
      return _PreparedTag(
        label: '包 $target${dirty ? '*' : ''}',
        variant: dirty
            ? RmChipVariant.warn
            : (staged.isAssigned
                  ? RmChipVariant.defaultC
                  : RmChipVariant.muted),
        tooltip: dirty
            ? (staged.isAssigned
                  ? '准备包位置\n已在播放列表中改到 $target，但还没重新准备包。* 表示当前只是本地改动。'
                  : '准备包位置\n已在播放列表中移出这首歌，但还没重新准备包。* 表示当前只是本地改动。')
            : '准备包位置\n本地播放列表计划和最新准备包一致：$target。',
      );
    }
    if (packaged != null) {
      return _PreparedTag(
        label: '包 ${packaged.label}',
        variant: RmChipVariant.defaultC,
        tooltip: '准备包位置\n已经写入最新准备包：${packaged.label}。',
      );
    }
    return _PreparedTag(
      label: hasPackage ? '包 未包含' : '包 未检测',
      variant: RmChipVariant.muted,
      tooltip: hasPackage ? '准备包位置\n最新准备包没有包含这首歌。' : '准备包位置\n还没有可读取的最新准备包。',
    );
  }

  bool _samePreparedTarget(
    PlaylistAssignment staged,
    PackageTrackAssignment? packaged,
  ) {
    if (!staged.isAssigned) return packaged == null;
    return packaged != null &&
        packaged.radioLabel == staged.radioCode &&
        packaged.slot == staged.slot &&
        packaged.normalizedPlaylistTypes.contains(staged.playlistType);
  }
}

class _PoolArtwork extends StatelessWidget {
  const _PoolArtwork({required this.track, required this.iconColor});

  final PoolTrack track;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final coverPath = track.coverArtPath?.trim();
    final coverFile = coverPath == null || coverPath.isEmpty
        ? null
        : File(coverPath);
    final hasCover = coverFile != null && coverFile.existsSync();
    final borderColor = hasCover
        ? rm.border
        : track.isSiren
        ? rm.accent.base.withAlpha(160)
        : rm.border;

    return Container(
      width: 32,
      height: 32,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: track.isSiren ? Colors.black : rm.raised,
        border: Border.all(color: borderColor),
        borderRadius: BorderRadius.circular(RmTokens.rSm),
      ),
      alignment: Alignment.center,
      child: hasCover
          ? Image.file(
              coverFile,
              width: 32,
              height: 32,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => _fallback(),
            )
          : _fallback(),
    );
  }

  Widget _fallback() {
    if (track.isSiren) {
      return Image.asset(
        'assets/images/monster_siren_share_logo.png',
        width: 32,
        height: 32,
        fit: BoxFit.cover,
      );
    }
    return RmIcon('music', size: 14, color: iconColor);
  }
}

class _DeleteTrackDialog extends StatelessWidget {
  const _DeleteTrackDialog({required this.track});

  final PoolTrack track;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final assignment = track.assignedTo == null
        ? '未分配'
        : '${track.assignedTo} · slot ${track.slot ?? '-'}';
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 36),
      child: Container(
        width: 560,
        constraints: const BoxConstraints(maxHeight: 720),
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
              padding: const EdgeInsets.fromLTRB(24, 22, 24, 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: rm.dangerBg,
                      border: Border.all(color: rm.danger.withAlpha(77)),
                      borderRadius: BorderRadius.circular(RmTokens.rMd),
                    ),
                    child: RmIcon('trash', size: 17, color: rm.danger),
                  ),
                  const SizedBox(width: 13),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'DELETE TRACK',
                          style: RmText.mono(
                            11,
                            color: rm.danger,
                            letterSpacing: 0.12 * 11,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text('删除这首自建歌曲？', style: RmText.modalH2(color: rm.fg)),
                      ],
                    ),
                  ),
                  RmButton.icon(
                    onPressed: () => Navigator.of(context).pop(false),
                    icon: const RmIcon('x', size: 13),
                    variant: RmButtonVariant.ghost,
                    tooltip: '取消',
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: rm.border),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 18, 24, 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '这会删除项目 sources 里的音频文件，并清理这首歌的时间点配置、metadata 缓存和播放列表草稿引用。已经写入游戏的文件不会在这一步被修改。',
                      style: RmText.body(color: rm.fg2),
                    ),
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                      decoration: BoxDecoration(
                        color: rm.raised,
                        border: Border.all(color: rm.border),
                        borderRadius: BorderRadius.circular(RmTokens.rMd),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            track.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: RmText.sans(
                              13,
                              weight: FontWeight.w700,
                              color: rm.fg,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            track.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: RmText.mono(11.5, color: rm.fg2),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            assignment,
                            style: RmText.mono(11.5, color: rm.fg3),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            track.source,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: RmText.mono(11, color: rm.fg3),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    const RmBanner(
                      kind: RmBannerKind.danger,
                      title: '删除提醒：',
                      body:
                          '删除后无法从 FH Radio Studio 内恢复这份项目副本。需要保留时，请先打开目录手动复制。',
                    ),
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
                    onPressed: () => Navigator.of(context).pop(true),
                    variant: RmButtonVariant.danger,
                    label: '确认删除',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

List<PoolTrack> _sortForEditing(Iterable<PoolTrack> tracks) {
  final items = tracks.toList(growable: false);
  final indexed = <({int index, PoolTrack track})>[
    for (var index = 0; index < items.length; index += 1)
      (index: index, track: items[index]),
  ];
  indexed.sort((a, b) {
    final byCompleteness = _configurationCompleteness(
      a.track,
    ).compareTo(_configurationCompleteness(b.track));
    if (byCompleteness != 0) return byCompleteness;
    if (a.track.configured != b.track.configured) {
      return a.track.configured ? 1 : -1;
    }
    if (a.track.isSiren != b.track.isSiren) {
      return a.track.isSiren ? -1 : 1;
    }
    return a.index.compareTo(b.index);
  });
  return [for (final item in indexed) item.track];
}

int _configurationCompleteness(PoolTrack track) {
  if (track.configured) return 4;
  return track.confirmed.clamp(0, 4).toInt();
}

class _PreparedTag {
  const _PreparedTag({
    required this.label,
    required this.variant,
    required this.tooltip,
  });

  final String label;
  final RmChipVariant variant;
  final String tooltip;
}

class _MsrOnlySwitch extends StatelessWidget {
  const _MsrOnlySwitch({
    required this.value,
    required this.count,
    required this.onChanged,
  });

  final bool value;
  final int count;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final color = value ? rm.accent.base : rm.fg3;
    final border = value ? rm.accent.ring : rm.border;
    final bg = value
        ? Color.alphaBlend(rm.accent.base.withAlpha(10), rm.panel)
        : Colors.transparent;
    return Tooltip(
      message: '仅显示从塞壬唱片 MSR 导入的歌曲',
      waitDuration: const Duration(milliseconds: 350),
      child: Semantics(
        label: '仅显示 MSR 导入歌曲',
        toggled: value,
        button: true,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            key: const ValueKey('custom-pool-msr-only-switch'),
            behavior: HitTestBehavior.opaque,
            onTap: () => onChanged(!value),
            child: Container(
              height: 24,
              padding: const EdgeInsets.symmetric(horizontal: 9),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: border),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 5,
                    height: 5,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'MSR · $count',
                    style: RmText.sans(
                      11.5,
                      color: color,
                      weight: value ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LibraryCanvas extends StatelessWidget {
  const _LibraryCanvas({required this.constraints, required this.child});
  final BoxConstraints constraints;
  final Widget child;
  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: constraints,
    child: LayoutBuilder(
      builder: (context, c) => c.maxWidth >= 540
          ? child
          : SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(width: 540, height: c.maxHeight, child: child),
            ),
    ),
  );
}
