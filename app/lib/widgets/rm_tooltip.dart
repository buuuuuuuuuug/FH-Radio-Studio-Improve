import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../theme/text_styles.dart';

/// Windows Tooltip/OverlayPortal can leave an orphan AX node inside a scroll
/// view (Flutter #182444). Keep the accessible tooltip on its stable owner;
/// the visual overlay uses an ordinary entry and contributes no extra AX nodes.
class RmTooltip extends StatefulWidget {
  const RmTooltip({
    super.key,
    required this.message,
    required this.child,
    this.waitDuration,
  });
  final String message;
  final Widget child;
  final Duration? waitDuration;
  @override
  State<RmTooltip> createState() => _RmTooltipState();
}

class _RmTooltipState extends State<RmTooltip> {
  final _anchor = GlobalKey();
  Timer? _timer;
  OverlayEntry? _entry;
  void _hide() {
    _timer?.cancel();
    _entry?.remove();
    _entry?.dispose();
    _entry = null;
  }

  void _show() {
    if (!mounted ||
        widget.message.isEmpty ||
        ModalRoute.of(context)?.isCurrent == false) {
      return;
    }
    final box = _anchor.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached) return;
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    final owner = overlay.context.findRenderObject();
    if (owner is! RenderBox) return;
    final point = box.localToGlobal(Offset.zero, ancestor: owner);
    final size = owner.size;
    final theme = Theme.of(context).tooltipTheme;
    final padding =
        theme.padding ??
        const EdgeInsets.symmetric(horizontal: 10, vertical: 6);
    final width = math.max(
      60.0,
      math.min(theme.constraints?.maxWidth ?? 320.0, size.width - 24),
    );
    final style = theme.textStyle ?? RmText.sans(12.5, color: context.rm.fg);
    final message = widget.message.trim();
    final scaler = MediaQuery.textScalerOf(context);
    final span = TextSpan(text: message, style: style);
    final painter = TextPainter(
      text: span,
      textScaler: scaler,
      locale: Localizations.maybeLocaleOf(context),
      textDirection: Directionality.of(context),
    )..layout(maxWidth: width - padding.horizontal);
    // RichText and TextPainter use identical scaling. Reserve a pixel for
    // fractional font advances, otherwise short CJK labels can wrap vertically.
    final contentWidth = (painter.width.ceilToDouble() + 2).clamp(
      0.0,
      width - padding.horizontal,
    );
    final tipWidth = math.max(
          math.min(60.0, width),
          contentWidth + padding.horizontal,
        ),
        height = painter.height + padding.vertical;
    final left = (point.dx + box.size.width / 2 - tipWidth / 2)
        .clamp(8.0, math.max(8.0, size.width - tipWidth - 8))
        .toDouble();
    final gap = theme.verticalOffset ?? 10;
    final above = point.dy - height - gap;
    final top = theme.preferBelow == true || above < 8
        ? math.min(size.height - height - 8, point.dy + box.size.height + gap)
        : above;
    final decoration = theme.decoration;
    _entry?.remove();
    _entry?.dispose();
    _entry = OverlayEntry(
      builder: (context) => Positioned(
        left: left,
        top: top,
        width: tipWidth,
        child: IgnorePointer(
          child: ExcludeSemantics(
            child: Material(
              color: Colors.transparent,
              child: Container(
                decoration: decoration,
                padding: padding,
                child: RichText(
                  text: span,
                  textScaler: scaler,
                  locale: Localizations.maybeLocaleOf(context),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    overlay.insert(_entry!);
  }

  @override
  void didUpdateWidget(RmTooltip old) {
    super.didUpdateWidget(old);
    if (old.message != widget.message) _hide();
  }

  @override
  void dispose() {
    _hide();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) {
      return Tooltip(
        message: widget.message,
        waitDuration: widget.waitDuration,
        child: widget.child,
      );
    }
    return Semantics(
      tooltip: widget.message,
      child: MouseRegion(
        key: _anchor,
        onEnter: (_) {
          _timer?.cancel();
          _timer = Timer(
            widget.waitDuration ??
                Theme.of(context).tooltipTheme.waitDuration ??
                const Duration(milliseconds: 280),
            _show,
          );
        },
        onExit: (_) => _hide(),
        child: Listener(onPointerDown: (_) => _hide(), child: widget.child),
      ),
    );
  }
}
