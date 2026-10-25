import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/app_state.dart';
import '../theme/app_theme.dart';
import 'rm_button.dart';

enum TourPage { welcome, basics, library, song, refine, playlist, settings }

class TourStep {
  const TourStep(
    this.target,
    this.title,
    this.body, {
    this.endTarget,
    this.optional = false,
  });
  final String target;
  final String title;
  final String body;
  final String? endTarget;
  final bool optional;
}

const _steps = <TourPage, List<TourStep>>{
  TourPage.welcome: [
    TourStep('project', '从工程开始', '新建或打开一个工程，用来保存歌曲、时间点和电台排布。'),
    TourStep('help', '边用边了解', '首次进入各页面会介绍核心功能。这里或主界面右上角的问号可重看当前页面介绍。'),
  ],
  TourPage.basics: [
    TourStep('game', '游戏与语言', '选择 FH6 安装目录，并按游戏设置选择显示和语音语言。构建时会使用对应的语言文件。'),
    TourStep('analysis', '分析模式', '无 AI 模式可手动选点；其他档位自动分析时间点，档位越高，通常需要更多时间和资源。'),
    TourStep(
      'sync',
      '同步循环',
      'TL 是比赛中循环，PL 是冲线后循环。开启后，PL 跟随 TL 的起止时间与确认状态；歌曲页也可临时暂停同步。',
    ),
    TourStep('expansion', '电台扩容', '允许加入超过原版槽位数量的歌曲。实验功能，构建和写入后请在游戏中验证。'),
    TourStep(
      'seamless',
      'SeamlessLoopMusic',
      '专注音高与响度衔接，寻找自然的 TL／PL 循环；无需加载重型 AI，无 AI 模式也可用，推荐启用。选点后仍需试听确认。',
    ),
    TourStep(
      'split',
      '分场景编辑',
      '实验功能，需要先开启电台扩容。分别编排漫游与比赛，播放列表也有开关；关闭时保留两套排布，再开启可恢复。',
    ),
    TourStep('workflow', '检查与写入', '这里查看准备状态。完成歌曲和电台排布后，构建准备包，再按提示写入游戏。'),
  ],
  TourPage.library: [
    TourStep('import', '添加歌曲', '导入本地音频；也可批量分析波形和循环建议。'),
    TourStep(
      'browse',
      '查找与迁移',
      '搜索、排序和筛选歌曲，也可批量导入或导出时间点。开启分场景编辑后，可按全部、漫游或比赛筛选分配的歌曲。',
      endTarget: 'browse-end',
    ),
    TourStep(
      'songs',
      '歌曲卡片',
      '查看信息、电台归属和配置进度。仅用于漫游的歌曲可直接构建；用于比赛需完成点位。单击编辑，右侧可试听、分配或删除。',
    ),
  ],
  TourPage.song: [
    TourStep(
      'groups',
      '四组时间点',
      'TD 比赛开始；TL 比赛循环；PD 冲线后起点；PL 冲线后循环。双击卡片或从下方详情精修；仅用于漫游时无需人工确认。',
    ),
    TourStep(
      'waveform',
      '波形与播放',
      '点击波形定位，Ctrl＋滚轮缩放。下方播放按钮用于播放音乐；循环拼接试听在时间组详情和精修中。',
    ),
    TourStep('details', '时间组详情', '查看确认状态，试听当前时间组，或解锁重新选点。可在下方输入时间、按拍或毫秒微调。'),
    TourStep(
      'audition',
      '试听设置',
      '分别设置 TD、PD 的试听时长，以及 TL／PL 拼接前后时长和音量；从下一次试听生效，不改变时间点。',
    ),
    TourStep('side', '分析与快捷键', '这里查看 BPM、循环衔接匹配度和快捷键。匹配度仅供参考，选点后仍应试听确认。'),
    TourStep(
      'save',
      '浏览与保存',
      '上方返回列表或切换歌曲；可编辑歌曲信息、手动校准 BPM 或分配电台。修改后保存，Ctrl＋S 也可保存。',
      endTarget: 'save-start',
    ),
  ],
  TourPage.refine: [
    TourStep('waveform', '放置端点', '点击或拖动波形调整端点；循环可分别选择 A、B。'),
    TourStep('values', '精确微调', '输入时间或使用微调按钮；也可自由放置端点，或提取当前播放位置。'),
    TourStep('audition', '试听设置', '调整播放起点试听时长、循环拼接前后时长和音量。使用旁边的试听按钮检查当前选点。'),
    TourStep(
      'suggestions',
      '套用建议',
      '点击建议载入端点，再试听比较。套用不会自动确认或保存，仍可手动微调。',
      optional: true,
    ),
    TourStep(
      'confirm',
      '快捷键与确认',
      '下方列出当前快捷键：按拍、10ms／1ms 微调，Alt 同移两端，Z 自由放置，Tab 取播放位置。试听后确认，再回歌曲页保存；演示曲练习后可回列表删除。',
    ),
  ],
  TourPage.playlist: [
    TourStep('view', '查看与编辑', '「游戏内」查看当前排布，「准备包」编辑下次构建的内容。'),
    TourStep(
      'split',
      '分场景编辑',
      '实验功能，可分别编排漫游和比赛，概览基础设置也有开关。关闭时选择统一列表并保留两套排布，再开启即可恢复；统一期间的修改不会并入。',
    ),
    TourStep('search', '搜索歌曲', '按歌曲、歌手或文件名搜索；池子可按全部、漫游或比赛筛选已分配的歌曲。'),
    TourStep(
      'layout',
      '电台列数与高度',
      '列数可自动适配或手动调整；高度可按内容、全部电台或一行电台安排，便于在不同屏幕上编辑。',
    ),
    TourStep(
      'board',
      '安排电台',
      '拖动排序或移入电台，池子支持批量分配。分场景时可一键套用另一场景歌单；同一电台不支持一边原版、一边自建。分配窗口数字键选比赛，Ctrl＋数字选漫游。',
    ),
    TourStep(
      'build',
      '保存与构建',
      '保存记录排布和场景快照。仅漫游无需确认比赛点位，构建补默认；同曲任一比赛使用仍需全部确认。构建后到概览写入游戏。',
    ),
  ],
  TourPage.settings: [
    TourStep('look', '外观与布局', '选择主题、强调色和导航位置。设置自动保存。', endTarget: 'look-end'),
    TourStep(
      'size',
      '调整工作区',
      '分别调整主界面与人工精修窗口宽度；支持恢复默认。',
      endTarget: 'size-end',
    ),
    TourStep(
      'help',
      '快捷键与塞壬唱片',
      '修改操作快捷键；启用塞壬唱片后，可从在线唱片库试听和导入歌曲。',
      endTarget: 'help-end',
    ),
  ],
};

// The app entrypoint enables automatic tours. Embedded screens and tests can
// opt in explicitly without unexpectedly opening modal routes.
final automaticFeatureToursProvider = Provider<bool>((ref) => false);
final featureToursProvider = Provider<FeatureTours>((ref) {
  return FeatureTours(ref.watch(sharedPreferencesProvider));
});

class FeatureTours {
  FeatureTours(this.preferences);
  final SharedPreferences preferences;
  final _scopes = <_FeatureTourScopeState>[];
  final _seen = <TourPage>{};
  bool _showing = false;
  bool seen(TourPage page) =>
      _seen.contains(page) || preferences.getBool(_key(page)) == true;
  String _key(TourPage page) => 'rm.tour.v2.${page.name}';

  Future<void> _remember(TourPage page) async {
    _seen.add(page);
    try {
      await preferences.setBool(_key(page), true);
    } on Object catch (error) {
      debugPrint('Could not save feature tour progress: $error');
    }
  }

  Future<void> showCurrent() async {
    if (_showing) return;
    for (final scope in _scopes.reversed) {
      if (scope.mounted && scope.widget.enabled && scope._currentRoute) {
        await scope._show();
        return;
      }
    }
  }
}

class FeatureTourScope extends ConsumerStatefulWidget {
  const FeatureTourScope({
    super.key,
    required this.page,
    required this.child,
    this.enabled = true,
    this.onReveal,
    this.onComplete,
  });
  final TourPage page;
  final Widget child;
  final bool enabled;
  final FutureOr<void> Function(String target)? onReveal;
  final FutureOr<void> Function()? onComplete;
  @override
  ConsumerState<FeatureTourScope> createState() => _FeatureTourScopeState();
}

class _FeatureTourScopeState extends ConsumerState<FeatureTourScope> {
  late final _tours = ref.read(featureToursProvider);
  late final _keys = {
    for (final step in _steps[widget.page]!) ...{
      step.target: GlobalKey(),
      if (step.endTarget != null) step.endTarget!: GlobalKey(),
    },
  };
  bool _scheduled = false;
  bool get _currentRoute => ModalRoute.of(context)?.isCurrent ?? false;

  @override
  void initState() {
    super.initState();
    _tours._scopes.add(this);
  }

  @override
  void dispose() {
    _tours._scopes.remove(this);
    super.dispose();
  }

  Future<void> _show() async {
    if (!mounted || !widget.enabled || !_currentRoute || _tours._showing) {
      return;
    }
    final steps = _steps[widget.page]!
        .where(
          (step) =>
              _keys[step.target]?.currentContext != null ||
              (widget.onReveal != null && !step.optional),
        )
        .toList();
    if (steps.isEmpty) return;
    _tours._showing = true;
    bool? done;
    try {
      done = await showDialog<bool>(
        context: context,
        barrierColor: Colors.transparent,
        barrierDismissible: false,
        builder: (_) => _TourOverlay(
          steps: steps,
          targets: _keys,
          onReveal: widget.onReveal,
        ),
      );
    } finally {
      _tours._showing = false;
    }
    if (done != null) await _tours._remember(widget.page);
    if (done == true && mounted) await widget.onComplete?.call();
  }

  @override
  Widget build(BuildContext context) {
    final current = _currentRoute;
    if (!_scheduled &&
        widget.enabled &&
        current &&
        ref.watch(automaticFeatureToursProvider) &&
        !_tours.seen(widget.page) &&
        !_tours._showing) {
      _scheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // Startup checks may mark the page busy in their first-frame callback.
        // Let that state rebuild before deciding whether to open a modal.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scheduled = false;
          if (mounted && !_tours.seen(widget.page)) {
            unawaited(_show());
          }
        });
        WidgetsBinding.instance.scheduleFrame();
      });
    }
    return _TourTargets(keys: _keys, child: widget.child);
  }
}

class _TourTargets extends InheritedWidget {
  const _TourTargets({required this.keys, required super.child});
  final Map<String, GlobalKey> keys;
  @override
  bool updateShouldNotify(_TourTargets oldWidget) => keys != oldWidget.keys;
}

class TourAnchor extends StatelessWidget {
  const TourAnchor(this.id, {super.key, required this.child});
  final String id;
  final Widget child;
  @override
  Widget build(BuildContext context) => KeyedSubtree(
    key: context.dependOnInheritedWidgetOfExactType<_TourTargets>()?.keys[id],
    child: child,
  );
}

extension FeatureTourWidgets on Widget {
  Widget withFeatureTour(
    TourPage page, {
    bool enabled = true,
    FutureOr<void> Function(String)? onReveal,
    FutureOr<void> Function()? onComplete,
  }) => FeatureTourScope(
    key: ValueKey('feature-tour-${page.name}'),
    page: page,
    enabled: enabled,
    onReveal: onReveal,
    onComplete: onComplete,
    child: this,
  );
  Widget tourAnchor(String id) => TourAnchor(id, child: this);
}

class FeatureTourButton extends ConsumerWidget {
  const FeatureTourButton({super.key, this.iconOnly = false});
  final bool iconOnly;
  @override
  Widget build(BuildContext context, WidgetRef ref) => RmButton(
    label: iconOnly ? null : '功能介绍',
    tooltip: '重新查看当前页面的功能介绍',
    leading: const Icon(Icons.help_outline_rounded, size: 16),
    size: RmButtonSize.sm,
    variant: RmButtonVariant.ghost,
    onPressed: () => unawaited(ref.read(featureToursProvider).showCurrent()),
  );
}

class _TourOverlay extends StatefulWidget {
  const _TourOverlay({
    required this.steps,
    required this.targets,
    this.onReveal,
  });
  final List<TourStep> steps;
  final Map<String, GlobalKey> targets;
  final FutureOr<void> Function(String)? onReveal;
  @override
  State<_TourOverlay> createState() => _TourOverlayState();
}

class _TourOverlayState extends State<_TourOverlay>
    with WidgetsBindingObserver {
  int _index = 0;
  int _generation = 0;
  Rect? _rect;
  final _focus = FocusNode();
  final _surface = GlobalKey();
  final _card = GlobalKey();
  Size _cardSize = const Size(380, 240);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _focus.dispose();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  Future<void> _reveal() async {
    final generation = ++_generation;
    await widget.onReveal?.call(widget.steps[_index].target);
    if (!mounted || generation != _generation) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || generation != _generation) return;
    final target = widget.targets[widget.steps[_index].target]?.currentContext;
    if (target != null && target.mounted) {
      await Scrollable.ensureVisible(
        target,
        duration: const Duration(milliseconds: 180),
        alignment: 0.4,
      );
    }
    if (mounted && generation == _generation) _measure();
  }

  void _measure() {
    if (!mounted) return;
    final surface = _surface.currentContext?.findRenderObject();
    if (surface is! RenderBox || !surface.attached) return;
    Rect? targetRect(String? id) {
      final box = widget.targets[id]?.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) return null;
      return surface.globalToLocal(box.localToGlobal(Offset.zero)) & box.size;
    }

    final step = widget.steps[_index];
    var rect = targetRect(step.target);
    final last = targetRect(step.endTarget);
    if (rect != null && last != null) rect = rect.expandToInclude(last);
    rect = rect?.inflate(5);
    final card = _card.currentContext?.findRenderObject();
    final cardSize = card is RenderBox && card.hasSize ? card.size : _cardSize;
    if (_rect != rect || _cardSize != cardSize) {
      setState(() {
        _rect = rect;
        _cardSize = cardSize;
      });
    }
  }

  void _move(int next) {
    if (next >= widget.steps.length) {
      Navigator.of(context).pop(true);
    } else if (next >= 0) {
      setState(() {
        _index = next;
        _rect = null;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
    }
  }

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final step = widget.steps[_index];
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(false);
      },
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: (_, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          if (event.logicalKey == LogicalKeyboardKey.escape) {
            Navigator.of(context).pop(false);
          } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
            _move(_index + 1);
          } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
            _move(_index - 1);
          } else {
            return KeyEventResult.ignored;
          }
          return KeyEventResult.handled;
        },
        child: LayoutBuilder(
          builder: (context, constraints) {
            WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
            final size = constraints.biggest;
            final bounds = Offset.zero & size;
            final width = math.min(380.0, math.max(0.0, size.width - 32));
            final height = math.min(280.0, math.max(0.0, size.height - 32));
            final cardSize = Size(width, math.min(height, _cardSize.height));
            final rect = featureTourVisibleTarget(
              size,
              _rect?.intersect(bounds),
              cardSize,
            );
            final offset = featureTourCardOffset(size, rect, cardSize);
            return Material(
              color: Colors.transparent,
              child: Stack(
                key: _surface,
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      key: const ValueKey('feature-tour-highlight'),
                      painter: _TourPainter(rect, rm.accent.base),
                    ),
                  ),
                  Positioned(
                    left: offset.dx,
                    top: offset.dy,
                    width: width,
                    child: Container(
                      key: _card,
                      constraints: BoxConstraints(maxHeight: height),
                      decoration: BoxDecoration(
                        color: rm.panel,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: rm.accent.base.withAlpha(140),
                        ),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x33000000),
                            blurRadius: 28,
                            offset: Offset(0, 8),
                          ),
                        ],
                      ),
                      child: SingleChildScrollView(
                        child: Padding(
                          padding: const EdgeInsets.all(18),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '功能介绍  ${_index + 1} / ${widget.steps.length}',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: rm.accent.base,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 10),
                              Text(
                                step.title,
                                semanticsLabel: '功能介绍：${step.title}',
                                style: TextStyle(
                                  fontSize: 18,
                                  color: rm.fg,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                step.body,
                                style: TextStyle(
                                  fontSize: 13,
                                  height: 1.6,
                                  color: rm.fg2,
                                ),
                              ),
                              const SizedBox(height: 16),
                              Wrap(
                                alignment: WrapAlignment.end,
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  RmButton(
                                    label: '跳过本页',
                                    size: RmButtonSize.sm,
                                    variant: RmButtonVariant.ghost,
                                    onPressed: () =>
                                        Navigator.of(context).pop(false),
                                  ),
                                  if (_index > 0)
                                    RmButton(
                                      label: '上一步',
                                      size: RmButtonSize.sm,
                                      onPressed: () => _move(_index - 1),
                                    ),
                                  RmButton(
                                    label: _index == widget.steps.length - 1
                                        ? '知道了'
                                        : '下一步',
                                    size: RmButtonSize.sm,
                                    variant: RmButtonVariant.primary,
                                    onPressed: () => _move(_index + 1),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

@visibleForTesting
Rect? featureTourVisibleTarget(Size viewport, Rect? target, Size card) {
  if (target == null) return null;
  final offset = featureTourCardOffset(viewport, target, card);
  if (!(offset & card).inflate(12).overlaps(target)) return target;
  // A tall board may fill the viewport. Highlight its visible upper portion so
  // the explanation has its own space and does not cover the highlighted area.
  final bottom = math.min(target.bottom, viewport.height - card.height - 28);
  if (bottom > target.top + 40) {
    return Rect.fromLTRB(target.left, target.top, target.right, bottom);
  }
  return target;
}

@visibleForTesting
Offset featureTourCardOffset(Size viewport, Rect? target, Size card) {
  const gap = 12.0;
  const inset = 16.0;
  Offset clamp(Offset point) => Offset(
    point.dx
        .clamp(inset, math.max(inset, viewport.width - card.width - inset))
        .toDouble(),
    point.dy
        .clamp(inset, math.max(inset, viewport.height - card.height - inset))
        .toDouble(),
  );
  if (target == null) {
    return clamp(
      Offset(
        (viewport.width - card.width) / 2,
        (viewport.height - card.height) / 2,
      ),
    );
  }
  if (target.bottom + gap + card.height <= viewport.height - inset) {
    return clamp(Offset(target.left, target.bottom + gap));
  }
  if (target.top - gap - card.height >= inset) {
    return clamp(Offset(target.left, target.top - gap - card.height));
  }
  if (target.right + gap + card.width <= viewport.width - inset) {
    return clamp(
      Offset(target.right + gap, target.center.dy - card.height / 2),
    );
  }
  if (target.left - gap - card.width >= inset) {
    return clamp(
      Offset(
        target.left - gap - card.width,
        target.center.dy - card.height / 2,
      ),
    );
  }
  // When the target fills the screen, place the card at its nearest usable edge.
  return clamp(Offset(target.left, target.bottom - card.height - gap));
}

class _TourPainter extends CustomPainter {
  _TourPainter(this.rect, this.accent);
  final Rect? rect;
  final Color accent;
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size);
    if (rect != null && !rect!.isEmpty) {
      path.addRRect(RRect.fromRectAndRadius(rect!, const Radius.circular(10)));
    }
    canvas.drawPath(path, Paint()..color = const Color(0xA6171B24));
    if (rect != null && !rect!.isEmpty) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect!, const Radius.circular(10)),
        Paint()
          ..color = accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(_TourPainter oldDelegate) =>
      oldDelegate.rect != rect || oldDelegate.accent != accent;
}
