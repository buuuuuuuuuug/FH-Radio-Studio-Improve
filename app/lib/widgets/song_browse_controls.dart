import 'package:flutter/material.dart';
import '../core/song_browse.dart';
import '../theme/app_theme.dart';
import '../theme/text_styles.dart';
import '../theme/tokens.dart';
import 'rm_button.dart';
import 'rm_select.dart';
import 'rm_icon.dart';
import 'rm_field.dart';

const songBrowseActionWidth = 90.0;

class SongBrowseControls extends StatefulWidget {
  const SongBrowseControls({
    super.key,
    required this.value,
    required this.onChanged,
    this.compact = false,
    this.showStatus = true,
    this.showSearch = true,
    this.showScene = false,
  });
  final SongBrowse value;
  final ValueChanged<SongBrowse> onChanged;
  final bool compact, showStatus, showSearch, showScene;

  @override
  State<SongBrowseControls> createState() => _SongBrowseControlsState();
}

class _SongBrowseControlsState extends State<SongBrowseControls> {
  late final TextEditingController _search = TextEditingController(
    text: widget.value.search,
  );
  SongBrowse get value => widget.value;
  ValueChanged<SongBrowse> get onChanged => widget.onChanged;
  bool get compact => widget.compact;
  bool get showStatus => widget.showStatus;
  bool get showSearch => widget.showSearch;

  @override
  void didUpdateWidget(covariant SongBrowseControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value.search != value.search &&
        _search.text != value.search) {
      _search.value = TextEditingValue(
        text: value.search,
        selection: TextSelection.collapsed(offset: value.search.length),
      );
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Widget _select<T>(
    BuildContext context,
    T current,
    List<(T, String)> items,
    ValueChanged<T> change,
    String tooltip,
  ) {
    if (compact) {
      return Tooltip(
        message: tooltip,
        child: LayoutBuilder(
          builder: (context, box) => RmSelect<T>(
            horizontalPadding: box.maxWidth < 86 ? 2 : 10,
            value: current,
            items: {for (final item in items) item.$1: item.$2},
            onChanged: change,
          ),
        ),
      );
    }
    final rm = context.rm;
    return Tooltip(
      message: '$tooltip：${items.firstWhere((item) => item.$1 == current).$2}',
      child: Container(
        height: 32,
        padding: EdgeInsets.symmetric(horizontal: compact ? 4 : 10),
        decoration: BoxDecoration(
          color: rm.raised,
          border: Border.all(color: rm.border),
          borderRadius: BorderRadius.circular(RmTokens.rSm),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<T>(
            value: current,
            isExpanded: true,
            isDense: true,
            dropdownColor: rm.panel,
            borderRadius: BorderRadius.circular(RmTokens.rSm),
            style: RmText.sans(12, color: rm.fg),
            icon: Icon(Icons.expand_more, size: 14, color: rm.fg3),
            items: [
              for (final item in items)
                DropdownMenuItem(
                  value: item.$1,
                  child: Text(
                    item.$2,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (v) {
              if (v != null) change(v);
            },
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final scene = SizedBox(
      width: songBrowseActionWidth,
      child: RmButton(
        key: const ValueKey('song-scene-filter'),
        label: switch (value.scene) {
          SongSceneFilter.all => '全部',
          SongSceneFilter.freeRoam => '漫游',
          SongSceneFilter.event => '比赛',
        },
        leading: const Icon(Icons.swap_horiz, size: 12),
        tooltip: '按准备包分配筛选：全部 → 漫游 → 比赛；点击切换',
        onPressed: () => onChanged(
          value.copyWith(
            scene:
                SongSceneFilter.values[(value.scene.index + 1) %
                    SongSceneFilter.values.length],
          ),
        ),
      ),
    );
    final sort = _select(
      context,
      value.sort == SongSort.editor
          ? SongSort.artist
          : value.sort == SongSort.modifiedNewest
          ? SongSort.modifiedOldest
          : value.sort,
      const [
        (SongSort.filename, '文件名称'),
        (SongSort.artist, '歌手名称'),
        (SongSort.title, '歌曲名称'),
        (SongSort.modifiedOldest, '修改日期'),
      ],
      (v) => onChanged(value.copyWith(sort: v)),
      '排序方式',
    );
    final direction = RmButton(
      label: value.descending ? '倒序' : '正序',
      leading: RmIcon(
        value.descending ? 'chevron-down' : 'chevron-up',
        size: 12,
      ),
      tooltip: '切换正序 / 倒序',
      onPressed: () => onChanged(value.copyWith(descending: !value.descending)),
    );
    final filter = _select(
      context,
      value.filter,
      [
        for (final f in SongFilter.values)
          (
            f,
            switch (f) {
              SongFilter.all => '全部状态',
              SongFilter.configured => '已就绪',
              SongFilter.unconfigured => '待配置',
              SongFilter.assigned => '已分配',
              SongFilter.unassigned => '未分配',
              SongFilter.duplicates => '可能重复',
            },
          ),
      ],
      (v) => onChanged(value.copyWith(filter: v)),
      '过滤歌曲',
    );
    final station = _select(
      context,
      value.station,
      [('', '全部电台'), for (var i = 1; i <= 9; i++) ('R$i', '电台 $i')],
      (v) => onChanged(value.copyWith(station: v)),
      '按电台过滤',
    );
    final search = SizedBox(
      height: 32,
      child: TextField(
        key: const ValueKey('song-browse-search'),
        controller: _search,
        style: RmText.sans(12, color: rm.fg),
        cursorColor: rm.accent.base,
        decoration:
            rmFieldDecoration(
              context,
              hint: '搜索歌曲 / 歌手 / 文件名',
              prefix: Icon(Icons.search, size: 14, color: rm.fg3),
            ).copyWith(
              suffixIconConstraints: const BoxConstraints.tightFor(
                width: 30,
                height: 30,
              ),
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(
                      key: const ValueKey('song-browse-clear-search'),
                      tooltip: '清空搜索',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 30,
                        height: 30,
                      ),
                      icon: Icon(Icons.close, size: 14, color: rm.fg3),
                      onPressed: () {
                        _search.clear();
                        setState(() {});
                        onChanged(value.copyWith(search: ''));
                      },
                    ),
            ),
        onChanged: (v) {
          setState(() {});
          onChanged(value.copyWith(search: v));
        },
      ),
    );
    return Padding(
      padding: compact
          ? const EdgeInsets.fromLTRB(8, 4, 8, 0)
          : const EdgeInsets.all(12),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            compact
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (showSearch) ...[search, const SizedBox(height: 4)],
                      Row(
                        children: [
                          Expanded(child: sort),
                          const SizedBox(width: 6),
                          SizedBox(
                            width: songBrowseActionWidth,
                            child: direction,
                          ),
                        ],
                      ),
                      const SizedBox(height: 5),
                      Row(
                        children: [
                          if (showStatus) ...[
                            Expanded(child: filter),
                            const SizedBox(width: 6),
                          ],
                          Expanded(child: station),
                          if (widget.showScene) ...[
                            const SizedBox(width: 6),
                            scene,
                          ],
                        ],
                      ),
                    ],
                  )
                : LayoutBuilder(
                    builder: (context, constraints) {
                      if (constraints.maxWidth >= 700) {
                        return Row(
                          children: [
                            if (showSearch) ...[
                              Expanded(flex: 4, child: search),
                              const SizedBox(width: 8),
                            ],
                            Expanded(flex: 3, child: sort),
                            const SizedBox(width: 8),
                            SizedBox(width: 84, child: direction),
                            if (widget.showScene) ...[
                              const SizedBox(width: 8),
                              scene,
                            ],
                            const SizedBox(width: 8),
                            if (showStatus) ...[
                              Expanded(flex: 2, child: filter),
                              const SizedBox(width: 8),
                            ],
                            Expanded(flex: 2, child: station),
                          ],
                        );
                      }
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (showSearch) ...[
                            search,
                            const SizedBox(height: 8),
                          ],
                          Row(
                            children: [
                              Expanded(child: sort),
                              const SizedBox(width: 8),
                              SizedBox(width: 84, child: direction),
                              if (widget.showScene) ...[
                                const SizedBox(width: 8),
                                scene,
                              ],
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              if (showStatus) ...[
                                Expanded(child: filter),
                                const SizedBox(width: 8),
                              ],
                              Expanded(child: station),
                            ],
                          ),
                        ],
                      );
                    },
                  ),
          ],
        ),
      ),
    );
  }
}
