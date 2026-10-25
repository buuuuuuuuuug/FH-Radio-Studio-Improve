import '../core/playlist_capacity.dart';
import 'playlist_capacity.dart';
import 'playlist_catalog_state.dart';
import 'playlist_plan_state.dart';
import '../domain/radio_library.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/project_workspace.dart';
import 'studio_state.dart';

class EditorOptions {
  const EditorOptions({
    this.syncPostLoop = false,
    this.manualOnly = false,
    this.sirenEnabled = false,
    this.expansionEnabled = false,
    this.slmEnabled = true,
  });
  final bool syncPostLoop;
  final bool manualOnly;
  final bool sirenEnabled;
  final bool expansionEnabled;
  final bool slmEnabled;
}

class EditorOptionsController extends StateNotifier<EditorOptions> {
  EditorOptionsController(this.ref) : super(const EditorOptions()) {
    _load();
    ref.listen<String>(
      studioProvider.select((s) => s.projectDir),
      (_, next) => _load(),
    );
  }
  final Ref ref;
  void _load() {
    final settings = FhRadioStudioProject.readSettings(
      ref.read(studioProvider).projectDir,
    );
    state = EditorOptions(
      syncPostLoop: settings['sync_post_loop'] == true,
      manualOnly: settings['manual_only'] == true,
      sirenEnabled: settings['siren_enabled'] == true,
      expansionEnabled: settings['expansion_enabled'] == true,
      slmEnabled: settings['seamless_loop_music'] != false,
    );
  }

  List<String> expansionOverflow() {
    final catalog = ref.read(playlistCatalogProvider);
    final plan = ref.read(effectivePlaylistPlanProvider);
    final hasPlan =
        ref.read(playlistPlanProvider.notifier).hasUserPlan || plan.hasDraft;
    final fallback = <String, Map<String, int>>{
      if (!hasPlan)
        for (final radio in catalog.radios)
          radio.code: {
            for (final type in ['FreeRoam', 'Event'])
              if (catalog.modeOfList(radio.code, type) == StationMode.custom)
                type: catalog.tracksOfRadio(radio.code, type).length,
          },
    };
    return describeCapacityViolations(
      ref
          .read(playlistCapacityPolicyProvider)
          .violations(plan, fallbackCounts: fallback),
    );
  }

  bool update({
    bool? syncPostLoop,
    bool? manualOnly,
    bool? sirenEnabled,
    bool? expansionEnabled,
    bool? slmEnabled,
  }) {
    if (expansionEnabled == false && state.expansionEnabled) {
      final plan = ref.read(effectivePlaylistPlanProvider);
      if (plan.splitPlaylistTypes == true) {
        return false;
      }
    }
    if (expansionEnabled == false &&
        state.expansionEnabled &&
        expansionOverflow().isNotEmpty) {
      return false;
    }
    final next = EditorOptions(
      syncPostLoop: syncPostLoop ?? state.syncPostLoop,
      manualOnly: manualOnly ?? state.manualOnly,
      sirenEnabled: sirenEnabled ?? state.sirenEnabled,
      expansionEnabled: expansionEnabled ?? state.expansionEnabled,
      slmEnabled: slmEnabled ?? state.slmEnabled,
    );
    FhRadioStudioProject.writeSettings(
      ref.read(studioProvider).projectDir,
      syncPostLoop: next.syncPostLoop,
      manualOnly: next.manualOnly,
      sirenEnabled: next.sirenEnabled,
      expansionEnabled: next.expansionEnabled,
      slmEnabled: next.slmEnabled,
    );
    state = next;
    return true;
  }
}

final editorOptionsProvider =
    StateNotifierProvider<EditorOptionsController, EditorOptions>(
      (ref) => EditorOptionsController(ref),
    );
