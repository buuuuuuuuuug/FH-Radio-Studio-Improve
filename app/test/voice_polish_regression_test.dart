import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:fh_radio_studio/widgets/rm_button.dart';
import 'package:fh_radio_studio/widgets/rm_select.dart';
import 'voice_replacement_test.dart' as base;
import 'voice_workbench_v2_test.dart' as data;

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  testWidgets('large catalog numbers stay on one line at the end of the list', (
    t,
  ) async {
    final snapshot = data.scan();
    snapshot['catalogs']['A']['entries'] = [
      for (var i = 0; i < 7100; i++)
        {'index': i, 'name': '导航 $i', 'duration': 2.0},
    ];
    snapshot['active'] = snapshot['catalogs']['A'];
    await base.open(
      t,
      const Size(1600, 900),
      [],
      responder: (a, o) async => a == 'scan' ? snapshot : {},
    );
    final list = t.widget<ListView>(
      find.byKey(const ValueKey('voice-entry-viewport')),
    );
    list.controller!.jumpTo(list.controller!.position.maxScrollExtent);
    await t.pumpAndSettle();
    expect(t.getSize(find.text('7100')).height, lessThan(20));
    expect(t.takeException(), isNull);
  });

  for (final width in [720.0, 1600.0, 2200.0]) {
    testWidgets('scrollbar and change rail match the list viewport at $width', (
      t,
    ) async {
      await base.open(
        t,
        Size(width, 900),
        [],
        responder: (a, o) async => a == 'scan' ? data.scan() : {},
      );
      final list = t.getRect(
        find.byKey(const ValueKey('voice-entry-viewport')),
      );
      final bar = t.getRect(find.byKey(const ValueKey('voice-entry-viewport')));
      final rail = t.getRect(find.byKey(const ValueKey('voice-change-map')));
      expect(bar.top, closeTo(list.top, .01));
      expect(bar.bottom, closeTo(list.bottom, .01));
      expect(rail.top, closeTo(list.top, .01));
      expect(rail.bottom, closeTo(list.bottom, .01));
      expect(t.takeException(), isNull);
    });
  }

  for (final width in [550.0, 720.0, 990.0, 1600.0]) {
    testWidgets(
      'material selection actions remain equal and on one row at $width',
      (t) async {
        await base.open(
          t,
          Size(width, 900),
          [],
          responder: (a, o) async => a == 'scan' ? data.scan() : {},
        );
        await t.tap(find.byKey(const ValueKey('voice-pool-multiselect')));
        await t.pumpAndSettle();
        final rects = [
          for (final key in [
            'voice-material-select-all',
            'voice-material-clear-selection',
            'voice-material-move',
          ])
            t.getRect(find.byKey(ValueKey(key))),
        ];
        for (final rect in rects.skip(1)) {
          expect(rect.top, closeTo(rects.first.top, .01));
          expect(rect.width, closeTo(rects.first.width, .01));
        }
        expect(rects.last.right, lessThanOrEqualTo(width - 20 + .01));
        expect(find.text('已选 0'), findsOneWidget);
        expect(t.takeException(), isNull);
      },
    );
  }

  testWidgets('language filter selects a specific voice language', (t) async {
    final snapshot = data.scan();
    snapshot['plan'] = {'banks': {}, 'assets': [], 'folders': []};
    snapshot.remove('active');
    snapshot['catalogs'] = {};
    snapshot['files'] = [
      for (final language in ['CN', 'JP', 'EN'])
        {
          'name': 'VO_Test_$language.assets.bank',
          'relative_path': '$language.bank',
          'category': '活动与播报',
          'size': 100,
          'status': '待解析',
        },
    ];
    await base.open(
      t,
      const Size(1600, 900),
      [],
      responder: (a, o) async => a == 'scan' ? snapshot : {},
    );
    final selector = find.byKey(const ValueKey('voice-language-filter'));
    expect(
      t.widget<RmSelect<String>>(selector).items.keys,
      containsAll(['CN', 'JP', 'EN', 'DE', 'KO']),
    );
    await t.tap(selector);
    await t.pumpAndSettle();
    await t.tap(find.text('日本語').last);
    await t.pumpAndSettle();
    expect(find.text('VO_Test_JP.assets.bank'), findsOneWidget);
    expect(find.text('VO_Test_CN.assets.bank'), findsNothing);
    expect(find.text('VO_Test_EN.assets.bank'), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('control files show the explanation without a prepare action', (
    t,
  ) async {
    final snapshot = data.scan();
    snapshot['files'].add({
      'name': 'VO_Control.bank',
      'relative_path': 'control.bank',
      'category': '活动与播报',
      'size': 128,
      'status': '无法解析',
      'reason': '事件控制文件，不包含独立音频。',
    });
    final calls = <String>[];
    await base.open(
      t,
      const Size(1600, 900),
      calls,
      responder: (a, o) async => a == 'scan' ? snapshot : {},
    );
    await t.tap(find.byKey(const ValueKey('voice-resource-control.bank')));
    await t.pumpAndSettle();
    expect(find.text('事件控制文件，不包含独立音频。'), findsOneWidget);
    expect(find.byKey(const ValueKey('voice-prepare')), findsNothing);
    expect(calls, ['scan']);
    expect(t.takeException(), isNull);
  });

  testWidgets('modified resource and parent both have an accent side border', (
    t,
  ) async {
    final snapshot = data.scan();
    snapshot['plan']['banks']['A']['replacements'] = {
      '0': {'asset_id': 'x', 'start': 0, 'end': 2, 'gain_db': 0},
    };
    await base.open(
      t,
      const Size(1600, 900),
      [],
      responder: (a, o) async => a == 'scan' ? snapshot : {},
    );
    Border border(String key) =>
        (t.widget<Container>(find.byKey(ValueKey(key))).decoration
                    as BoxDecoration)
                .border
            as Border;
    final child = border(
      'voice-resource-mark-media/audio/FMODBanks/VO_A.assets.bank',
    );
    final parent = border('voice-resource-group-mark-活动与播报');
    expect(child.left.width, 3);
    expect(parent.left.color, child.left.color);
    expect(parent.left.width, 3);
    expect(child.left.color.a, greaterThan(0));
    expect(t.takeException(), isNull);
  });

  testWidgets(
    'unused material delete is direct and edit is only a double click',
    (t) async {
      final snapshot = data.scan();
      final calls = <String>[];
      await base.open(
        t,
        const Size(1600, 900),
        calls,
        responder: (a, o) async {
          if (a == 'scan') return snapshot;
          if (a == 'remove-assets') {
            expect(o['input']['assets'], ['x']);
            snapshot['plan']['assets'] = [
              for (final asset in snapshot['plan']['assets'])
                if (asset['id'] != 'x') asset,
            ];
            return {'plan': snapshot['plan']};
          }
          return {};
        },
      );
      await t.tap(find.text('路线'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('voice-edit-material-x')), findsNothing);
      await t.tap(find.byKey(const ValueKey('voice-delete-material-x')));
      await t.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      expect(calls, ['scan', 'remove-assets']);
      expect(find.byKey(const ValueKey('voice-material-x')), findsNothing);
      expect(find.byKey(const ValueKey('voice-material-y')), findsOneWidget);
      expect(find.widgetWithText(RmButton, '编辑'), findsNothing);
      expect(t.takeException(), isNull);
    },
  );
}
