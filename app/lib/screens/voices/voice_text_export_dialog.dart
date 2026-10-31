import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../theme/app_theme.dart';
import '../../theme/text_styles.dart';
import '../../theme/tokens.dart';
import '../../widgets/rm_button.dart';
import '../../widgets/rm_icon.dart';
import '../../widgets/rm_select.dart';
import '../../widgets/timing_dialog_frame.dart';

/// Presents structured CLI rows; it never reads or resolves game metadata.
class VoiceTextExportDialog extends StatefulWidget {
  const VoiceTextExportDialog({
    super.key,
    required this.name,
    required this.count,
    required this.load,
    required this.xlsx,
    required this.tablePreview,
    required this.notify,
    required this.onExported,
  });
  final String name;
  static String fileName(String resource, String format) =>
      '${resource.split(RegExp(r'[/\\]')).last.replaceAll(RegExp(r'[<>:"|?*]'), '_')}_语音文本导出.$format';
  final int count;
  final Future<Map<String, dynamic>> Function() load;
  final Future<List<int>> Function(List<String> fields, bool matchedOnly) xlsx;
  final Widget Function(BuildContext, List<String>, List<List<String>>)
  tablePreview;
  final ValueChanged<String> notify;
  final VoidCallback onExported;
  @override
  State<VoiceTextExportDialog> createState() => _VoiceTextExportDialogState();
}

class _VoiceTextExportDialogState extends State<VoiceTextExportDialog> {
  static const fields = {
    'name': '条目名称',
    'content': '语音语言',
    'translation': '显示语言',
    'duration': '时长',
  };
  final _selected = fields.keys.toSet();
  List<String> _headers = [];
  List<List<String>> _rows = [];
  String _format = 'txt';
  bool _matched = false, _loading = true, _saving = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final result = await widget.load();
      if (!mounted) return;
      setState(() {
        _headers = (result['headers'] as List? ?? []).map((v) => '$v').toList();
        _rows = (result['rows'] as List? ?? [])
            .whereType<List>()
            .map((r) => r.map((v) => '$v').toList())
            .toList();
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  List<int> get _columns => [
    0,
    for (var i = 0; i < fields.length; i++)
      if (_selected.contains(fields.keys.elementAt(i))) i + 1,
  ];
  List<List<String>> get _projectedRows => [
    for (final r in _rows)
      if (!_matched ||
          (r.length > 3 && (r[2].trim().isNotEmpty || r[3].trim().isNotEmpty)))
        [for (final i in _columns) i < r.length ? r[i] : ''],
  ];
  List<String> get _projectedHeaders => [
    for (final i in _columns) i < _headers.length ? _headers[i] : '',
  ];
  String _delimited(String separator) {
    String cell(String v) {
      if (RegExp(r'^\s*[=+@-]').hasMatch(v)) {
        v = "'$v";
      }
      return v.contains(separator) ||
              v.contains('"') ||
              v.contains('\n') ||
              v.contains('\r')
          ? '"${v.replaceAll('"', '""')}"'
          : v;
    }

    return [
      _projectedHeaders,
      ..._projectedRows,
    ].map((r) => r.map(cell).join(separator)).join('\r\n');
  }

  String get _text {
    final rows = _projectedRows, columns = _projectedHeaders;
    final out = <String>['【${widget.name}】', columns.join('\t'), ''];
    for (final row in rows) {
      out.add(
        row.map((v) => v.replaceAll(RegExp(r'[\t\r\n]'), ' ')).join('\t'),
      );
    }
    return out.join('\n');
  }

  Future<void> _save() async {
    final format = _format,
        fields = _VoiceTextExportDialogState.fields.keys
            .where(_selected.contains)
            .toList(),
        matched = _matched;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final path = await FilePicker.saveFile(
        dialogTitle: '导出语音文本',
        fileName: VoiceTextExportDialog.fileName(widget.name, format),
        type: FileType.custom,
        allowedExtensions: [format],
      );
      if (path == null) return;
      final file = File(
        path.toLowerCase().endsWith('.$format') ? path : '$path.$format',
      );
      if (format == 'xlsx') {
        await file.writeAsBytes(
          await widget.xlsx(fields, matched),
          flush: true,
        );
      } else {
        await file.writeAsString(
          format == 'csv' ? '\uFEFF${_delimited(',')}' : _text,
          encoding: utf8,
          flush: true,
        );
      }
      widget.onExported();
      widget.notify('语音文本已导出。');
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _option(String label, bool value, ValueChanged<bool> change) =>
      InkWell(
        onTap: _saving ? null : () => change(!value),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            children: [
              SizedBox(
                width: 22,
                height: 22,
                child: Checkbox(
                  value: value,
                  onChanged: _saving ? null : (v) => change(v == true),
                  activeColor: context.rm.accent.base,
                  visualDensity: VisualDensity.compact,
                  side: BorderSide(color: context.rm.fg4),
                ),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  label,
                  style: RmText.sans(12, color: context.rm.fg2),
                ),
              ),
            ],
          ),
        ),
      );
  @override
  Widget build(BuildContext context) {
    final ready =
        !_loading && !_saving && _selected.isNotEmpty && _headers.isNotEmpty;
    final rows = _projectedRows;
    final options = DialogSettingsSection(
      title: '导出选项',
      child: Wrap(
        spacing: 12,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: 180,
            child: RmSelect<String>(
              key: const ValueKey('voice-export-format'),
              value: _format,
              items: const {
                'txt': '文本 TXT',
                'csv': '表格 CSV',
                'xlsx': '工作簿 XLSX',
              },
              onChanged: _saving ? null : (v) => setState(() => _format = v),
            ),
          ),
          for (final f in fields.entries)
            SizedBox(
              width: f.key == 'duration' ? 68 : 110,
              child: _option(
                f.value,
                _selected.contains(f.key),
                (v) => setState(() {
                  if (v) {
                    _selected.add(f.key);
                  } else {
                    _selected.remove(f.key);
                  }
                }),
              ),
            ),
          SizedBox(
            width: 220,
            child: _option(
              '仅包含已找到文本的条目',
              _matched,
              (v) => setState(() => _matched = v),
            ),
          ),
        ],
      ),
    );
    final preview = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              '实时预览',
              style: RmText.sans(
                13,
                weight: FontWeight.w600,
                color: context.rm.fg,
              ),
            ),
            const Spacer(),
            Text(
              '${rows.length} 条',
              style: RmText.mono(11, color: context.rm.fg3),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          key: const ValueKey('voice-export-preview'),
          height: _loading
              ? 130
              : _format == 'txt'
              ? (_text.split('\n').length * 19.0 + 24).clamp(100.0, 260.0)
              : ((rows.length.clamp(0, 6) + 1) * 44.0 + 12).clamp(100.0, 300.0),
          decoration: BoxDecoration(
            color: context.rm.raised,
            border: Border.all(color: context.rm.border),
            borderRadius: BorderRadius.circular(RmTokens.rMd),
          ),
          clipBehavior: Clip.antiAlias,
          child: _loading
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : _error != null
              ? Center(
                  child: Text(
                    _error!,
                    style: RmText.sans(12, color: context.rm.danger),
                  ),
                )
              : _selected.isEmpty
              ? Center(
                  child: Text(
                    '至少选择一个导出字段',
                    style: RmText.sans(12, color: context.rm.fg3),
                  ),
                )
              : _format == 'txt'
              ? SingleChildScrollView(
                  padding: const EdgeInsets.all(12),
                  child: SelectableText(
                    _text.split('\n').take(100).join('\n'),
                    style: RmText.sans(
                      11.5,
                      color: context.rm.fg2,
                      height: 1.6,
                    ),
                  ),
                )
              : widget.tablePreview(context, _projectedHeaders, rows),
        ),
        const SizedBox(height: 7),
        Text(
          _format == 'txt'
              ? '预览前 100 行；文件包含全部结果，使用 UTF-8。'
              : '预览前 20 条；文件包含全部结果。',
          style: RmText.sans(11, color: context.rm.fg3),
        ),
      ],
    );
    return TimingDialogFrame(
      title: '导出语音文本',
      icon: 'export',
      width: 1020,
      busy: _saving,
      description: '已选择 ${widget.count} 条音频 · ${widget.name}',
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [options, const SizedBox(height: 14), preview],
      ),
      actions: [
        RmButton(
          label: '关闭',
          onPressed: _saving ? null : () => Navigator.pop(context),
        ),
        RmButton(
          label: _format == 'txt' ? '复制文本' : '复制表格',
          leading: const RmIcon('copy', size: 12),
          onPressed: !ready
              ? null
              : () async {
                  await Clipboard.setData(
                    ClipboardData(
                      text: _format == 'txt' ? _text : _delimited('\t'),
                    ),
                  );
                  widget.notify('语音文本已复制。');
                },
        ),
        RmButton(
          label: '导出 ${_format.toUpperCase()}',
          leading: const RmIcon('export', size: 12),
          variant: RmButtonVariant.primary,
          onPressed: ready ? _save : null,
        ),
      ],
    );
  }
}
