import 'dart:ui' as ui;
import 'dart:async';
import 'package:flutter/material.dart';
import '../theme/tokens.dart';

/// Like the song's manual-refine overlay, an audio editor belongs to its page.
/// Its local navigator (including any confirmation dialogs) is destroyed when
/// that page is removed. A shell navigation must never leave a pageless editor
/// attached to the next page or rebuild closures from a disposed ConsumerState.
class AudioEditorHost extends StatefulWidget {
  const AudioEditorHost({super.key, required this.child});
  final Widget child;

  @override
  State<AudioEditorHost> createState() => _AudioEditorHostState();
}

class _AudioEditorHostState extends State<AudioEditorHost> {
  WidgetBuilder? _builder;
  Completer<Object?>? _result;
  bool _backdrop = true;

  Future<T?> show<T>(WidgetBuilder builder, bool backdrop) async {
    if (_result != null) return null;
    final result = Completer<Object?>();
    setState(() {
      _builder = builder;
      _backdrop = backdrop;
      _result = result;
    });
    return (await result.future) as T?;
  }

  void _closed(Completer<Object?> result, Object? value) {
    if (!result.isCompleted) result.complete(value);
    if (!mounted || _result != result) return;
    setState(() {
      _result = null;
      _builder = null;
    });
  }

  @override
  void dispose() {
    final result = _result;
    if (result != null && !result.isCompleted) result.complete(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      ExcludeFocus(excluding: _result != null, child: widget.child),
      if (_result case final result?)
        Positioned.fill(
          child: HeroControllerScope.none(
            child: Navigator(
              key: ObjectKey(result),
              onGenerateInitialRoutes: (navigator, _) {
                final route = RawDialogRoute<Object?>(
                  barrierDismissible: false,
                  barrierColor: Colors.transparent,
                  transitionDuration: const Duration(milliseconds: 140),
                  pageBuilder: (context, _, _) =>
                      _editorViewport(context, _builder!, _backdrop),
                );
                unawaited(route.popped.then((value) => _closed(result, value)));
                return [
                  PageRouteBuilder<void>(
                    opaque: false,
                    pageBuilder: (_, _, _) => const SizedBox.expand(),
                  ),
                  route,
                ];
              },
              onGenerateRoute: (_) => null,
            ),
          ),
        ),
    ],
  );
}

/// Shares the song editor's content-area viewport. Shell navigation and title
/// bar stay outside the modal, and all editors use the same width preference.
Future<T?> showAudioEditorDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool backdrop = true,
}) {
  final host = context.findAncestorStateOfType<_AudioEditorHostState>();
  if (host != null) return host.show<T>(builder, backdrop);
  return showGeneralDialog<T>(
    context: context,
    useRootNavigator: false,
    barrierDismissible: false,
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 140),
    pageBuilder: (dialogContext, _, _) =>
        _editorViewport(dialogContext, builder, backdrop),
  );
}

Widget _editorViewport(
  BuildContext dialogContext,
  WidgetBuilder builder,
  bool backdrop,
) => LayoutBuilder(
  builder: (context, box) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(size: Size(box.maxWidth, box.maxHeight)),
    child: ClipRect(
      child: Stack(
        children: [
          if (backdrop)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.maybePop(dialogContext),
                child: BackdropFilter(
                  filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                  child: const ColoredBox(color: RmTokens.modalBackdrop),
                ),
              ),
            ),
          builder(context),
        ],
      ),
    ),
  ),
);
