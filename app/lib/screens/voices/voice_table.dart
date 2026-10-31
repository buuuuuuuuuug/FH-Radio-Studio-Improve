part of '../voice_replacement.dart';

const _voiceColumnSpecs = <LibraryColumnSpec>[
  LibraryColumnSpec('number', 34, 34),
  LibraryColumnSpec('entry', 110, 250),
  LibraryColumnSpec('content', 66, 220),
  LibraryColumnSpec('translation', 72, 220),
  LibraryColumnSpec('original-duration', 66, 66),
  LibraryColumnSpec('original-play', 44, 44),
  LibraryColumnSpec('replacement-name', 116, 236),
  LibraryColumnSpec('category', 68, 90),
  LibraryColumnSpec('replacement-duration', 66, 66),
  LibraryColumnSpec('actions', 84, 84),
];

extension _VoiceTable on _VoiceReplacementState {
  double get _numberColumnWidth =>
      math.max(34.0, 16 + '${_entries.length}'.length * 7.0);
  bool get _readyFile {
    if (_bank.isEmpty || _pending == null) return false;
    if (_pending!['bank_id'] case final id?) return id == _bank['id'];
    final relative = _pending!['relative_path'];
    return relative != null && relative == _bank['relative_path'];
  }

  bool get _unavailableResource =>
      _pending != null &&
      (_pending!['status'] == '无法解析' ||
          (_readyFile && _entries.isEmpty && _bank['supported'] != true));

  String get _unavailableReason {
    final reason = '${_pending?['reason'] ?? ''}'.trim();
    return reason.isEmpty ? '此文件不包含可独立解析的音频，请选择对应的音频资源。' : reason;
  }

  List<Map<String, dynamic>> _visibleEntries() {
    final query = _entrySearch.text.toLowerCase().trim();
    if (!identical(_filteredSource, _entries) ||
        query != _filteredQuery ||
        !identical(_filteredEdits, _edits) ||
        !identical(_filteredAssets, _assets)) {
      _filteredSource = _entries;
      _filteredQuery = query;
      _filteredEdits = _edits;
      _filteredAssets = _assets;
      final assets = {
        for (var i = 0; i < _assets.length; i++)
          '${_assets[i]['id']}': (asset: _assets[i], number: i + 1),
      };
      _filteredEntries = query.isEmpty
          ? _entries
          : _entries.where((e) {
              final edit = stingerMap(_replacements['${e['index']}']);
              final material = assets['${edit['asset_id']}'];
              final asset = material?.asset;
              final text =
                  '${e['index'] + 1} ${e['name']} ${e['content'] ?? ''} ${e['translation'] ?? ''} ${e['duration']} ${stingerTime(e['duration'])} '
                  '${asset?['name'] ?? ''} ${asset?['category'] ?? ''} ${material?.number ?? ''} '
                  '${asset == null ? '未替换' : '已替换'} ${asset == null ? '' : stingerTime(stingerEditedDuration({...asset, ...edit}, stingerNumber(asset['duration'])))}';
              return query
                  .split(RegExp(r'\s+'))
                  .every((word) => text.toLowerCase().contains(word));
            }).toList();
    }
    return _filteredEntries;
  }

  List<LibraryColumnSpec> get _specs => [
    LibraryColumnSpec(
      'number',
      _selectingExport ? 68 : _numberColumnWidth,
      _selectingExport ? 68 : _numberColumnWidth,
    ),
    ..._voiceColumnSpecs.skip(1),
  ];

  void _fitColumns(double available) {
    if (!identical(_columnContentSource, _entries)) {
      _columnContentSource = _entries;
      _hasContent = _entries.any((e) => '${e['content'] ?? ''}'.isNotEmpty);
      _hasTranslation = _entries.any(
        (e) => '${e['translation'] ?? ''}'.isNotEmpty,
      );
    }
    final specs = _specs;
    final a = specs.take(6).toList(), b = specs.skip(6).toList();
    final minA = a.fold(0.0, (v, s) => v + s.minimum);
    final minB = b.fold(0.0, (v, s) => v + s.minimum);
    final total = math.max(available, minA + minB);
    final left = (total * _comparisonRatio).clamp(minA, total - minB);
    final desired = {
      for (var i = 0; i < specs.length; i++)
        specs[i].id: i == 2 && !_hasContent || i == 3 && !_hasTranslation
            ? specs[i].minimum
            : _desiredColumns[i],
    };
    final fitted = {
      ...fitLibraryColumns(left, a, desired),
      ...fitLibraryColumns(total - left, b, desired),
    };
    for (var i = 0; i < specs.length; i++) {
      _columns[i] = fitted[specs[i].id]!;
    }
  }

  void _resetColumns() {
    _update(() {
      _comparisonRatio = .62;
      for (var i = 0; i < _columns.length; i++) {
        _desiredColumns[i] = _voiceColumnSpecs[i].initial;
      }
    });
    unawaited(_rememberLayout());
  }

  void _resizeColumn(double x) {
    final drag = _columnDrag;
    if (drag == null) return;
    final i = drag.column, j = i + 1;
    final delta = (x - drag.origin).clamp(
      _specs[i].minimum - drag.widths[i],
      drag.widths[j] - _specs[j].minimum,
    );
    _update(() {
      _columns.setAll(0, drag.widths);
      _columns[i] += delta;
      _columns[j] -= delta;
      _desiredColumns.setAll(0, _columns);
    });
  }

  void _replaceDroppedAssets(List<String> ids, {required int index}) {
    if (_locked || !_readyFile || _bank['supported'] != true || ids.isEmpty) {
      return;
    }
    final start = _entries.indexWhere((e) => e['index'] == index);
    if (start < 0 || start + ids.length > _entries.length) {
      _update(() => _error = '后续条目不足，请减少所选素材。');
      return;
    }
    final next = stingerClone(_edits), changes = _replacements;
    for (var i = 0; i < ids.length; i++) {
      final asset = _assets.where((a) => a['id'] == ids[i]).firstOrNull;
      if (asset == null) return;
      changes['${_entries[start + i]['index']}'] = {
        'asset_id': asset['id'],
        'start': asset['start'] ?? 0.0,
        'end': asset['end'] ?? asset['duration'],
        'gain_db': asset['gain_db'] ?? 0.0,
        'keep_duration': false,
        'audio_edits': asset['audio_edits'] ?? [],
      };
    }
    next['${_bank['id']}'] = changes;
    _change(next);
  }

  void _toggleEntrySelection() {
    _workspaceFocus.requestFocus();
    _update(() {
      _selectingExport = !_selectingExport;
      if (!_selectingExport) _exportEntries.clear();
    });
  }

  void _selectEntry(int index) {
    final range = HardwareKeyboard.instance.isShiftPressed;
    final multi = HardwareKeyboard.instance.isControlPressed;
    if (_selectingExport || range || multi) {
      _workspaceFocus.requestFocus();
      _update(() {
        _selectingExport = true;
        final selected =
            SongSelection(
              ids: _exportEntries.map((i) => '$i').toSet(),
              anchor: '${_entryAnchor ?? _index}',
            ).click(
              '$index',
              _visibleEntries().map((e) => '${e['index']}').toList(),
              range: range,
            );
        _exportEntries
          ..clear()
          ..addAll(selected.ids.map(int.parse));
        _entryAnchor = index;
        _index = index;
      });
    } else {
      _update(() {
        _index = index;
        _entryAnchor = index;
      });
    }
  }

  Widget _workbenchToolbar(bool decoded) => LayoutBuilder(
    builder: (context, box) {
      Widget history(String label, String icon, VoidCallback? callback) =>
          RmButton(
            label: label,
            size: RmButtonSize.sm,
            leading: RmIcon(icon, size: 12),
            onPressed: callback,
          );
      final left = Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (!_selectingExport || box.maxWidth >= 1000) ...[
            history(
              '撤销',
              'undo',
              _undo.isEmpty || _locked ? null : () => _history(false),
            ),
            history(
              '重做',
              'redo',
              _redo.isEmpty || _locked ? null : () => _history(true),
            ),
            history(
              '恢复原音',
              'history',
              _locked || _replacements.isEmpty ? null : _restoreFile,
            ),
            if (!decoded && _entries.isNotEmpty)
              RmButton(
                label: '准备全部试听',
                size: RmButtonSize.sm,
                leading: const RmIcon('music', size: 12),
                onPressed: _locked ? null : _warmCurrent,
              ),
          ],
          RmButton(
            key: const ValueKey('voice-export-text'),
            label: _selectingExport ? '退出多选' : '多选导出',
            size: RmButtonSize.sm,
            leading: const RmIcon('export', size: 12),
            onPressed: _locked || _entries.isEmpty
                ? null
                : _toggleEntrySelection,
          ),
          if (_selectingExport) ..._entrySelectionActions(_visibleEntries()),
        ],
      );
      final files = box.maxWidth >= 820
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                RmButton(
                  key: const ValueKey('voice-open-audio-folder'),
                  label: '打开音频目录',
                  size: RmButtonSize.sm,
                  leading: const RmIcon('folder', size: 12),
                  onPressed: _locked
                      ? null
                      : () => _openDirectory(
                          'analysis/voices/original/${_bank['sha256']}',
                        ),
                ),
                const SizedBox(width: 6),
                RmButton(
                  key: const ValueKey('voice-forget-audio'),
                  label: '删除解析',
                  size: RmButtonSize.sm,
                  leading: const RmIcon('trash', size: 12),
                  foregroundColor: context.rm.danger,
                  onPressed: _locked ? null : _forgetFile,
                ),
              ],
            )
          : PopupMenuButton<String>(
              tooltip: '',
              color: context.rm.panel,
              surfaceTintColor: Colors.transparent,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(RmTokens.rSm),
                side: BorderSide(color: context.rm.border),
              ),
              onSelected: (v) {
                if (v == 'open') {
                  unawaited(
                    _openDirectory(
                      'analysis/voices/original/${_bank['sha256']}',
                    ),
                  );
                } else {
                  unawaited(_forgetFile());
                }
              },
              itemBuilder: (ctx) => [
                PopupMenuItem(
                  value: 'open',
                  enabled: !_locked,
                  child: _menuLabel('folder', '打开音频目录'),
                ),
                PopupMenuItem(
                  value: 'forget',
                  enabled: !_locked,
                  child: _menuLabel('trash', '删除解析记录'),
                ),
              ],
              child: IgnorePointer(
                child: RmButton(
                  label: '文件',
                  size: RmButtonSize.sm,
                  leading: const RmIcon('folder', size: 12),
                  trailing: const RmIcon('chevron-down', size: 11),
                  onPressed: () {},
                ),
              ),
            );
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: left),
          const SizedBox(width: 10),
          files,
        ],
      );
    },
  );

  List<Widget> _entrySelectionActions(List<Map<String, dynamic>> visible) {
    final ids = visible.map((e) => e['index'] as int).toSet();
    final all = ids.isNotEmpty && ids.every(_exportEntries.contains);
    return [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Text(
          '已选 ${_exportEntries.length}',
          style: RmText.sans(11, color: context.rm.fg3),
        ),
      ),
      RmButton(
        key: const ValueKey('voice-toggle-all-entries'),
        label: all ? '取消全选' : '全选',
        size: RmButtonSize.sm,
        onPressed: _locked || ids.isEmpty
            ? null
            : () => _update(() {
                if (all) {
                  _exportEntries.removeAll(ids);
                } else {
                  _exportEntries.addAll(ids);
                }
              }),
      ),
      RmButton(
        key: const ValueKey('voice-export-selected-text'),
        label: '导出文本',
        size: RmButtonSize.sm,
        leading: const RmIcon('export', size: 12),
        onPressed: _locked || _exportEntries.isEmpty ? null : _exportText,
      ),
      RmButton(
        key: const ValueKey('voice-extract-assets'),
        label: '加入素材池',
        size: RmButtonSize.sm,
        leading: const RmIcon('plus', size: 12),
        variant: RmButtonVariant.primary,
        onPressed: _locked || _exportEntries.isEmpty
            ? null
            : _extractOriginalAssets,
      ),
    ];
  }

  Widget _menuLabel(String icon, String label) => Row(
    children: [
      RmIcon(icon, size: 13),
      const SizedBox(width: 8),
      Text(label, style: RmText.sans(12, color: context.rm.fg)),
    ],
  );

  Widget _workbench() {
    final rm = context.rm, visible = _visibleEntries(), changes = _replacements;
    final decoded = _catalogs['${_bank['id']}']?['decoded'] == true;
    final fileDirty =
        jsonEncode(stingerMap(_edits['${_bank['id']}'])) !=
        jsonEncode(stingerMap(_saved['${_bank['id']}']));
    return _panel(
      '音频替换',
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            key: const ValueKey('voice-workbench-tools'),
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: RmTooltip(
                        message: '${_pending?['relative_path'] ?? ''}',
                        child: Text(
                          '${_pending?['name'] ?? '请从左侧选择文件'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: RmText.mono(
                            11.5,
                            color: rm.fg,
                            weight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (_readyFile)
                      RmChip(
                        key: const ValueKey('voice-resource-status'),
                        showDot: true,
                        dense: true,
                        label: changes.isEmpty && !fileDirty
                            ? '0 条替换 · 已解析'
                            : '${changes.length} 条替换 · ${jsonEncode(_edits['${_bank['id']}']) == jsonEncode(_saved['${_bank['id']}']) ? '已保存' : '未保存'}',
                        leading: changes.isEmpty && !fileDirty
                            ? null
                            : const RmIcon('pencil', size: 10),
                        variant: RmChipVariant.accent,
                      ),
                  ],
                ),
                if (_readyFile && !_unavailableResource) ...[
                  const SizedBox(height: 10),
                  _workbenchToolbar(decoded),
                ],
              ],
            ),
          ).tourAnchor(
            _readyFile && !_unavailableResource ? 'tools' : 'unprepared-header',
          ),
          Divider(height: 1, color: rm.border),
          if (_readyFile && !_unavailableResource) ...[
            Padding(
              key: const ValueKey('voice-workbench-search'),
              padding: const EdgeInsets.all(12),
              child: PlaylistSearchField(
                key: const ValueKey('voice-entry-filter'),
                controller: _entrySearch,
                onChanged: (_) => _update(() {}),
                hint: '搜索条目 / 文本 / 替换名称 / 分类',
              ),
            ).tourAnchor('tools-end'),

            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: rm.border),
                    borderRadius: BorderRadius.circular(RmTokens.rSm),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: _comparisonTable(visible, changes),
                ),
              ),
            ),
          ] else
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      RmIcon(
                        _unavailableResource ? 'info' : 'volume',
                        size: 32,
                        color: rm.fg4,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _unavailableResource
                            ? _unavailableReason
                            : _pending == null
                            ? '选择资源文件，或添加自选文件。'
                            : '备份并解析后，在此对照原音与替换音频。',
                        textAlign: TextAlign.center,
                        style: RmText.sans(12, color: rm.fg3, height: 1.6),
                      ),
                      if (_pending != null && !_unavailableResource) ...[
                        const SizedBox(height: 14),
                        RmButton(
                          key: const ValueKey('voice-prepare'),
                          label: '备份并解析',
                          leading: const RmIcon('shield', size: 12),
                          variant: RmButtonVariant.primary,
                          onPressed: _locked ? null : _prepare,
                        ).tourAnchor('prepare'),
                      ],
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
      hint: _unavailableResource
          ? '此资源暂不可解析'
          : !_readyFile
          ? '选择资源后备份并解析'
          : _selectingExport
          ? '勾选条目后导出文本或加入素材池'
          : _bank['supported'] != true
          ? '只读 · ${_bank['reason']}'
          : '拖入素材替换 · 双击编辑 · Ctrl+左键复制文本',
      trailing: !_readyFile || _unavailableResource
          ? null
          : Text(
              '${visible.length} 条音频',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: RmText.mono(
                10.5,
                color: changes.isEmpty ? rm.fg3 : rm.accent.base,
              ),
            ),
    );
  }

  Widget _comparisonTable(
    List<Map<String, dynamic>> visible,
    Map<String, dynamic> changes,
  ) => ScrollConfiguration(
    behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
    child: LayoutBuilder(
      builder: (context, box) {
        const railWidth = 14.0;
        _fitColumns(box.maxWidth - railWidth);
        final total = _columns.reduce((a, b) => a + b);
        final horizontal = total > box.maxWidth - railWidth + .5;
        final split = _columns.take(6).reduce((a, b) => a + b);
        return RawScrollbar(
          controller: _tableScroll,
          thumbVisibility: horizontal,
          scrollbarOrientation: ScrollbarOrientation.bottom,
          thickness: 6,
          radius: const Radius.circular(3),
          thumbColor: context.rm.fg4.withAlpha(150),
          padding: const EdgeInsets.only(right: railWidth),
          notificationPredicate: (n) => n.metrics.axis == Axis.horizontal,
          child: Column(
            children: [
              SizedBox(
                height: 59,
                child: Row(
                  children: [
                    Expanded(
                      child: ClipRect(
                        child: OverflowBox(
                          alignment: Alignment.topLeft,
                          minWidth: total,
                          maxWidth: total,
                          child: AnimatedBuilder(
                            animation: _tableScroll,
                            child: SizedBox(
                              width: total,
                              height: 59,
                              child: Stack(
                                children: [
                                  Column(
                                    children: [
                                      _groupHeaders(),
                                      _columnHeaders(visible),
                                    ],
                                  ),
                                  Positioned(
                                    left: split - 8,
                                    top: 0,
                                    bottom: 0,
                                    width: 16,
                                    child: _comparisonDivider(
                                      total,
                                      header: true,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            builder: (context, child) => Transform.translate(
                              offset: Offset(
                                _tableScroll.hasClients
                                    ? -_tableScroll.offset
                                    : 0,
                                0,
                              ),
                              child: child,
                            ),
                          ),
                        ),
                      ),
                    ),
                    Container(width: railWidth, color: context.rm.raised),
                  ],
                ),
              ).tourAnchor('entries'),
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, viewport) => SingleChildScrollView(
                          controller: _tableScroll,
                          scrollDirection: Axis.horizontal,
                          child: SizedBox(
                            width: total,
                            height: viewport.maxHeight,
                            child: Stack(
                              children: [
                                ListView.builder(
                                  key: const ValueKey('voice-entry-viewport'),
                                  controller: _entryScroll,
                                  itemExtent: 50,
                                  itemCount: visible.length,
                                  itemBuilder: (context, i) =>
                                      _voiceRow(visible[i], changes),
                                ),
                                Positioned(
                                  left: split - 8,
                                  top: 0,
                                  bottom: 0,
                                  width: 16,
                                  child: _comparisonDivider(total),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    _changeMap(visible, changes),
                  ],
                ),
              ),
              if (horizontal) const SizedBox(height: 10),
            ],
          ),
        );
      },
    ),
  );

  Widget _comparisonDivider(double total, {bool header = false}) => MouseRegion(
    cursor: SystemMouseCursors.resizeColumn,
    child: GestureDetector(
      key: ValueKey(
        header ? 'voice-comparison-divider' : 'voice-comparison-divider-body',
      ),
      behavior: HitTestBehavior.opaque,
      dragStartBehavior: DragStartBehavior.down,
      onHorizontalDragStart: (d) => _comparisonDrag = (
        origin: d.globalPosition.dx,
        width: total,
        ratio: _columns.take(6).reduce((a, b) => a + b) / total,
      ),
      onHorizontalDragUpdate: (d) {
        final drag = _comparisonDrag;
        if (drag == null) return;
        final minA = _specs.take(6).fold(0.0, (v, s) => v + s.minimum);
        final minB = _specs.skip(6).fold(0.0, (v, s) => v + s.minimum);
        _update(
          () => _comparisonRatio =
              (drag.ratio + (d.globalPosition.dx - drag.origin) / drag.width)
                  .clamp(minA / total, 1 - minB / total),
        );
      },
      onHorizontalDragEnd: (_) {
        _comparisonDrag = null;
        unawaited(_rememberLayout());
      },
      onHorizontalDragCancel: () => _comparisonDrag = null,
      onDoubleTap: _resetColumns,
      child: RmTooltip(
        message: '拖动调整两侧宽度；双击恢复默认',
        child: Center(
          child: Container(
            key: ValueKey(
              header ? 'voice-split-header-line' : 'voice-split-body-line',
            ),
            width: 1,
            color: context.rm.borderStrong,
          ),
        ),
      ),
    ),
  );

  Widget _groupHeaders() => Container(
    key: const ValueKey('voice-table-groups'),
    height: 30,
    color: context.rm.raised,
    child: Row(
      children: [
        SizedBox(
          width: _columns.take(6).reduce((a, b) => a + b),
          child: Padding(
            padding: const EdgeInsets.only(left: 10),
            child: Text(
              '原有音频',
              style: RmText.sans(
                12,
                color: context.rm.fg2,
                weight: FontWeight.w600,
              ),
            ),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(left: 18),
            child: Text(
              '替换音频',
              style: RmText.sans(
                12,
                color: context.rm.accent.base,
                weight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _columnHeaders(List<Map<String, dynamic>> visible) {
    const labels = ['', '条目', '语音语言', '显示语言', '时长', '', '名称', '分类', '时长', ''];
    return Container(
      height: 29,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: context.rm.border)),
      ),
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++)
            SizedBox(
              width: _columns[i],
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Align(
                      alignment: i == 0 && !_selectingExport
                          ? Alignment.center
                          : Alignment.centerLeft,
                      child: i == 0 && _selectingExport
                          ? Padding(
                              padding: const EdgeInsets.only(left: 8),
                              child: _VoiceCheck(
                                value:
                                    visible.isNotEmpty &&
                                    visible.every(
                                      (e) =>
                                          _exportEntries.contains(e['index']),
                                    ),
                                onChanged: (v) => _update(() {
                                  if (v == true) {
                                    _exportEntries.addAll(
                                      visible.map((e) => e['index'] as int),
                                    );
                                  } else {
                                    _exportEntries.removeAll(
                                      visible.map((e) => e['index'] as int),
                                    );
                                  }
                                }),
                              ),
                            )
                          : Padding(
                              padding: EdgeInsets.only(
                                left: i == 6 ? 18 : 8,
                                right: 8,
                              ),
                              child: Text(
                                labels[i],
                                style: RmText.sans(11, color: context.rm.fg3),
                              ),
                            ),
                    ),
                  ),
                  if ([1, 2, 6].contains(i))
                    Positioned(
                      right: -0.0,
                      top: 0,
                      bottom: 0,
                      width: 8,
                      child: MouseRegion(
                        cursor: SystemMouseCursors.resizeColumn,
                        child: GestureDetector(
                          key: ValueKey('voice-column-$i'),
                          behavior: HitTestBehavior.opaque,
                          dragStartBehavior: DragStartBehavior.down,
                          onHorizontalDragStart: (d) => _columnDrag = (
                            origin: d.globalPosition.dx,
                            column: i,
                            widths: List.from(_columns),
                          ),
                          onHorizontalDragUpdate: (d) =>
                              _resizeColumn(d.globalPosition.dx),
                          onHorizontalDragEnd: (_) {
                            _columnDrag = null;
                            unawaited(_rememberLayout());
                          },
                          onHorizontalDragCancel: () => _columnDrag = null,
                          onDoubleTap: _resetColumns,
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: Container(
                              width: 1,
                              height: 12,
                              color: context.rm.borderStrong,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _cell(int column, String text, {Color? color, String? hint}) =>
      SizedBox(
        width: _columns[column],
        child: RmTooltip(
          message: hint ?? text,
          child: Padding(
            padding: EdgeInsets.only(left: column == 6 ? 18 : 8, right: 8),
            child: Text(
              text,
              maxLines: column == 0 ? 1 : 2,
              overflow: TextOverflow.ellipsis,
              textAlign: column == 0 ? TextAlign.center : TextAlign.left,
              style: (column == 0 || column == 4 || column == 8)
                  ? RmText.mono(10, color: color ?? context.rm.fg3)
                  : RmText.sans(
                      11.5,
                      color: color ?? context.rm.fg2,
                      height: 1.35,
                    ),
            ),
          ),
        ),
      );

  Widget _copyTextCell(
    int column,
    String text,
    String label,
    int index,
    String reason,
  ) {
    if (text == '—') {
      return _cell(column, text, hint: reason.isEmpty ? '游戏未提供对应文本' : reason);
    }
    return InkWell(
      key: ValueKey(
        'voice-copy-${column == 2 ? 'content' : 'translation'}-$index',
      ),
      mouseCursor: SystemMouseCursors.click,
      onTap: () async {
        if (_selectingExport ||
            !HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isShiftPressed) {
          _selectEntry(index);
          return;
        }
        try {
          await Clipboard.setData(ClipboardData(text: text));
          _toast('$label已复制');
        } on Object catch (e) {
          _update(() => _error = '复制失败：$e');
        }
      },
      child: _cell(column, text, hint: text),
    );
  }

  Widget _toolIcon(
    String icon,
    String tooltip,
    VoidCallback? onTap, {
    bool danger = false,
    Key? key,
  }) => SizedBox(
    width: 26,
    height: 26,
    child: RmButton(
      key: key,
      leading: RmIcon(icon, size: 13),
      tooltip: tooltip,
      size: RmButtonSize.sm,
      horizontalPadding: 0,
      variant: RmButtonVariant.ghost,
      foregroundColor: danger ? context.rm.danger : context.rm.fg3,
      onPressed: onTap,
    ),
  );

  Widget _previewButton(String key, VoidCallback? onTap) => SizedBox(
    key: ValueKey('voice-play-$key'),
    width: 26,
    height: 26,
    child: _toolIcon(
      _playing == key ? 'stop' : 'play',
      _playing == key ? '停止试听' : '试听',
      onTap,
    ),
  );

  Widget _voiceRow(Map<String, dynamic> entry, Map<String, dynamic> changes) {
    final rm = context.rm, index = entry['index'] as int;
    final edit = stingerMap(changes['$index']);
    final asset = _assets.where((a) => a['id'] == edit['asset_id']).firstOrNull;
    void select() => _update(() => _index = index);
    String text(String key) =>
        '${entry[key] ?? ''}'.isEmpty ? '—' : '${entry[key]}';
    return ExternalAudioDropTarget(
      label: '松开以替换此条语音',
      leftInset: _columns.take(6).reduce((a, b) => a + b),
      enabled: !_locked && !_selectingExport && _bank['supported'] == true,
      onDrop: (paths) => _importPaths(paths, at: index),
      child: DragTarget<_VoiceDrag>(
        onWillAcceptWithDetails: (_) =>
            !_locked && !_selectingExport && _bank['supported'] == true,
        onAcceptWithDetails: (d) {
          select();
          _replaceDroppedAssets(d.data.ids, index: index);
        },
        builder: (context, candidates, rejected) => InkWell(
          onTap: () => _selectEntry(index),
          child: Container(
            key: ValueKey('voice-entry-$index'),
            decoration: BoxDecoration(
              color:
                  (_selectingExport
                          ? _exportEntries.contains(index)
                          : _index == index) ||
                      candidates.isNotEmpty
                  ? rm.accent.bg
                  : null,
              border: Border(bottom: BorderSide(color: rm.border)),
            ),
            child: Row(
              children: [
                if (_selectingExport)
                  SizedBox(
                    width: _columns[0],
                    child: Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Row(
                        children: [
                          _VoiceCheck(
                            value: _exportEntries.contains(index),
                            onChanged: (_) => _update(() {
                              if (!_exportEntries.add(index)) {
                                _exportEntries.remove(index);
                              }
                            }),
                          ),
                          Expanded(
                            child: Text(
                              '${index + 1}',
                              textAlign: TextAlign.center,
                              style: RmText.mono(10, color: rm.fg3),
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  _cell(
                    0,
                    '${index + 1}',
                    color: asset != null ? rm.accent.base : null,
                  ),
                _cell(1, '${entry['name']}'),
                _copyTextCell(
                  2,
                  text('content'),
                  '语音语言',
                  index,
                  '${entry['text_reason'] ?? ''}',
                ),
                _copyTextCell(
                  3,
                  text('translation'),
                  '显示语言',
                  index,
                  '${entry['text_reason'] ?? ''}',
                ),
                _cell(4, stingerTime(entry['duration'])),
                SizedBox(
                  width: _columns[5],
                  child: Center(
                    child: _previewButton(
                      'original:${_bank['id']}:$index',
                      _locked
                          ? null
                          : () {
                              select();
                              unawaited(_play('original'));
                            },
                    ),
                  ),
                ),
                GestureDetector(
                  key: ValueKey('voice-replacement-$index'),
                  behavior: HitTestBehavior.opaque,
                  onDoubleTap: _selectingExport || asset == null
                      ? null
                      : () {
                          select();
                          unawaited(_edit());
                        },
                  child: _cell(
                    6,
                    asset == null ? '—' : '${asset['name']}',
                    color: asset == null ? rm.fg4 : rm.accent.base,
                  ),
                ),
                _cell(
                  7,
                  asset == null
                      ? '—'
                      : '${asset['category']} | ${_assets.indexWhere((a) => a['id'] == asset['id']) + 1}',
                ),
                _cell(
                  8,
                  asset == null
                      ? '—'
                      : stingerTime(
                          edit['keep_duration'] == true
                              ? stingerNumber(entry['duration'])
                              : stingerEditedDuration(
                                  edit,
                                  stingerNumber(asset['duration']),
                                ),
                        ),
                  hint: asset == null
                      ? '尚未替换'
                      : edit['keep_duration'] == true
                      ? '保持原时长 ${stingerTime(entry['duration'])}，不足补静音、超出裁剪。'
                      : '使用选段实际时长；游戏事件仍可能提前停止播放。',
                ),
                SizedBox(
                  width: _columns[9],
                  child: asset == null
                      ? const SizedBox.shrink()
                      : Row(
                          children: [
                            _previewButton(
                              'preview:${_bank['id']}:$index',
                              _locked
                                  ? null
                                  : () {
                                      select();
                                      unawaited(_play('preview'));
                                    },
                            ),
                            _toolIcon(
                              'pencil',
                              '编辑替换音频',
                              _locked
                                  ? null
                                  : () {
                                      select();
                                      unawaited(_edit());
                                    },
                            ),
                            _toolIcon(
                              'trash',
                              '删除替换 · Ctrl+Z 撤销',
                              _locked
                                  ? null
                                  : () {
                                      select();
                                      unawaited(_clear());
                                    },
                              danger: true,
                              key: ValueKey('voice-clear-$index'),
                            ),
                          ],
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _changeMap(
    List<Map<String, dynamic>> visible,
    Map<String, dynamic> changes,
  ) {
    final marks = <double>[
      for (var i = 0; i < visible.length; i++)
        if (changes.containsKey('${visible[i]['index']}'))
          (i + .5) / visible.length,
    ];
    return SizedBox(
      width: 14,
      child: LayoutBuilder(
        builder: (context, box) {
          void jump(double y) {
            if (!_entryScroll.hasClients || box.maxHeight <= 0) return;
            var fraction = (y / box.maxHeight).clamp(0.0, 1.0);
            final near = marks
                .where((m) => (m - fraction).abs() * box.maxHeight < 6)
                .toList();
            if (near.isNotEmpty) {
              near.sort(
                (a, b) => (a - fraction).abs().compareTo((b - fraction).abs()),
              );
              fraction = near.first;
            }
            final position = _entryScroll.position;
            _entryScroll.jumpTo(
              (fraction * visible.length * 50 - position.viewportDimension / 2)
                  .clamp(0.0, position.maxScrollExtent),
            );
          }

          return GestureDetector(
            key: const ValueKey('voice-change-map'),
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => jump(d.localPosition.dy),
            onVerticalDragUpdate: (d) => jump(d.localPosition.dy),
            child: AnimatedBuilder(
              animation: _entryScroll,
              builder: (context, _) {
                final p = _entryScroll.hasClients
                    ? _entryScroll.position
                    : null;
                return CustomPaint(
                  size: Size.infinite,
                  painter: _VoiceOverviewPainter(
                    marks,
                    context.rm.accent.base,
                    context.rm.fg4.withAlpha(165),
                    p?.pixels ?? 0,
                    p?.viewportDimension ?? 0,
                    p?.maxScrollExtent ?? 0,
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

/// A slim change rail beside the standard, keyboard-accessible scrollbar.
class _VoiceOverviewPainter extends CustomPainter {
  _VoiceOverviewPainter(
    this.marks,
    this.accent,
    this.thumb,
    this.offset,
    this.viewport,
    this.extent,
  );
  final Color thumb;
  final double offset, viewport, extent;
  final List<double> marks;
  final Color accent;
  @override
  void paint(Canvas canvas, Size size) {
    if (extent > 0 && viewport > 0) {
      final h = math.min(
        size.height,
        math.max(32.0, size.height * viewport / (extent + viewport)),
      );
      final y = offset / extent * (size.height - h);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(7, y, 6, h),
          const Radius.circular(3),
        ),
        Paint()..color = thumb,
      );
    }
    for (final mark in marks) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            1,
            (mark * size.height).clamp(0.0, math.max(0.0, size.height - 3)),
            3,
            3,
          ),
          const Radius.circular(1),
        ),
        Paint()..color = accent,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _VoiceOverviewPainter oldDelegate) =>
      oldDelegate.marks != marks ||
      oldDelegate.accent != accent ||
      oldDelegate.offset != offset ||
      oldDelegate.viewport != viewport ||
      oldDelegate.extent != extent ||
      oldDelegate.thumb != thumb;
}

class _VoiceDrag {
  const _VoiceDrag(this.ids);
  final List<String> ids;
}
