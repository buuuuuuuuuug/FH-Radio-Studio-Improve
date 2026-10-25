import 'playlist_plan.dart';

/// A source needs race markers if it is used by Event in any station.
/// Unassigned/legacy inputs retain the normal timing requirement.
bool isFreeRoamOnlySource(PlaylistPlan plan, String source) {
  final assignments = plan.assignmentsForPath(source);
  return assignments.isNotEmpty &&
      assignments.every((a) => a.playlistType == 'FreeRoam');
}
