import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'rm_icon.dart';

/// Windows Explorer drops use logical coordinates in the Flutter client area.
/// The most specific visible target wins; hidden routes never receive files.
class ExternalAudioDropTarget extends StatefulWidget {
  const ExternalAudioDropTarget({
    super.key,
    required this.child,
    required this.onDrop,
    this.enabled = true,
    this.label = '松开以导入音频',
    this.leftInset = 0,
  });
  final Widget child;
  final bool enabled;
  final String label;
  final double leftInset;
  final Future<void> Function(List<String>) onDrop;
  @override
  State<ExternalAudioDropTarget> createState() =>
      _ExternalAudioDropTargetState();
}

class _ExternalAudioDropTargetState extends State<ExternalAudioDropTarget> {
  static const _channel = MethodChannel('fh_radio_studio/file_drop');
  static final _targets = <_ExternalAudioDropTargetState>{};
  static bool _installed = false;
  static _ExternalAudioDropTargetState? _hovered;
  bool _over = false;

  static void _hover(_ExternalAudioDropTargetState? next) {
    if (identical(next, _hovered)) return;
    final previous = _hovered;
    _hovered = next;
    if (previous?.mounted == true) {
      previous!.setState(() => previous._over = false);
    }
    if (next?.mounted == true) next!.setState(() => next._over = true);
  }

  @override
  void initState() {
    super.initState();
    _targets.add(this);
    if (!_installed) {
      _installed = true;
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'filesExited') {
          _hover(null);
          return false;
        }
        if (!const {
          'filesEntered',
          'filesMoved',
          'filesDropped',
        }.contains(call.method)) {
          return false;
        }
        final data = Map<Object?, Object?>.from(call.arguments as Map);
        final point = Offset(
          (data['x'] as num).toDouble(),
          (data['y'] as num).toDouble(),
        );
        final paths = (data['paths'] as List).whereType<String>().toList();
        final hit = HitTestResult();
        GestureBinding.instance.hitTestInView(
          hit,
          point,
          WidgetsBinding.instance.platformDispatcher.views.first.viewId,
        );
        final matches = <(_ExternalAudioDropTargetState, double)>[];
        for (final target in _targets.toList()) {
          if (!target.mounted ||
              !target.widget.enabled ||
              ModalRoute.of(target.context)?.isCurrent == false) {
            continue;
          }
          final box = target.context.findRenderObject();
          if (box is! RenderBox || !box.attached || !box.hasSize) continue;
          if (!hit.path.any((entry) => entry.target == box)) continue;
          if (Rect.fromLTRB(
            target.widget.leftInset,
            0,
            box.size.width,
            box.size.height,
          ).contains(box.globalToLocal(point))) {
            matches.add((target, box.size.width * box.size.height));
          }
        }
        matches.sort((a, b) => a.$2.compareTo(b.$2));
        if (call.method != 'filesDropped') {
          _hover(paths.isEmpty ? null : matches.firstOrNull?.$1);
          return matches.isNotEmpty && paths.isNotEmpty;
        }
        _hover(null);
        if (matches.isEmpty || paths.isEmpty) return false;
        await matches.first.$1.widget.onDrop(paths);
        return true;
      });
    }
  }

  @override
  void didUpdateWidget(covariant ExternalAudioDropTarget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && identical(_hovered, this)) {
      _hovered = null;
      _over = false;
    }
  }

  @override
  void dispose() {
    _targets.remove(this);
    if (identical(_hovered, this)) _hovered = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    child: Stack(
      fit: StackFit.passthrough,
      children: [
        widget.child,
        if (_over &&
            widget.enabled &&
            ModalRoute.of(context)?.isCurrent != false)
          Positioned.fill(
            left: widget.leftInset,
            child: IgnorePointer(
              child: LayoutBuilder(
                builder: (context, box) {
                  final rm = context.rm;
                  final compact = box.maxHeight < 90;
                  return Container(
                    key: const ValueKey('external-audio-drop-hint'),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Color.alphaBlend(
                        rm.accent.bg,
                        rm.panel,
                      ).withAlpha(245),
                      border: Border.all(color: rm.accent.base, width: 2),
                      borderRadius: BorderRadius.circular(RmTokens.rLg),
                    ),
                    child: Center(
                      child: compact
                          ? Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                RmIcon(
                                  'import',
                                  size: 15,
                                  color: rm.accent.base,
                                ),
                                const SizedBox(width: 7),
                                Flexible(
                                  child: Text(
                                    widget.label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: rm.accent.base,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            )
                          : Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                RmIcon(
                                  'import',
                                  size: 27,
                                  color: rm.accent.base,
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  widget.label,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: rm.accent.base,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 5),
                                Text(
                                  '支持多个音频文件，原文件保留',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(fontSize: 11, color: rm.fg2),
                                ),
                              ],
                            ),
                    ),
                  );
                },
              ),
            ),
          ),
      ],
    ),
  );
}
