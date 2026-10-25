import '../domain/radio_library.dart';
import 'playlist_plan.dart';

String formatSongModifiedMinute(DateTime? date) {
  if (date == null) return '—';
  final t = date.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

enum SongSort {
  editor,
  modifiedNewest,
  modifiedOldest,
  artist,
  title,
  filename,
}

enum SongSceneFilter { all, freeRoam, event }

enum SongFilter {
  all,
  configured,
  unconfigured,
  assigned,
  unassigned,
  duplicates,
}

class SongBrowse {
  const SongBrowse({
    this.search = '',
    this.sort = SongSort.filename,
    this.filter = SongFilter.all,
    this.station = '',
    this.descending = false,
    this.scene = SongSceneFilter.all,
  });
  final String search;
  final SongSort sort;
  final SongFilter filter;
  final String station;
  final bool descending;
  final SongSceneFilter scene;
  SongBrowse copyWith({
    String? search,
    SongSort? sort,
    SongFilter? filter,
    String? station,
    bool? descending,
    SongSceneFilter? scene,
  }) => SongBrowse(
    search: search ?? this.search,
    sort: sort ?? this.sort,
    filter: filter ?? this.filter,
    station: station ?? this.station,
    descending: descending ?? this.descending,
    scene: scene ?? this.scene,
  );
}

String songIdentity(PoolTrack t) =>
    '${t.title.trim().toLowerCase()}|${t.artist.trim().toLowerCase()}|${t.durationSec.round()}';
Set<String> duplicateSongs(List<PoolTrack> tracks) {
  final counts = <String, int>{};
  for (final t in tracks) {
    final key = songIdentity(t);
    counts[key] = (counts[key] ?? 0) + 1;
  }
  return {
    for (final e in counts.entries)
      if (e.value > 1) e.key,
  };
}

List<PoolTrack> browseSongs(
  List<PoolTrack> all,
  SongBrowse options, {
  Set<String>? duplicates,
  PlaylistPlan? plan,
  bool splitTypes = false,
}) {
  final repeated = duplicates ?? duplicateSongs(all);
  final q = options.search.trim().toLowerCase();
  final result = all
      .where(
        (t) =>
            (q.isEmpty ||
                '${t.title} ${t.artist} ${t.source}'.toLowerCase().contains(
                  q,
                )) &&
            _matchesAssignment(t, options, plan, splitTypes) &&
            switch (options.filter) {
              SongFilter.all => true,
              SongFilter.configured => t.readyForBuild,
              SongFilter.unconfigured => !t.readyForBuild,
              SongFilter.assigned => t.assignedTo != null,
              SongFilter.unassigned => t.assignedTo == null,
              SongFilter.duplicates => repeated.contains(songIdentity(t)),
            },
      )
      .toList();
  if (options.sort != SongSort.editor) {
    result.sort((a, b) {
      final value = switch (options.sort) {
        SongSort.modifiedNewest => (b.modifiedAt ?? DateTime(1970)).compareTo(
          a.modifiedAt ?? DateTime(1970),
        ),
        SongSort.modifiedOldest => (a.modifiedAt ?? DateTime(1970)).compareTo(
          b.modifiedAt ?? DateTime(1970),
        ),
        SongSort.artist => a.artist.toLowerCase().compareTo(
          b.artist.toLowerCase(),
        ),
        SongSort.title => a.title.toLowerCase().compareTo(
          b.title.toLowerCase(),
        ),
        SongSort.filename => _filename(a.source).compareTo(_filename(b.source)),
        SongSort.editor => 0,
      };
      return value != 0
          ? value
          : a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });
  }
  return options.descending ? result.reversed.toList() : result;
}

String _filename(String source) =>
    source.replaceAll('\\', '/').split('/').last.toLowerCase();

bool _matchesAssignment(
  PoolTrack track,
  SongBrowse options,
  PlaylistPlan? plan,
  bool splitTypes,
) {
  final scene = splitTypes ? options.scene : SongSceneFilter.all;
  if (scene == SongSceneFilter.all && options.station.isEmpty) return true;
  if (plan == null) {
    return scene == SongSceneFilter.all &&
        (options.station.isEmpty || track.assignedTo == options.station);
  }
  final type = switch (scene) {
    SongSceneFilter.all => null,
    SongSceneFilter.freeRoam => 'FreeRoam',
    SongSceneFilter.event => 'Event',
  };
  return plan
      .assignmentsForPath(track.source)
      .any(
        (assignment) =>
            assignment.isAssigned &&
            (type == null || assignment.playlistType == type) &&
            (options.station.isEmpty ||
                assignment.radioCode == options.station),
      );
}
