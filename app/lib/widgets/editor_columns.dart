import 'dart:math' as math;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// The main editor determines the side panel's height in the same layout pass.
/// This works with waveforms/LayoutBuilders without intrinsic measurements or
/// a post-frame resize. A tall side panel should scroll inside this height.
class EditorColumns extends MultiChildRenderObjectWidget {
  EditorColumns({
    super.key,
    required Widget main,
    required Widget side,
    this.sideWidth = 264,
    this.gap = 12,
  }) : super(children: [main, side]);
  final double sideWidth, gap;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _EditorColumnsBox(sideWidth, gap);
  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderBox renderObject,
  ) => (renderObject as _EditorColumnsBox).configure(sideWidth, gap);
}

class _EditorColumnParentData extends ContainerBoxParentData<RenderBox> {}

class _EditorColumnsBox extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _EditorColumnParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _EditorColumnParentData> {
  _EditorColumnsBox(this.sideWidth, this.gap);
  double sideWidth, gap;
  void configure(double width, double spacing) {
    if (sideWidth == width && gap == spacing) return;
    sideWidth = width;
    gap = spacing;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _EditorColumnParentData) {
      child.parentData = _EditorColumnParentData();
    }
  }

  @override
  void performLayout() {
    final main = firstChild!, side = childAfter(main)!;
    final width = constraints.maxWidth;
    final mainWidth = math.max(0.0, width - sideWidth - gap);
    main.layout(
      BoxConstraints.tightFor(width: mainWidth),
      parentUsesSize: true,
    );
    side.layout(
      BoxConstraints.tightFor(width: sideWidth, height: main.size.height),
      parentUsesSize: true,
    );
    (main.parentData! as _EditorColumnParentData).offset = Offset.zero;
    (side.parentData! as _EditorColumnParentData).offset = Offset(
      mainWidth + gap,
      0,
    );
    size = constraints.constrain(Size(width, main.size.height));
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);
  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
