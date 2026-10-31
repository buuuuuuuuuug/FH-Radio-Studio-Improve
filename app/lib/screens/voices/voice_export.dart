part of '../voice_replacement.dart';

extension _VoiceExport on _VoiceReplacementState {
  Future<void> _extractOriginalAssets() async {
    if (_locked || !_readyFile || _exportEntries.isEmpty) return;
    final bank = '${_bank['id']}', indices = _exportEntries.toList()..sort();
    var category = _assetCategory == '全部分类' ? '原音频' : _assetCategory;
    final accepted = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => TimingDialogFrame(
          title: '加入素材池',
          icon: 'volume',
          width: 520,
          busy: false,
          description: '${indices.length} 条原音频 · 保留完整时长',
          body: DialogSettingsSection(
            title: '目标文件夹',
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                RmSelect<String>(
                  key: const ValueKey('voice-extract-folder'),
                  value: category,
                  items: {
                    for (final f in ({
                      '原音频',
                      ..._assetFolders,
                    }.toList()..sort()))
                      f: f.replaceAll('/', ' / '),
                  },
                  onChanged: (v) => update(() => category = v),
                ),
                const SizedBox(height: 9),
                Text(
                  '复用已有试听缓存；重复素材保留原名称、文件夹和编辑设置。',
                  style: RmText.sans(11.5, color: ctx.rm.fg3),
                ),
              ],
            ),
          ),
          actions: [
            RmButton(label: '取消', onPressed: () => Navigator.pop(ctx)),
            RmButton(
              key: const ValueKey('voice-extract-confirm'),
              label: '加入素材池',
              leading: const RmIcon('plus', size: 12),
              variant: RmButtonVariant.primary,
              onPressed: () => Navigator.pop(ctx, category),
            ),
          ],
        ),
      ),
    );
    if (accepted == null || !mounted) return;
    await _guard(() async {
      _update(() => _busyText = '正在将 ${indices.length} 条原音频加入素材池…');
      final result = await _call('extract-assets', {
        'bank': bank,
        'input': {'indices': indices, 'category': accepted},
      });
      _update(() {
        _hydrate(stingerMap(result['plan']));
        _selectedAssets
          ..clear()
          ..addAll(List<String>.from(result['asset_ids'] ?? []));
        _selectedAsset = _selectedAssets.firstOrNull;
        _selectingAssets = _selectedAssets.length > 1;
        _assetCategory = accepted;
        for (final a in _assets.where(
          (a) => _selectedAssets.contains(a['id']),
        )) {
          final parts = '${a['category']}'.split('/');
          for (var n = 1; n <= parts.length; n++) {
            _openAssetFolders.add(parts.take(n).join('/'));
          }
        }
        for (final e in stingerMap(result['preview_paths']).entries) {
          _previewPaths['asset:${e.key}'] = '${e.value}';
        }
        _selectingExport = false;
        _exportEntries.clear();
        _notice =
            '已处理 ${result['count']} 条原音频，新增 ${result['added']} 条素材${stingerNumber(result['reused']) > 0 ? '，复用 ${result['reused']} 条已有素材' : ''}。';
      });
    });
  }

  Future<void> _exportText() async {
    if (!_readyFile || _pending == null || _exportEntries.isEmpty) return;
    final source = _pending!['path'], bank = _bank['id'];
    final indices = _exportEntries.toList()..sort();
    Future<Map<String, dynamic>> render(
      List<String> fields,
      bool matched, [
      String? format,
    ]) => _call('export-text', {
      'input': {
        'sources': [source],
        'bank_id': bank,
        'indices': indices,
        'fields': fields,
        'matched_only': matched,
        'format': ?format,
      },
    });
    await showDialog<void>(
      context: context,
      builder: (ctx) => VoiceTextExportDialog(
        name: '${_bank['name']}',
        count: indices.length,
        load: () =>
            render(['name', 'content', 'translation', 'duration'], false),
        xlsx: (fields, matched) async => base64Decode(
          '${(await render(fields, matched, 'xlsx'))['xlsx_base64']}',
        ),
        tablePreview: _csvPreview,
        notify: _toast,
        onExported: () {
          if (mounted) _update(() => _selectingExport = false);
        },
      ),
    );
  }

  Widget _csvPreview(
    BuildContext ctx,
    List<String> headers,
    List<List<String>> rows,
  ) {
    if (headers.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Text('请重新生成预览。', style: RmText.sans(12, color: ctx.rm.fg3)),
      );
    }
    final widths = <int, TableColumnWidth>{
      for (var i = 0; i < headers.length; i++)
        i: FixedColumnWidth(
          headers[i] == '序号'
              ? 60
              : headers[i].contains('时长')
              ? 90
              : 230,
        ),
    };
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: widths.values.fold<double>(
          0,
          (v, w) => v + (w as FixedColumnWidth).value,
        ),
        child: SingleChildScrollView(
          child: Table(
            columnWidths: widths,
            border: TableBorder(
              horizontalInside: BorderSide(color: ctx.rm.border),
              verticalInside: BorderSide(color: ctx.rm.border),
            ),
            children: [
              TableRow(
                decoration: BoxDecoration(color: ctx.rm.hover),
                children: [
                  for (final label in headers)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 9,
                      ),
                      child: Text(
                        label,
                        style: RmText.sans(
                          11.5,
                          color: ctx.rm.fg,
                          weight: FontWeight.w600,
                        ),
                      ),
                    ),
                ],
              ),
              for (final row in rows.take(20))
                TableRow(
                  children: [
                    for (var i = 0; i < headers.length; i++)
                      RmTooltip(
                        message: i < row.length ? row[i] : '',
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          child: Text(
                            i < row.length ? row[i] : '',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: RmText.sans(
                              11.5,
                              color: ctx.rm.fg2,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
