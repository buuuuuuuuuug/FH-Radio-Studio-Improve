import '../core/playlist_action_errors.dart';
import '../widgets/rm_banner.dart';
import '../widgets/timing_dialog_frame.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../theme/app_theme.dart';
import '../theme/text_styles.dart';
import '../theme/tokens.dart';
import '../widgets/rm_button.dart';

enum UnsavedChoice { save, discard }

class PendingEdit {
  PendingEdit({
    required this.label,
    required this.dirty,
    required this.save,
    required this.discard,
    this.discardBlockedReason,
  });
  final String label;
  final bool Function() dirty;
  final FutureOr<void> Function() save;
  final void Function() discard;
  final String? Function()? discardBlockedReason;
}

class UnsavedEdits {
  final entries = <String, PendingEdit>{};
  Future<bool>? _pending;
  bool get isDirty => entries.values.any((e) => e.dirty());
  Future<bool> confirmForBuild(BuildContext context) async {
    if (_pending != null) {
      if (!await _pending! || !context.mounted) return false;
      return confirmForBuild(context);
    }
    final edits = entries.values.where((e) => e.dirty()).toList();
    if (edits.isEmpty) return true;
    return _pending = _saveBeforeBuild(
      context,
      edits,
    ).whenComplete(() => _pending = null);
  }

  Future<bool> _saveBeforeBuild(
    BuildContext context,
    List<PendingEdit> edits,
  ) async {
    var saving = false;
    String? failure;
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => StatefulBuilder(
            builder: (ctx, setState) => TimingDialogFrame(
              title: '构建前保存修改？',
              icon: 'check',
              busy: saving,
              width: 520,
              body: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '${edits.map((e) => e.label).join('、')}尚未保存。保存后将按当前排布构建准备包。',
                    style: RmText.body(color: ctx.rm.fg3),
                  ),
                  if (failure != null) ...[
                    const SizedBox(height: 14),
                    RmBanner(
                      kind: RmBannerKind.danger,
                      title: '尚未开始构建',
                      body: failure!,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '未保存的修改仍留在草稿中。可返回编辑修正，或重试保存。',
                      style: RmText.sans(12, color: ctx.rm.fg3),
                    ),
                  ],
                ],
              ),
              actions: [
                RmButton(
                  key: const ValueKey('build-unsaved-cancel'),
                  label: '返回编辑',
                  onPressed: saving ? null : () => Navigator.pop(ctx, false),
                ),
                RmButton(
                  key: const ValueKey('build-unsaved-save'),
                  label: saving
                      ? '正在保存…'
                      : failure == null
                      ? '保存并继续'
                      : '重试保存',
                  variant: RmButtonVariant.primary,
                  onPressed: saving
                      ? null
                      : () async {
                          setState(() {
                            saving = true;
                            failure = null;
                          });
                          for (final edit in edits) {
                            if (!edit.dirty()) continue;
                            try {
                              await edit.save();
                            } on Object catch (error) {
                              if (ctx.mounted) {
                                setState(() {
                                  saving = false;
                                  failure = playlistActionFailure(
                                    '保存${edit.label}',
                                    error,
                                  );
                                });
                              }
                              return;
                            }
                          }
                          if (ctx.mounted) Navigator.pop(ctx, true);
                        },
                ),
              ],
            ),
          ),
        ) ??
        false;
  }

  Future<bool> confirm(
    BuildContext context, {
    String? key,
    bool exiting = false,
    bool switching = false,
  }) {
    final pending = _pending;
    if (pending != null) {
      // A track navigation prompt may cover fewer edits than a window-close
      // request. Re-check this caller's scope after the active prompt finishes.
      return pending.then((allowed) {
        if (!allowed || !context.mounted) return false;
        return confirm(
          context,
          key: key,
          exiting: exiting,
          switching: switching,
        );
      });
    }
    return _pending = _confirm(
      context,
      key: key,
      exiting: exiting,
      switching: switching,
    ).whenComplete(() => _pending = null);
  }

  Future<bool> _confirm(
    BuildContext context, {
    String? key,
    required bool exiting,
    required bool switching,
  }) async {
    if (!context.mounted) return false;
    final edits = [
      for (final e in entries.entries)
        if ((key == null || e.key == key) && e.value.dirty()) e.value,
    ];
    if (edits.isEmpty) return true;
    final blockedDiscard = [
      for (final edit in edits)
        if (edit.discardBlockedReason?.call() case final String reason) reason,
    ];
    final choice = await showDialog<UnsavedChoice>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ctx.rm.panel,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(RmTokens.rLg),
          side: BorderSide(color: ctx.rm.border),
        ),
        title: Text(
          exiting ? '关闭前保存修改？' : (switching ? '切换歌曲前保存修改？' : '存在未保存的修改'),
          style: RmText.sans(15, weight: FontWeight.w600, color: ctx.rm.fg),
        ),
        content: SizedBox(
          width: 480,
          child: Text(
            [
              '${edits.map((e) => e.label).join('、')}尚未保存。',
              ...blockedDiscard,
            ].join('\n\n'),
            style: RmText.sans(12.5, color: ctx.rm.fg3),
          ),
        ),
        actions: [
          RmButton(
            onPressed: () => Navigator.pop(ctx),
            label: exiting ? '取消关闭' : (switching ? '取消切换' : '取消返回'),
          ),
          RmButton(
            onPressed: blockedDiscard.isNotEmpty
                ? null
                : () => Navigator.pop(ctx, UnsavedChoice.discard),
            label: '放弃更改',
          ),
          RmButton(
            variant: RmButtonVariant.primary,
            onPressed: () => Navigator.pop(ctx, UnsavedChoice.save),
            label: exiting ? '保存并关闭' : (switching ? '保存并切换' : '保存并返回'),
          ),
        ],
      ),
    );
    if (choice == null) return false;
    try {
      for (final edit in edits) {
        if (choice == UnsavedChoice.save) {
          await edit.save();
        } else {
          edit.discard();
        }
      }
      return true;
    } on Object catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${choice == UnsavedChoice.save ? '保存' : '放弃更改'}失败：$e',
            ),
          ),
        );
      }
      return false;
    }
  }
}

final unsavedEditsProvider = Provider<UnsavedEdits>((ref) => UnsavedEdits());
