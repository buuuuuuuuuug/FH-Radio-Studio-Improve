part of '../voice_replacement.dart';

const _voiceLanguageFilters = <String, String>{
  '当前语言': '当前语音语言',
  '全部语言': '全部语言',
  'CN': '简体中文',
  'TW': '繁體中文',
  'JP': '日本語',
  'EN': 'English',
  'DE': 'Deutsch',
  'ES': 'Español',
  'MX': 'Español (México)',
  'IT': 'Italiano',
  'KO': '한국어',
  'BR': 'Português (Brasil)',
};

extension _VoiceBrowser on _VoiceReplacementState {
  Future<void> _warmCurrent() async {
    if (_locked || !_readyFile || _entries.isEmpty) return;
    final id = '${_bank['id']}';
    await _guard(() async {
      _update(() => _busyText = '正在补齐 ${_entries.length} 条试听缓存…');
      final decoded = await _call('decode-all', {'bank': id});
      final paths = stingerMap(decoded['paths']);
      for (final entry in _entries) {
        entry['preview_path'] = paths['${entry['index']}'];
      }
      _catalogs[id]!['decoded'] = true;
      _update(() {
        _busyText = '';
        _notice = '全部试听音频已准备，可直接播放。';
      });
    });
  }

  void _selectResource(Map<String, dynamic> file) {
    if (_locked) return;
    final cached =
        _catalogs['${file['bank_id']}'] ??
        _catalogs.values
            .where(
              (c) =>
                  stingerMap(c['bank'])['relative_path'] ==
                  file['relative_path'],
            )
            .firstOrNull;
    _playGeneration++;
    if (_playing != null) unawaited(_voicePlayer.pause());
    _update(() {
      _pending = file;
      _selectingExport = false;
      _exportEntries.clear();
      _playing = null;
      _entrySearch.clear();
      if (cached != null) {
        _bank = stingerMap(cached['bank']);
        _preferredBank = '${_bank['id']}';
        _entries = stingerMaps(cached['entries']);
        _index = _entries.isEmpty ? 0 : _entries.first['index'] as int;
      }
    });
    if (_entryScroll.hasClients) _entryScroll.jumpTo(0);
    if (cached != null) unawaited(_rememberLayout());
  }

  Future<void> _prepareSelected() async {
    if (_pending == null || _locked || _unavailableResource) return;
    final selected = Map<String, dynamic>.from(_pending!);
    Map<String, dynamic> estimate = {};
    await _guard(() async {
      estimate = await _call('inspect', {'source': selected['path']});
    });
    if (!mounted || estimate.isEmpty) return;
    if (stingerNumber(estimate['count']) <= 0) {
      _update(() {
        _pending!['status'] = '无法解析';
        _pending!['reason'] =
            estimate['reason'] ?? '此文件不包含可独立解析的音频，请选择对应的音频资源。';
      });
      return;
    }
    final accepted =
        await showDialog<bool>(
          context: context,
          builder: (ctx) => TimingDialogFrame(
            title: '备份并解析音频资源',
            icon: 'volume',
            width: 560,
            busy: false,
            description: '${selected['name']}',
            body: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: ctx.rm.raised,
                    border: Border.all(color: ctx.rm.border),
                    borderRadius: BorderRadius.circular(RmTokens.rMd),
                  ),
                  child: Column(
                    children: [
                      _estimateRow(
                        '原始备份',
                        '1 个文件 · ${_size(estimate['source_bytes'])}',
                      ),
                      _estimateRow(
                        '预计文件数量',
                        '${stingerNumber(estimate['count']).toInt() + 1} 个（原始备份与试听音频）',
                      ),
                      _estimateRow(
                        '试听音频',
                        '预计 ${estimate['count']} 个 WAV · ${_size(estimate['decoded_bytes'])}',
                      ),
                      _estimateRow(
                        '预计总大小',
                        '${_size(estimate['total_bytes'])} + 少量目录与文本缓存',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                _confirmLine('shield', '先备份原文件', '保存工程内的独立原始快照，之后编辑不会直接写入游戏。'),
                _confirmLine(
                  'music',
                  '一次准备全部条目',
                  estimate['reason'] as String? ??
                      '按概览设置提取语音语言和显示语言文本，批量解码后可连续试听；以后直接复用缓存。大型文件首次处理可能需要一些时间。',
                ),
                _confirmLine(
                  'settings',
                  '保留编号与声音映射',
                  '默认使用替换选段的实际时长，可在编辑中选择保持原时长。歌曲与台呼在各自页面编辑。',
                ),
              ],
            ),
            actions: [
              RmButton(label: '取消', onPressed: () => Navigator.pop(ctx, false)),
              RmButton(
                key: const ValueKey('voice-confirm-action'),
                label: '确认解析',
                variant: RmButtonVariant.primary,
                onPressed: () => Navigator.pop(ctx, true),
              ),
            ],
          ),
        ) ??
        false;
    if (!accepted || !mounted) return;
    await _guard(() async {
      _update(() => _busyText = '正在备份并解析 ${selected['name']}…');
      final data = await _call('prepare', {
        'source': selected['path'],
        if (selected['custom'] == true) 'input': {'custom': true},
      });
      if (!mounted) return;
      final bank = stingerMap(data['bank']),
          entries = stingerMaps(data['entries']);
      _update(() {
        _bank = bank;
        _entries = entries;
        _index = 0;
        _entrySearch.clear();
        _hydrate(stingerMap(data['plan']));
        _catalogs['${bank['id']}'] = {'bank': bank, 'entries': entries};
        selected['bank_id'] = bank['id'];
        selected['prepared'] = true;
        selected['relative_path'] = bank['relative_path'];
        selected['status'] = bank['supported'] == true
            ? '可替换'
            : entries.isEmpty
            ? '无法解析'
            : '仅试听';
        selected['reason'] = bank['reason'];
        if (!_files.any(
          (f) => f['relative_path'] == selected['relative_path'],
        )) {
          _files.add(selected);
        }
        for (final file in _files.where(
          (f) => f['relative_path'] == selected['relative_path'],
        )) {
          file.addAll(selected);
        }
        if (selected['custom'] == true) selected['category'] = '自选文件';
        _files = List<Map<String, dynamic>>.from(_files);
        _pending = selected;
      });
      if (entries.isNotEmpty) {
        _update(() => _busyText = '正在批量准备 ${entries.length} 条试听音频，完成后可直接播放…');
        final decoded = await _call('decode-all', {'bank': bank['id']});
        final paths = stingerMap(decoded['paths']);
        for (final entry in entries) {
          entry['preview_path'] = paths['${entry['index']}'];
        }
        _catalogs['${bank['id']}']!['decoded'] = true;
      }
      _update(() {
        _notice = '已备份并准备 ${entries.length} 条音频 · 再次切换直接使用缓存';
        _busyText = '';
      });
    });
  }

  Widget _estimateRow(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        Text(label, style: RmText.sans(12, color: context.rm.fg3)),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: RmText.mono(11, color: context.rm.fg),
          ),
        ),
      ],
    ),
  );

  Widget _library() {
    final rm = context.rm,
        query = _fileSearch.text.toLowerCase(),
        locale = ref.read(studioProvider).targetLang;
    final filterKey = jsonEncode([query, _language, locale]);
    if (!identical(_resourceSource, _files) ||
        _resourceFilterKey != filterKey) {
      _resourceSource = _files;
      _resourceFilterKey = filterKey;
      final languagePattern = RegExp(
        r'_(BR|CN|DE|EN|ES|IT|JP|KO|MX|TW)(?:\.assets)?\.bank$',
      );
      final currentSlot = locale == 'CHS'
          ? 'CN'
          : locale == 'CHT'
          ? 'TW'
          : locale;
      final slot = _language == '当前语言' || _language == '全部语言'
          ? currentSlot
          : _language;
      _resourceGroups = {};
      for (final file in _files) {
        final name = '${file['name']}';
        if ((query.isEmpty || name.toLowerCase().contains(query)) &&
            (_language == '全部语言' ||
                !languagePattern.hasMatch(name) ||
                name.contains('_$slot.'))) {
          _resourceGroups
              .putIfAbsent('${file['category'] ?? '自选文件'}', () => [])
              .add(file);
        }
      }
    }
    const order = [
      '自选文件',
      '导航',
      '活动与播报',
      '电台 DJ',
      '电台台呼',
      '歌曲与音乐',
      '车辆与环境',
      '其他音频',
      '无法解析／控制文件',
    ];
    int rank(String category) => category.startsWith('无法解析')
        ? 999
        : order.contains(category)
        ? order.indexOf(category)
        : 100;
    final groups = _resourceGroups.entries.toList()
      ..sort((a, b) => rank(a.key).compareTo(rank(b.key)));
    final modifiedPaths = <String>{
      for (final entry in _catalogs.entries)
        if (stingerMap(_edits[entry.key]).isNotEmpty ||
            jsonEncode(stingerMap(_edits[entry.key])) !=
                jsonEncode(stingerMap(_saved[entry.key])))
          '${stingerMap(entry.value['bank'])['relative_path']}',
    };
    bool changed(Map<String, dynamic> file) =>
        modifiedPaths.contains('${file['relative_path']}');
    Color statusColor(Map<String, dynamic> file) =>
        changed(file) || file['prepared'] == true ? rm.accent.base : rm.fg2;
    return _panel(
      '音频资源',
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              children: [
                PlaylistSearchField(
                  key: const ValueKey('voice-resource-filter'),
                  controller: _fileSearch,
                  onChanged: (_) => _update(() {}),
                  hint: '搜索资源文件',
                ),
                const SizedBox(height: 6),
                RmSelect(
                  key: const ValueKey('voice-language-filter'),
                  value: _language,
                  items: _voiceLanguageFilters,
                  onChanged: (v) {
                    _update(() => _language = v);
                    unawaited(_rememberLayout());
                  },
                ),
              ],
            ),
          ),
          Divider(height: 1, color: rm.border),
          Expanded(
            child: CustomScrollView(
              controller: _fileScroll,
              slivers: [
                for (final group in groups) ...[
                  SliverPersistentHeader(
                    key: ValueKey('voice-resource-group-${group.key}'),
                    pinned: true,
                    delegate: _VoiceGroupHeader(
                      height: 33,
                      child: Material(
                        color: rm.panel,
                        child: InkWell(
                          onTap: () => _update(() {
                            if (!_expanded.add(group.key)) {
                              _expanded.remove(group.key);
                            }
                          }),
                          child: Container(
                            key: ValueKey(
                              'voice-resource-group-mark-${group.key}',
                            ),
                            decoration: BoxDecoration(
                              border: Border(
                                left: BorderSide(
                                  width: 3,
                                  color: group.value.any(changed)
                                      ? rm.accent.base
                                      : Colors.transparent,
                                ),
                                bottom: BorderSide(color: rm.border),
                              ),
                            ),
                            padding: const EdgeInsets.symmetric(horizontal: 7),
                            child: Row(
                              children: [
                                RotatedBox(
                                  quarterTurns: _expanded.contains(group.key)
                                      ? 0
                                      : 3,
                                  child: RmIcon(
                                    'chevron-down',
                                    size: 14,
                                    color: rm.fg3,
                                  ),
                                ),
                                const SizedBox(width: 3),
                                Expanded(
                                  child: Text(
                                    group.key,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: RmText.sans(
                                      11.5,
                                      color: group.value.any(changed)
                                          ? rm.accent.base
                                          : group.value.any(
                                              (f) => f['prepared'] == true,
                                            )
                                          ? rm.accent.base
                                          : rm.fg,
                                      weight: group.value.any(changed)
                                          ? FontWeight.w600
                                          : FontWeight.w400,
                                    ),
                                  ),
                                ),
                                if (group.value.any(
                                  (f) => changed(f) || f['prepared'] == true,
                                ))
                                  Padding(
                                    padding: const EdgeInsets.only(right: 5),
                                    child: RmIcon(
                                      group.value.any(changed)
                                          ? 'pencil'
                                          : 'check',
                                      size: 11,
                                      color: group.value.any(changed)
                                          ? rm.accent.base
                                          : rm.accent.base,
                                    ),
                                  ),
                                Text(
                                  '${group.value.length}',
                                  style: RmText.mono(9.5, color: rm.fg3),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (_expanded.contains(group.key))
                    SliverList.builder(
                      key: ValueKey('voice-resource-files-${group.key}'),
                      itemCount: group.value.length,
                      itemBuilder: (context, i) {
                        final file = group.value[i],
                            selected =
                                _pending?['relative_path'] ==
                                file['relative_path'];
                        return RmTooltip(
                          message:
                              '${file['relative_path']}\n${file['reason'] ?? ''}',
                          child: InkWell(
                            key: ValueKey(
                              'voice-resource-${file['relative_path']}',
                            ),
                            onTap: _locked ? null : () => _selectResource(file),
                            child: Container(
                              key: ValueKey(
                                'voice-resource-mark-${file['relative_path']}',
                              ),
                              decoration: BoxDecoration(
                                color: selected ? rm.accent.bg : null,
                                border: Border(
                                  left: BorderSide(
                                    width: 3,
                                    color: changed(file)
                                        ? rm.accent.base
                                        : Colors.transparent,
                                  ),
                                ),
                              ),
                              padding: const EdgeInsets.fromLTRB(9, 7, 7, 7),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${file['name']}',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: RmText.mono(
                                      10.5,
                                      color: statusColor(file),
                                      weight: changed(file)
                                          ? FontWeight.w600
                                          : FontWeight.w400,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    '${_size(file['size'])} · ${changed(file)
                                        ? '已修改'
                                        : file['prepared'] == true
                                        ? '已解析'
                                        : file['status'] ?? '待解析'}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: RmText.sans(
                                      9.5,
                                      color: statusColor(file),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                ],
              ],
            ),
          ),
          Divider(height: 1, color: rm.border),
          Padding(
            padding: const EdgeInsets.all(7),
            child: LayoutBuilder(
              builder: (context, box) => Row(
                children: [
                  if (box.maxWidth >= 162)
                    Expanded(
                      child: RmButton(
                        key: const ValueKey('voice-rescan'),
                        label: '重新扫描',
                        size: RmButtonSize.sm,
                        horizontalPadding: 4,
                        leading: const RmIcon('refresh', size: 12),
                        onPressed: _locked ? null : _scan,
                      ),
                    )
                  else
                    _toolIcon(
                      'refresh',
                      '重新扫描',
                      _locked ? null : _scan,
                      key: const ValueKey('voice-rescan'),
                    ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: RmButton(
                      key: const ValueKey('voice-choose-resource'),
                      label: '自选文件',
                      size: RmButtonSize.sm,
                      horizontalPadding: 4,
                      leading: const RmIcon('folder', size: 12),
                      onPressed: _locked ? null : _choose,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      trailing: Text('${_files.length}', style: RmText.mono(10, color: rm.fg3)),
    );
  }
}

class _VoiceGroupHeader extends SliverPersistentHeaderDelegate {
  _VoiceGroupHeader({required this.child, required this.height});
  final Widget child;
  final double height;
  @override
  double get minExtent => height;
  @override
  double get maxExtent => height;
  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => SizedBox(height: height, child: child);
  @override
  bool shouldRebuild(covariant _VoiceGroupHeader oldDelegate) =>
      oldDelegate.child != child || oldDelegate.height != height;
}
