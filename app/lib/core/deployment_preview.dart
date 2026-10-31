import 'game_deployment_target.dart';

typedef DeploymentPreviewLoader =
    Future<DeploymentPreview> Function(
      GameDeploymentTarget target,
      Set<String> excludedFiles,
    );

class DeploymentChoice {
  const DeploymentChoice(this.target, this.excludedFiles);
  final GameDeploymentTarget target;
  final Set<String> excludedFiles;
}

class DeploymentFilePreview {
  const DeploymentFilePreview({
    required this.fileName,
    required this.destination,
    required this.relativePath,
    required this.description,
    required this.category,
    this.sizeBytes,
    this.operation = 'write',
    this.selectionId,
    this.selected = true,
    this.pathBase = '游戏目录',
  });

  final String fileName, destination, relativePath, description, category;
  final int? sizeBytes;
  final String operation, pathBase;
  final String? selectionId;
  final bool selected;
  String get id => selectionId ?? relativePath;

  factory DeploymentFilePreview.fromJson(Map<String, dynamic> value) =>
      DeploymentFilePreview(
        fileName: value['file_name'] as String,
        selectionId: value['selection_id'] as String?,
        selected: value['selected'] != false,
        pathBase: value['path_base'] as String? ?? '游戏目录',
        destination: value['destination'] as String,
        relativePath: value['relative_path'] as String,
        description: value['description'] as String,
        category: value['category'] as String,
        operation: value['operation'] as String? ?? 'write',
        sizeBytes: (value['size_bytes'] as num?)?.toInt(),
      );
}

class DeploymentPreview {
  const DeploymentPreview({
    required this.writes,
    this.removals = const [],
    this.changedFilesOnly = false,
    this.omittedUnchangedCount = 0,
    this.selectionIssues = const [],
  });

  final List<DeploymentFilePreview> writes, removals;
  final List<String> selectionIssues;
  int get selectedCount => writes.where((f) => f.selected).length;
  final bool changedFilesOnly;
  final int omittedUnchangedCount;
  int get resourceCount => writes.where((f) => f.category == 'resource').length;
  int get auxiliaryCount => writes.length - resourceCount;

  factory DeploymentPreview.fromJson(Map<String, dynamic> value) {
    if (value['schema_version'] != 1 ||
        value['writes'] is! List ||
        value['removals'] is! List) {
      throw const FormatException('写入清单格式无效，请重新读取。');
    }
    List<DeploymentFilePreview> files(String name) => (value[name] as List)
        .map(
          (item) => DeploymentFilePreview.fromJson(
            Map<String, dynamic>.from(item as Map),
          ),
        )
        .toList(growable: false);
    return DeploymentPreview(
      writes: files('writes'),
      selectionIssues: List<String>.from(
        value['selection_issues'] as List? ?? const [],
      ),
      removals: files('removals'),
      changedFilesOnly: value['changed_files_only'] == true,
      omittedUnchangedCount:
          (value['omitted_unchanged_count'] as num?)?.toInt() ?? 0,
    );
  }
}
