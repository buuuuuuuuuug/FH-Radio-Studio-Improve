import 'package:flutter/material.dart';
import 'pending_gate.dart';

void showAudioImportResult(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

extension AudioImportProgress on Widget {
  Widget withAudioImportProgress({required int count, required String noun}) =>
      PendingGate(
        pending: count > 0,
        label: '正在导入 $count 个$noun',
        detail: '正在读取音频并转换试听副本，原文件保留。完成后即可试听或编辑。',
        overlayKey: const ValueKey('audio-import-progress'),
        borderRadius: BorderRadius.zero,
        child: this,
      );
}
