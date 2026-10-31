import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_theme.dart';
import '../theme/text_styles.dart';
import '../theme/tokens.dart';
import 'rm_button.dart';
import 'rm_icon.dart';

/// Compact setting groups shared by import, export and audition dialogs.
class DialogSettingsSection extends StatelessWidget {
  const DialogSettingsSection({
    super.key,
    required this.title,
    required this.child,
  });
  final String title;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        border: Border.all(color: rm.border),
        borderRadius: BorderRadius.circular(RmTokens.rMd),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: RmText.sans(12.5, weight: FontWeight.w600, color: rm.fg),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

/// Shared frame and keyboard dismissal for timing import and export.
class TimingDialogFrame extends StatelessWidget {
  const TimingDialogFrame({
    super.key,
    required this.title,
    required this.busy,
    required this.width,
    required this.body,
    required this.actions,
    this.icon,
    this.description,
    this.closeKey,
    this.footer,
    this.headerActions = const [],
    this.showCloseHint = true,
    this.editorStyle = false,
    this.bodyPadding = const EdgeInsets.all(20),
  });
  final String title;
  final bool busy;
  final double width;
  final Widget body;
  final List<Widget> actions;
  final String? icon;
  final String? description;
  final Key? closeKey;
  final Widget? footer;
  final List<Widget> headerActions;
  final bool showCloseHint;
  final bool editorStyle;
  final EdgeInsetsGeometry bodyPadding;
  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    void close() {
      if (!busy) Navigator.of(context).pop();
    }

    return Theme(
      data: Theme.of(context).copyWith(
        colorScheme: Theme.of(context).colorScheme.copyWith(
          primary: rm.accent.base,
          onPrimary: rm.accent.onAccent,
          surface: rm.panel,
        ),
      ),
      child: PopScope(
        canPop: !busy,
        child: CallbackShortcuts(
          bindings: {const SingleActivator(LogicalKeyboardKey.escape): close},
          child: Focus(
            autofocus: true,
            child: Dialog(
              backgroundColor: rm.panel,
              surfaceTintColor: Colors.transparent,
              insetPadding: const EdgeInsets.all(24),
              clipBehavior: Clip.antiAlias,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(
                  editorStyle ? RmTokens.rXl : RmTokens.rLg,
                ),
                side: BorderSide(color: rm.borderStrong),
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: width,
                  maxHeight:
                      MediaQuery.sizeOf(context).height -
                      (editorStyle ? 48 : 64),
                ),
                child: SizedBox(
                  key: const ValueKey('timing-dialog-panel'),
                  width: width,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: editorStyle
                            ? const EdgeInsets.fromLTRB(16, 13, 14, 12)
                            : const EdgeInsets.fromLTRB(20, 14, 14, 14),
                        child: Row(
                          children: [
                            if (icon != null) ...[
                              Container(
                                width: editorStyle ? 34 : 36,
                                height: editorStyle ? 34 : 36,
                                decoration: BoxDecoration(
                                  color: rm.accent.bg,
                                  border: Border.all(color: rm.accent.ring),
                                  borderRadius: BorderRadius.circular(
                                    RmTokens.rMd,
                                  ),
                                ),
                                child: Center(
                                  child: RmIcon(
                                    icon!,
                                    size: 17,
                                    color: rm.accent.base,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                            ],
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    title,
                                    style: RmText.sans(
                                      icon == null ? 15 : 17,
                                      weight: FontWeight.w600,
                                      color: rm.fg,
                                    ),
                                  ),
                                  if (description != null) ...[
                                    const SizedBox(height: 4),
                                    Text(
                                      description!,
                                      style: RmText.sans(11.5, color: rm.fg3),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            ...[
                              for (final action in headerActions) ...[
                                action,
                                const SizedBox(width: 6),
                              ],
                            ],
                            if (showCloseHint)
                              Text(
                                busy ? '正在处理…' : 'Esc 关闭',
                                style: RmText.mono(10.5, color: rm.fg3),
                              ),
                            if (showCloseHint) const SizedBox(width: 10),
                            RmButton.icon(
                              key: closeKey,
                              onPressed: busy ? null : close,
                              icon: Icon(Icons.close, size: 16, color: rm.fg3),
                              tooltip: '关闭',
                            ),
                          ],
                        ),
                      ),
                      Divider(height: 1, color: rm.border),
                      Flexible(
                        child: SingleChildScrollView(
                          padding: bodyPadding,
                          child: body,
                        ),
                      ),
                      Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: editorStyle ? 12 : 20,
                          vertical: editorStyle ? 10 : 14,
                        ),
                        decoration: BoxDecoration(
                          border: Border(top: BorderSide(color: rm.border)),
                        ),
                        child: LayoutBuilder(
                          builder: (context, box) {
                            final buttons = Wrap(
                              alignment: WrapAlignment.end,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              spacing: 8,
                              runSpacing: 6,
                              children: actions,
                            );
                            if (footer == null) return buttons;
                            if (box.maxWidth >= 820) {
                              return Row(
                                children: [
                                  Expanded(child: footer!),
                                  const SizedBox(width: 14),
                                  buttons,
                                ],
                              );
                            }
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                footer!,
                                const SizedBox(height: 8),
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: buttons,
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
