part of '../voice_replacement.dart';

extension _VoiceDialogs on _VoiceReplacementState {
  Widget _voiceInput(
    BuildContext ctx,
    TextEditingController controller,
    String label, {
    String? hint,
    bool numeric = false,
    bool autofocus = false,
    ValueChanged<String>? onSubmitted,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        label,
        style: RmText.sans(11.5, color: ctx.rm.fg2, weight: FontWeight.w500),
      ),
      const SizedBox(height: 6),
      SizedBox(
        height: 36,
        child: TextField(
          controller: controller,
          autofocus: autofocus,
          keyboardType: numeric ? TextInputType.number : TextInputType.text,
          style: RmText.sans(12.5, color: ctx.rm.fg),
          decoration: rmFieldDecoration(ctx, hint: hint),
          onSubmitted: onSubmitted,
        ),
      ),
    ],
  );

  Future<String?> _askText(
    String title,
    String hint, {
    String initial = '',
  }) async {
    final field = TextEditingController(text: initial);
    field.selection = TextSelection.collapsed(offset: initial.length);
    final result = await _voiceInputDialog<String>(
      context: context,
      controllers: [field],
      builder: (ctx) => TimingDialogFrame(
        title: title,
        busy: false,
        width: 440,
        icon: 'folder',
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _voiceInput(
              ctx,
              field,
              '文件夹名称或路径',
              hint: '例如：导航/路线提示',
              autofocus: true,
              onSubmitted: (v) {
                if (v.trim().isNotEmpty) Navigator.pop(ctx, v.trim());
              },
            ),
            const SizedBox(height: 8),
            Text(hint, style: RmText.sans(11, color: ctx.rm.fg3, height: 1.5)),
          ],
        ),
        actions: [
          RmButton(label: '取消', onPressed: () => Navigator.pop(ctx)),
          RmButton(
            label: '确定',
            variant: RmButtonVariant.primary,
            onPressed: () {
              if (field.text.trim().isNotEmpty) {
                Navigator.pop(ctx, field.text.trim());
              }
            },
          ),
        ],
      ),
    );
    return result;
  }

  Future<void> _openDirectory(String relative) async {
    final root = ref.read(studioProvider).projectDir;
    if (!relative.startsWith('analysis/voices/') &&
        relative != 'sources/voices') {
      return;
    }
    final directory = Directory(
      p.normalize(p.joinAll([root, ...relative.split('/')])),
    ).absolute;
    try {
      if (relative == 'sources/voices') await directory.create(recursive: true);
      if (!await directory.exists()) {
        throw const FileSystemException('试听缓存尚未准备，请先准备全部试听');
      }
      await ref.read(packageFolderOpenerProvider)(directory.path);
    } on Object catch (e) {
      _update(() => _error = '无法打开目录：$e');
    }
  }

  Future<void> _forgetFile() async {
    if (_locked || !_readyFile) return;
    if (_replacements.isNotEmpty ||
        stingerMap(_saved['${_bank['id']}']).isNotEmpty) {
      _update(() => _error = '此文件仍有替换，请先恢复原音并保存，再删除解析记录。');
      return;
    }
    if (!await _confirm(
      '删除此文件的解析记录？',
      '将移除条目目录与试听缓存，保留原始备份、导入素材和游戏文件。之后需要时可以重新解析。',
      '删除解析记录',
    )) {
      return;
    }
    final id = '${_bank['id']}';
    await _guard(() async {
      final data = await _call('forget', {'bank': id});
      _update(() {
        _catalogs.remove(id);
        _edits.remove(id);
        _saved.remove(id);
        _bank = {};
        _entries = [];
        _hydrate(stingerMap(data['plan']));
        for (final file in _files.where((f) => f['bank_id'] == id)) {
          file.remove('bank_id');
          file['prepared'] = false;
          file['status'] = '待解析';
        }
        _notice = '解析记录与试听缓存已删除，原始备份保留。';
      });
    });
  }

  Future<void> _editMaterial(Map<String, dynamic> asset) async {
    if (_locked) return;
    _playGeneration++;
    if (_playing != null) await _voicePlayer.pause();
    _update(() => _playing = null);
    if (!mounted) return;
    final accepted = await showAudioEditorDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => VoiceClipEditor(
        featureTour: true,
        preferredWidth: ref.read(layoutOptionsProvider).manualRefineWidth,
        asset: asset,
        folders: _assetFolders.toList(),
        load: () => _loadAssetWave(asset),
        render: (data) => _call('asset', {
          'asset': asset['id'],
          'input': {...data, 'wave': true},
        }),
      ),
    );
    if (accepted == null || !mounted) return;
    await _guard(() async {
      final data = await _call('update-asset', {
        'asset': asset['id'],
        'input': accepted,
      });
      _update(() {
        _hydrate(stingerMap(data['plan']));
        _previewPaths.removeWhere(
          (key, _) => key.startsWith('asset:${asset['id']}'),
        );
      });
    });
  }

  Future<void> _buildVoicePackage() async {
    if (_locked) return;
    if (_dirty) {
      if (!await _confirm('保存语音修改后构建？', '只构建语音替换准备包，歌曲和台呼使用各自的准备包。', '保存并继续')) {
        return;
      }
      if (!await _save()) return;
    }
    Map<String, dynamic> summary = {};
    await _guard(() async {
      summary = await _call('build-preview');
    });
    if (!mounted || summary.isEmpty) return;
    final files = stingerMaps(summary['files']);
    if (files.isEmpty) {
      _update(() => _notice = '没有需要构建的语音替换或恢复记录。');
      return;
    }
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (ctx) => TimingDialogFrame(
            title: '构建语音准备包',
            icon: 'volume',
            busy: false,
            width: 650,
            description: '${files.length} 个资源文件 · 不包含歌曲、台呼或 RadioInfo',
            body: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final file in files)
                  Container(
                    margin: const EdgeInsets.only(bottom: 7),
                    padding: const EdgeInsets.all(11),
                    decoration: BoxDecoration(
                      color: ctx.rm.raised,
                      border: Border.all(color: ctx.rm.border),
                      borderRadius: BorderRadius.circular(RmTokens.rMd),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${file['name']}',
                          style: RmText.mono(11.5, color: ctx.rm.fg),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          file['restore'] == true
                              ? '恢复原有音频'
                              : '替换 ${file['replaced']} 条 · 其余条目保留原音频',
                          style: RmText.sans(11, color: ctx.rm.accent.base),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 5),
                Text(
                  '完成后可使用右上角“写入游戏”核对文件。构建会验证编号映射并解码检查替换结果，失败时保留上次完成的准备包。',
                  style: RmText.sans(11.5, color: ctx.rm.fg3, height: 1.6),
                ),
              ],
            ),
            actions: [
              RmButton(label: '取消', onPressed: () => Navigator.pop(ctx, false)),
              RmButton(
                label: '开始构建',
                variant: RmButtonVariant.primary,
                onPressed: () => Navigator.pop(ctx, true),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;
    await _guard(() async {
      _update(() => _busyText = '正在构建并验证语音准备包…');
      final result = await _call('build');
      _update(() {
        _packageReady = result['built'] == true;
        _busyText = '';
        _notice = '语音准备包已构建，可使用右上角“写入游戏”。';
      });
    });
  }

  Future<void> _deployVoicePackage() async {
    if (_locked || !_packageReady || _dirty) return;
    final studio = ref.read(studioProvider);
    final selection = await showDialog<DeploymentChoice>(
      context: context,
      barrierColor: RmTokens.modalBackdrop,
      builder: (ctx) => DeploymentConfirmationDialog(
        title: '写入语音准备包',
        description: '仅写入此页面构建的语音文件，不携带歌曲、台呼或 RadioInfo。',
        latestConfirmation: '清单对应本次已完成的语音准备包',
        modificationConfirmation: '理解将修改游戏资源，原始快照已保存在工程内',
        gameRunning: studio.gameRunning,
        gameDir: studio.gameDir,
        packageReady: _packageReady && !_dirty,
        loadFiles: (target, excluded) async => DeploymentPreview.fromJson(
          await _call('deployment-preview', {
            'input': {
              'target': target.directoryName,
              'excluded': excluded.toList(),
            },
          }),
        ),
      ),
    );
    if (selection == null || !mounted) return;
    await _guard(() async {
      await _call('deploy', {
        'input': {
          'target': selection.target.directoryName,
          'excluded': selection.excludedFiles.toList(),
        },
      });
      _update(() => _notice = '语音准备包已写入所选游戏目录。');
    });
  }
}

Future<T?> _voiceInputDialog<T>({
  required BuildContext context,
  required List<TextEditingController> controllers,
  required WidgetBuilder builder,
}) async {
  final route = DialogRoute<T>(
    context: context,
    builder: builder,
    barrierColor: RmTokens.modalBackdrop,
  );
  try {
    final result = await Navigator.of(
      context,
      rootNavigator: true,
    ).push<T>(route);
    await route.completed;
    return result;
  } finally {
    for (final controller in controllers) {
      controller.dispose();
    }
  }
}
