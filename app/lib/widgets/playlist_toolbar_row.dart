import 'package:flutter/material.dart';

/// Keep view controls together, and move the entire edit/status group together.
class PlaylistToolbarRow extends StatelessWidget {
  const PlaylistToolbarRow({
    super.key,
    required this.leading,
    required this.trailing,
  });
  final Widget leading, trailing;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) => c.maxWidth >= 900
        ? Row(
            children: [
              Expanded(child: leading),
              const SizedBox(width: 16),
              trailing,
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              leading,
              const SizedBox(height: 10),
              Align(alignment: Alignment.centerRight, child: trailing),
            ],
          ),
  );
}
