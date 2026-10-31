import 'dart:convert';

List<Map<String, dynamic>> stingerMaps(Object? value) => value is List
    ? value.whereType<Map>().map((v) => Map<String, dynamic>.from(v)).toList()
    : [];

double stingerNumber(Object? value, [double fallback = 0]) {
  final number = value is num ? value.toDouble() : double.tryParse('$value');
  return number != null && number.isFinite ? number : fallback;
}

String stingerTime(Object? value) {
  final ms = (stingerNumber(value) * 1000).round().clamp(0, 86400000);
  return '${ms ~/ 60000}:${((ms ~/ 1000) % 60).toString().padLeft(2, '0')}.${(ms % 1000).toString().padLeft(3, '0')}';
}

Map<String, dynamic> stingerMap(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : {};
Map<String, dynamic> stingerClone(Map<String, dynamic> value) =>
    jsonDecode(jsonEncode(value)) as Map<String, dynamic>;

class StingerDrag {
  const StingerDrag(this.assetIds, {this.sourceSlot});
  final List<String> assetIds;
  final String? sourceSlot;
}

/// Fixed game positions retain their identity. Moving onto a used slot swaps
/// assignments; copying or dragging a pool asset replaces only the target.
Map<String, dynamic> stingerDropChanges({
  required List<Map<String, dynamic>> slots,
  required List<Map<String, dynamic>> assets,
  required StingerDrag drag,
  required String targetId,
  bool copy = false,
}) {
  final target = slots.indexWhere((s) => s['id'] == targetId);
  if (target < 0) throw const FormatException('目标台呼位置不存在');
  if (drag.sourceSlot == targetId) return {};
  if (drag.sourceSlot != null) {
    final source = slots.where((s) => s['id'] == drag.sourceSlot).firstOrNull;
    final edit = stingerMap(source?['assignment']);
    if (edit.isEmpty) throw const FormatException('拖动的台呼已被清除');
    return {
      targetId: edit,
      if (!copy) drag.sourceSlot!: slots[target]['assignment'],
    };
  }
  // A batch uses the visible target station's subsequent positions, not another station.
  final station = targetId.split(':').first;
  final remaining = slots
      .skip(target)
      .takeWhile((s) => '${s['id']}'.startsWith('$station:'))
      .toList();
  if (drag.assetIds.length > remaining.length) {
    throw const FormatException('剩余台呼位置不足，请减少素材数量或选择更靠前的位置');
  }
  final changes = <String, dynamic>{};
  for (var i = 0; i < drag.assetIds.length; i++) {
    final asset = assets.where((a) => a['id'] == drag.assetIds[i]).firstOrNull;
    if (asset == null) throw const FormatException('素材不存在，请重新选择');
    changes['${remaining[i]['id']}'] = stingerMap(asset['edit']);
  }
  return changes;
}

double stingerEditedDuration(Map<String, dynamic> edit, [double fallback = 0]) {
  var duration =
      stingerNumber(edit['end'], fallback) - stingerNumber(edit['start']);
  for (final operation in stingerMaps(edit['audio_edits'])) {
    if (operation['kind'] == 'insert') {
      duration += stingerNumber(operation['duration']);
    }
    if (operation['kind'] == 'delete') {
      duration -=
          stingerNumber(operation['end']) - stingerNumber(operation['start']);
    }
  }
  return duration;
}
