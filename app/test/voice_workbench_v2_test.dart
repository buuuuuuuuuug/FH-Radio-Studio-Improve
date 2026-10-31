import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:fh_radio_studio/widgets/rm_button.dart';
import 'voice_replacement_test.dart' as base;

Map<String, dynamic> scan() {
  Map<String, dynamic> bank(String id) => {
    'id': id,
    'name': 'VO_$id.assets.bank',
    'relative_path': 'media/audio/FMODBanks/VO_$id.assets.bank',
    'supported': true,
    'sha256': id,
    'replacements': <String, dynamic>{},
  };
  Map<String, dynamic> catalog(String id) => {
    'bank': bank(id),
    'decoded': true,
    'entries': [
      for (var i = 0; i < 50; i++)
        {
          'index': i,
          'name': '$id 条目 ${i + 1}',
          'content': '日本語 $i',
          'translation': '中文 $i',
          'duration': 2.0,
          'channels': 1,
          'frequency': 48000,
        },
    ],
  };
  return {
    'files': [
      for (final id in ['A', 'B'])
        {
          'name': 'VO_$id.assets.bank',
          'path': 'D:/Game/VO_$id.assets.bank',
          'relative_path': 'media/audio/FMODBanks/VO_$id.assets.bank',
          'category': '活动与播报',
          'bank_id': id,
          'size': 1048576,
          'status': '可替换',
        },
    ],
    'plan': {
      'banks': {
        for (final id in ['A', 'B']) id: bank(id),
      },
      'assets': [
        {'id': 'x', 'name': '素材一', 'category': '导航/路线', 'duration': 2.0},
        {'id': 'y', 'name': '素材二', 'category': '导航/路线', 'duration': 2.0},
      ],
      'folders': ['导航', '导航/路线'],
    },
    'catalogs': {'A': catalog('A'), 'B': catalog('B')},
    'active': catalog('A'),
  };
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  for (final width in [1600.0, 990.0, 720.0]) {
    testWidgets('loaded comparison table fits $width', (tester) async {
      final calls = <String>[];
      await base.open(
        tester,
        Size(width, 850),
        calls,
        responder: (a, o) async => a == 'scan' ? scan() : {},
      );
      expect(find.text('原有音频'), findsOneWidget);
      expect(find.text('替换音频'), findsOneWidget);
      expect(find.byKey(const ValueKey('voice-change-map')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('switching prepared resources does not parse or decode again', (
    tester,
  ) async {
    final calls = <String>[];
    await base.open(
      tester,
      const Size(1600, 900),
      calls,
      responder: (a, o) async => a == 'scan' ? scan() : {},
    );
    await tester.tap(find.text('VO_B.assets.bank').first);
    await tester.pumpAndSettle();
    expect(find.text('B 条目 1'), findsOneWidget);
    await tester.tap(find.text('VO_A.assets.bank').first);
    await tester.pumpAndSettle();
    expect(find.text('A 条目 1'), findsOneWidget);
    expect(calls, ['scan']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('three panes and table columns resize without overflow', (
    tester,
  ) async {
    final calls = <String>[];
    await base.open(
      tester,
      const Size(1600, 900),
      calls,
      responder: (a, o) async => a == 'scan' ? scan() : {},
    );
    final divider = find.byKey(const ValueKey('voice-left-divider'));
    final before = tester.getTopLeft(divider).dx;
    await tester.drag(divider, const Offset(60, 0));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(divider).dx - before, closeTo(60, 1));
    final grip = find.byKey(const ValueKey('voice-column-1'));
    final columnBefore = tester.getCenter(grip).dx;
    await tester.drag(grip, const Offset(50, 0));
    await tester.pumpAndSettle();
    expect(tester.getCenter(grip).dx - columnBefore, closeTo(50, 1));
    await tester.tap(grip);
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tap(grip);
    await tester.pumpAndSettle();
    expect(tester.getCenter(grip).dx, closeTo(columnBefore, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'preview controls keep their size and default columns fill the table',
    (tester) async {
      final calls = <String>[];
      await base.open(
        tester,
        const Size(2000, 900),
        calls,
        responder: (a, o) async => a == 'scan' ? scan() : {},
      );
      final groups = tester.getRect(
        find.byKey(const ValueKey('voice-table-groups')),
      );
      final map = tester.getRect(
        find.byKey(const ValueKey('voice-change-map')),
      );
      expect(groups.right, closeTo(map.left, 1));
      final preview = find.byKey(const ValueKey('voice-play-original:A:0'));
      final original = tester.getSize(preview);
      await tester.drag(
        find.byKey(const ValueKey('voice-comparison-divider')),
        const Offset(90, 0),
      );
      await tester.pumpAndSettle();
      expect(tester.getSize(preview), original);
      expect(original, const Size(26, 26));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a large catalog scrolls while keeping only visible rows built', (
    tester,
  ) async {
    final calls = <String>[];
    final data = scan();
    final catalog = Map<String, dynamic>.from((data['catalogs'] as Map)['A']);
    catalog['entries'] = [
      for (var i = 0; i < 7100; i++)
        {
          'index': i,
          'name': '导航 $i',
          'duration': 2.0,
          'channels': 1,
          'frequency': 48000,
        },
    ];
    data['active'] = catalog;
    (data['catalogs'] as Map)['A'] = catalog;
    await base.open(
      tester,
      const Size(1600, 900),
      calls,
      responder: (a, o) async => a == 'scan' ? data : {},
    );
    await tester.drag(find.byType(ListView), const Offset(0, -1400));
    await tester.pumpAndSettle();
    expect(
      find
          .byWidgetPredicate(
            (w) =>
                w.key is ValueKey<String> &&
                (w.key as ValueKey<String>).value.startsWith('voice-entry-'),
          )
          .evaluate()
          .length,
      lessThan(40),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'text export selects audio entries in the middle table and previews chosen fields',
    (tester) async {
      final calls = <String>[];
      Map<String, dynamic>? exportOptions;
      await base.open(
        tester,
        const Size(1500, 900),
        calls,
        responder: (a, o) async {
          if (a == 'scan') return scan();
          if (a == 'export-text') {
            exportOptions = Map<String, dynamic>.from(o['input']);
            return {
              'headers': ['序号', '条目', '语音语言', '显示语言', '时长（秒）'],
              'rows': [
                ['1', '导航文本预览', 'Turn left', '请左转', '2.000'],
              ],
              'count': 1,
              'plan': scan()['plan'],
            };
          }
          return {};
        },
      );
      await tester.tap(find.byKey(const ValueKey('voice-export-text')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('voice-entry-0')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('voice-export-selected-text')),
      );
      await tester.pumpAndSettle();
      expect(find.text('导出语音文本'), findsOneWidget);
      expect(find.text('生成预览'), findsNothing);
      expect(exportOptions!['sources'], ['D:/Game/VO_A.assets.bank']);
      expect(exportOptions!['indices'], [0]);
      expect(find.textContaining('导航文本预览'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('CSV export offers a structured table preview', (tester) async {
    final calls = <String>[];
    await base.open(
      tester,
      const Size(1600, 950),
      calls,
      responder: (a, o) async {
        if (a == 'scan') return scan();
        if (a == 'export-text') {
          return {
            'text': '示例文本',
            'count': 1,
            'headers': ['序号', '条目', '语音语言', '显示语言', '时长（秒）'],
            'rows': [
              ['1', '条目一', '日本語', '中文台词', '2.000'],
            ],
            'csv': '资源文件,序号,内容\r\nVO_A.assets.bank,1,中文台词',
            'table_text': '资源文件\t序号\t内容',
            'plan': scan()['plan'],
          };
        }
        return {};
      },
    );
    await tester.tap(find.byKey(const ValueKey('voice-export-text')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('voice-entry-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('voice-export-selected-text')));
    await tester.pumpAndSettle();
    expect(find.text('生成预览'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('voice-export-format')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('表格 CSV').last);
    await tester.pumpAndSettle();
    expect(find.text('中文台词'), findsOneWidget);
    await tester.tap(
      find
          .descendant(of: find.byType(Dialog), matching: find.text('显示语言'))
          .first,
    );
    await tester.pumpAndSettle();
    expect(find.text('中文台词'), findsNothing);
    expect(calls.where((c) => c == 'export-text').length, 1);
    expect(find.widgetWithText(RmButton, '导出 CSV'), findsOneWidget);
    expect(find.widgetWithText(RmButton, '复制表格'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a material folder is created directly without a modal', (
    tester,
  ) async {
    final calls = <String>[];
    Map<String, dynamic>? request;
    await base.open(
      tester,
      const Size(1600, 950),
      calls,
      responder: (a, o) async {
        if (a == 'scan') return scan();
        if (a == 'folders') {
          request = Map<String, dynamic>.from(o['input']);
          return {'plan': scan()['plan']};
        }
        return {};
      },
    );
    await tester.tap(find.byKey(const ValueKey('voice-new-folder')));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(request!['name'], '新建文件夹');
    expect(request!['action'], 'create');
    expect(tester.takeException(), isNull);
  });

  testWidgets('build preview and adjacent deployment use only voice actions', (
    tester,
  ) async {
    final calls = <String>[];
    await base.open(
      tester,
      const Size(1500, 900),
      calls,
      responder: (a, o) async {
        if (a == 'scan') return scan();
        if (a == 'build-preview') {
          return {
            'files': [
              {'name': 'VO_A.assets.bank', 'replaced': 1},
            ],
          };
        }
        if (a == 'build') return {'built': true};
        if (a == 'deployment-preview') {
          return {'schema_version': 1, 'writes': [], 'removals': []};
        }
        return {};
      },
    );
    await tester.tap(find.byKey(const ValueKey('voice-build')));
    await tester.pumpAndSettle();
    expect(find.text('构建语音准备包'), findsOneWidget);
    expect(find.textContaining('不包含歌曲、台呼或 RadioInfo'), findsOneWidget);
    await tester.tap(find.widgetWithText(RmButton, '开始构建'));
    await tester.pumpAndSettle();
    expect(calls, containsAllInOrder(['build-preview', 'build']));
    await tester.tap(find.byKey(const ValueKey('voice-deploy')));
    await tester.pumpAndSettle();
    expect(find.text('写入语音准备包'), findsOneWidget);
    expect(calls.last, 'deployment-preview');
    expect(calls, isNot(contains('deploy')));
    expect(tester.takeException(), isNull);
  });
}
