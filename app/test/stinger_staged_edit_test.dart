import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:fh_radio_studio/state/stinger_state.dart';
import 'package:fh_radio_studio/state/unsaved_edits.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'studio_v18_workflow_test.dart' as fixtures;

const edit = {
  'asset_id': 'a',
  'start': 0.0,
  'end': 2.0,
  'gain_db': 1.0,
  'next_track': 1.5,
};
Map<String, dynamic> catalog([String locale = 'JP']) => {
  'locale': locale,
  'stations': [
    {
      'radio': 1,
      'key': 'R1:$locale',
      'name': 'Test',
      'original_count': 10,
      'additional_sound_prefix': 'FHRS_Stinger_R1_${locale}_',
      'slots': [
        for (var i = 1; i <= 10; i++)
          {
            'id': 'R1:$locale:voice$i',
            'sound_name': 'voice$i',
            'number': i,
            'duration': 2.0,
            'additional': false,
            'assignment': null,
            'original_preview': {'path': 'original-$i.wav'},
          },
      ],
    },
  ],
  'assets': [
    {
      'id': 'a',
      'name': 'Voice',
      'duration': 2.0,
      'edit': edit,
      'source_preview': {'path': 'source.wav'},
    },
  ],
  'draft': {
    'assignments': {},
    'extra_slots': {},
    'asset_edits': {'a': edit},
    'asset_names': {'a': 'Voice'},
  },
};

void main() {
  setUp(() => GoogleFonts.config.allowRuntimeFetching = false);
  test('processed draft audio survives catalog refresh and undo', () async {
    final c = await fixtures.fixture();
    addTearDown(c.dispose);
    final d = c.read(stingerDraftProvider.notifier)..hydrate(catalog());
    final processed = {
      ...edit,
      'audio_edits': [
        {'kind': 'insert', 'at': 0.0, 'duration': .1},
      ],
    };
    d.rememberMaterialPreview('a', processed, {
      'path': 'processed.wav',
      'duration': 2.1,
    });
    d.apply(d.snapshot..['asset_edits'] = {'a': processed});
    d.hydrate(catalog());
    expect(
      d.render(catalog())['assets'][0]['preview']['path'],
      'processed.wav',
    );
    d.undo();
    expect(d.render(catalog())['assets'][0]['preview']['path'], 'source.wav');
    d.redo();
    expect(
      d.render(catalog())['assets'][0]['preview']['path'],
      'processed.wav',
    );
  });
  testWidgets(
    'save failure stays in the dialog, names the failing position, and allows retry',
    (tester) async {
      var dirty = true, attempts = 0, continued = false;
      final edits = UnsavedEdits();
      edits.entries['stingers'] = PendingEdit(
        label: '电台台呼',
        dirty: () => dirty,
        discard: () {},
        save: () {
          attempts++;
          if (attempts == 1) {
            throw const FormatException('R4 · 台呼 11：素材「Voice」不存在，请重新选择。');
          }
          dirty = false;
        },
      );
      BuildContext? page;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: AppAccent.lime,
          ),
          home: Builder(
            builder: (context) {
              page = context;
              return const Scaffold();
            },
          ),
        ),
      );
      final confirmation = edits.confirmForBuild(page!).then((value) {
        continued = value;
        return value;
      });
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('build-unsaved-save')));
      await tester.pumpAndSettle();
      expect(continued, isFalse);
      expect(dirty, isTrue);
      expect(
        find.textContaining('R4 · 台呼 11', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('FormatException', findRichText: true),
        findsNothing,
      );
      expect(find.text('重试保存'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('build-unsaved-save')));
      await tester.pumpAndSettle();
      expect(await confirmation, isTrue);
      expect(dirty, isFalse);
      expect(attempts, 2);
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'a cleared edit is removed instead of becoming an assignment to a missing asset',
    () async {
      final c = await fixtures.fixture();
      final d = c.read(stingerDraftProvider.notifier)..hydrate(catalog());
      d.apply(d.snapshot..['assignments'] = {'R1:JP:voice1': edit});
      d.apply(
        d.snapshot
          ..['assignments'] = {
            'R1:JP:voice1': {
              'asset_id': null,
              'start': null,
              'end': null,
              'gain_db': null,
              'next_track': null,
            },
          },
      );
      expect(d.snapshot['assignments'], isEmpty);
      expect(d.dirty, isFalse);
      expect(
        d.render(catalog())['stations'][0]['slots'][0]['assignment'],
        isNull,
      );
    },
  );

  test(
    'locale switching retains edits; save failure preserves dirty state and cache',
    () async {
      final base = await fixtures.fixture();
      final calls = <Map<String, dynamic>>[];
      var fail = false;
      final c = ProviderContainer(
        parent: base,
        overrides: [
          stingerDraftProvider.overrideWith(
            (ref) => StingerDraftController(ref),
          ),
          stingerRequestOverrideProvider.overrideWithValue((
            action,
            input,
          ) async {
            expect(action, 'restore-draft');
            calls.add(input);
            if (fail) throw StateError('locked');
            return {'saved': true};
          }),
        ],
      );
      addTearDown(c.dispose);
      final d = c.read(stingerDraftProvider.notifier)..hydrate(catalog());
      final first = d.snapshot;
      first['assignments'] = {'R1:JP:voice1': edit};
      d.apply(first);
      d.hydrate(catalog('EN'));
      final second = d.snapshot;
      second['assignments'] = {
        ...second['assignments'] as Map,
        'R1:EN:voice2': edit,
      };
      d.apply(second);
      expect(d.dirty, isTrue);
      expect(calls, isEmpty);
      fail = true;
      await expectLater(d.save(), throwsStateError);
      expect(d.dirty, isTrue);
      expect((d.snapshot['assignments'] as Map).length, 2);
      fail = false;
      await d.save();
      expect(d.dirty, isFalse);
      expect(calls.last['input']['all_locales'], isTrue);
      expect((calls.last['input']['assignments'] as Map).length, 2);
      d.undo();
      expect(d.dirty, isTrue);
      d.discard();
      expect(d.dirty, isFalse);
      expect((d.snapshot['assignments'] as Map).length, 2);
    },
  );

  test(
    'undo restores removed materials and keeps original preview after clearing a slot',
    () async {
      final c = await fixtures.fixture();
      final d = c.read(stingerDraftProvider.notifier)..hydrate(catalog());
      final assigned = d.snapshot..['assignments'] = {'R1:JP:voice1': edit};
      d.apply(assigned);
      final view = d.render(catalog());
      expect(view['stations'][0]['slots'][0]['preview']['path'], 'source.wav');
      final removed = d.snapshot
        ..['assignments'] = {}
        ..['removed_assets'] = ['a'];
      d.apply(removed);
      final cleared = d.render(catalog());
      expect(cleared['assets'], isEmpty);
      expect(cleared['stations'][0]['slots'][0]['preview'], isNull);
      expect(
        cleared['stations'][0]['slots'][0]['original_preview']['path'],
        'original-1.wav',
      );
      d.undo();
      expect(d.render(catalog())['assets'].length, 1);
      expect(
        d.render(catalog())['stations'][0]['slots'][0]['assignment'],
        edit,
      );
    },
  );
}
