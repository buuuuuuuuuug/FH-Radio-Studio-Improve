from __future__ import annotations

import tempfile

from .baseline import baseline_version_id, describe_game_version, load_baseline_md5s
from .common import *
from .deployment_paths import (
    contained_game_path,
    deployment_relative_path,
    owned_overlay_for_media_write,
)
from .file_transaction import game_file_write_lock, replace_files_atomically
from .game import game_root_for, resolve_game_dir, steam_game_version
from .language import normalize_preferred_language, resolve_user_preferred_lang_path
from .package import collect_package_deploy_files
from .project_json_guard import write_project_json
from .project_refs import project_path_or_absolute


def _last_applied_manifest_data(
    path: Optional[str],
    *,
    package_manifest_path: Path,
    package_root: Path,
    package_manifest: Dict[str, object],
    game_version: Dict[str, object],
    deploy_files: List[Dict[str, object]],
    game_dir: Optional[Path] = None,
    removed_paths: Optional[set[str]] = None,
    retain_previous: bool = False,
) -> Dict[str, object]:
    if not path:
        return {}
    manifest_path = Path(path).expanduser()
    project_dir = (
        manifest_path.parent.parent if manifest_path.parent.name == ".fh-radio-studio" else None
    )
    package_files = []
    for item in deploy_files:
        package_md5 = item.get("package_md5")
        if not isinstance(package_md5, str) or not package_md5:
            continue
        package_files.append(
            {
                "kind": item.get("kind", "file"),
                "relative_path": item.get("relative_path"),
                "install_relative_path": item.get("install_relative_path"),
                "size": item.get("source_size"),
                "md5": package_md5,
            }
        )
    retained = 0
    if (
        game_dir is not None
        and (
            retain_previous
            or (package_manifest.get("package_delta") or {}).get("mode") == "changed_files"
        )
        and manifest_path.is_file()
    ):
        previous = load_manifest(manifest_path)
        new_paths = {item["install_relative_path"] for item in package_files}
        for old in previous.get("package_files", []):
            relative = str(old.get("install_relative_path") or "")
            if (
                relative
                and relative not in new_paths
                and relative not in (removed_paths or set())
                and md5_file(contained_game_path(game_dir, relative)) == old.get("md5")
            ):
                package_files.append(old)
                retained += 1
    manifest = {
        "schema_version": 1,
        "kind": "last_applied_package",
        "created_at": datetime.now(timezone.utc).isoformat(),
        "source_package_manifest": (
            project_path_or_absolute(project_dir, package_manifest_path)
            if project_dir is not None
            else str(package_manifest_path.resolve())
        ),
        "package_root": (
            project_path_or_absolute(project_dir, package_root)
            if project_dir is not None
            else str(package_root.resolve())
        ),
        "game_version": game_version,
        "game_version_id": baseline_version_id(game_version),
        "supported_game_version_ids": [baseline_version_id(game_version)],
        "package_name": (
            package_manifest.get("package_name") if isinstance(package_manifest, dict) else None
        ),
        "package_files": package_files,
        "retained_previous_files": retained,
        "deployment_target": (
            "mediapc"
            if package_files
            and str(package_files[0].get("install_relative_path", "")).startswith("mediapc/")
            else "media"
        ),
    }
    return manifest


def _last_applied_md5s(path: Optional[str]) -> Dict[str, str]:
    if not path:
        return {}
    manifest_path = Path(path).expanduser()
    if not manifest_path.exists():
        return {}
    manifest = load_manifest(manifest_path)
    result: Dict[str, str] = {}

    def add_path(value: object, md5: object) -> None:
        if not isinstance(md5, str) or not md5:
            return
        text = str(value or "").replace("\\", "/").strip("/")
        if not text:
            return
        result[text] = md5
        if not text.startswith(("media/", "mediapc/")) and text != "UserPreferredLang":
            result[f"media/audio/{text}"] = md5

    def add_items(items: object) -> None:
        if not isinstance(items, list):
            return
        for item in items:
            if not isinstance(item, dict):
                continue
            md5 = item.get("md5") or item.get("package_md5") or item.get("source_md5")
            add_path(item.get("relative_path"), md5)
            add_path(item.get("install_relative_path"), md5)

    add_items(manifest.get("package_files"))
    add_items(manifest.get("files"))
    return result


def cmd_deploy_package(args: argparse.Namespace) -> int:
    if getattr(args, "json", False) and args.yes:
        raise CliError("写入清单预览不会修改文件，不能同时使用 --json 和 --yes")
    game_dir = game_root_for(resolve_game_dir(args.game_dir))
    with game_file_write_lock(game_dir, enabled=args.yes):
        return _deploy_package(args, game_dir)


def _deploy_package(args: argparse.Namespace, game_dir: Path) -> int:
    game_version = steam_game_version(game_dir)
    package_dir = Path(args.package_dir).expanduser()
    package_root = package_root_dir(package_dir)
    from .package_transaction import journal_path

    if journal_path(package_root.parent).exists():
        raise CliError("准备包正在替换或等待恢复，请先重试替换完成后再写入游戏")
    package_manifest_path = package_root / "fh_radio_studio_package_manifest.json"
    package_manifest = (
        load_manifest(package_manifest_path) if package_manifest_path.exists() else {}
    )
    from .package_delta import validate_delta_dependencies

    files = collect_package_deploy_files(package_root)
    from .deployment_selection import (
        DEPLOYMENT_RECORD,
        PREFERRED_LANGUAGE,
        excluded_files,
        selection_issues,
    )

    excluded = excluded_files(args, files, package_manifest)
    selected_xml = {
        str(f["install_relative_path"])
        for f in files
        if f["install_relative_path"] not in excluded
        and Path(str(f["source"])).name.startswith("RadioInfo_")
    }
    if selected_xml:
        validate_delta_dependencies(package_manifest, game_dir, xml_paths=selected_xml)
    target_root = getattr(args, "target_root", "mediapc")
    for item in files:
        item["package_install_relative_path"] = item["install_relative_path"]
        item["install_relative_path"] = deployment_relative_path(
            str(item["install_relative_path"]), target_root
        )
    issues = selection_issues(files, excluded, game_dir)
    if issues and not getattr(args, "json", False):
        raise CliError("；".join(issues) + " 尚未写入任何文件。")

    def reject_file(message):
        if getattr(args, "json", False):
            issues.append(message)
        else:
            raise CliError(message)

    baseline_md5s = load_baseline_md5s(args.baseline_manifest)
    last_applied_md5s = _last_applied_md5s(getattr(args, "last_applied_manifest", None))
    if target_root == "media" and not args.force and not baseline_md5s:
        die(
            "A pristine baseline is required before deploy. Create one first, or pass --force explicitly."
        )
    if not getattr(args, "json", False):
        print(f"Game dir   : {game_dir}")
        print(f"Game build : {describe_game_version(game_version)}")
        print(f"Package    : {package_root}")
        print(f"Write target: {target_root}")
        if args.baseline_manifest:
            print(f"Baseline   : {args.baseline_manifest}")
        if getattr(args, "last_applied_manifest", None):
            print(f"Fingerprint: {Path(args.last_applied_manifest).expanduser()}")
        print("Plan:")
        for item in files:
            src = Path(str(item["source"]))
            install_rel = Path(*str(item["install_relative_path"]).split("/"))
            print(f"  {src} -> {game_dir / install_rel}")

    # Validate the entire write set before changing any destination.
    manifest_files = []
    owned_overlay_removals = []
    for item in files:
        src = Path(str(item["source"]))
        rel_text = str(item["relative_path"]).replace("\\", "/")
        install_rel_text = str(item["install_relative_path"]).replace("\\", "/")
        dest = contained_game_path(game_dir, install_rel_text)
        source_md5 = md5_file(src)
        source_size = file_size(src)
        current_before_md5 = md5_file(dest)
        canonical_rel = str(item["package_install_relative_path"])
        baseline_md5 = baseline_md5s.get(canonical_rel) or baseline_md5s.get(rel_text)
        last_applied_md5 = last_applied_md5s.get(install_rel_text) or last_applied_md5s.get(
            rel_text
        )
        selected = canonical_rel not in excluded
        voice = next(
            (
                b
                for b in (package_manifest.get("voices") or {}).get("banks", [])
                if b.get("bank") == src.name
            ),
            None,
        )
        if selected and voice and voice.get("original_md5"):
            from .deployment_paths import effective_game_file

            current_voice = md5_file(effective_game_file(game_dir, canonical_rel))
            overlay_relative = deployment_relative_path(canonical_rel, "mediapc")
            trusted_voice = {
                voice["original_md5"],
                source_md5,
                last_applied_md5s.get(canonical_rel),
                last_applied_md5s.get(overlay_relative),
            }
            if current_voice is not None and current_voice not in trusted_voice:
                reject_file(
                    f"{src.name} 在确认备份后发生变化，请重新核对资源，或取消勾选此文件。尚未写入任何文件。"
                )
        if selected and not args.force and (target_root == "media" or dest.exists()):
            if baseline_md5 is None and target_root == "media":
                reject_file(f"{src.name} 缺少原始备份。请先补齐备份，或取消勾选此文件。")
            trusted_md5s = {
                value
                for value in (baseline_md5, source_md5, last_applied_md5)
                if isinstance(value, str) and value
            }
            if current_before_md5 not in trusted_md5s:
                trusted_label = (
                    "pristine baseline, package, and last applied package"
                    if last_applied_md5
                    else "both pristine baseline and package"
                )
                reject_file(
                    f"{install_rel_text} differs from {trusted_label}. "
                    "Use --force only when you intentionally want to overwrite an untrusted current game file."
                )
        if selected and target_root == "media":
            try:
                overlay = owned_overlay_for_media_write(game_dir, canonical_rel, last_applied_md5s)
            except CliError as error:
                reject_file(str(error))
                overlay = None
            if overlay is not None:
                owned_overlay_removals.append(overlay)
        manifest_files.append(
            {
                "kind": item.get("kind", "file"),
                "selection_id": canonical_rel,
                "selected": selected,
                "relative_path": rel_text,
                "install_relative_path": install_rel_text,
                "source": str(src.resolve()),
                "destination": str(dest.resolve()),
                "source_size": source_size,
                "source_md5": source_md5,
                "package_md5": source_md5,
                "baseline_md5": baseline_md5,
                "last_applied_md5": last_applied_md5,
                "current_before_md5": current_before_md5,
                "force": args.force,
            }
        )
    if getattr(args, "json", False):
        from .deployment_preview import deployment_preview

        preview = deployment_preview(
            args,
            game_dir,
            package_root,
            package_manifest,
            manifest_files,
            owned_overlay_removals,
            excluded=excluded,
            issues=issues,
        )
        print(json.dumps(preview, ensure_ascii=False, allow_nan=False, indent=2))
        return 0
    if not args.yes:
        for overlay in owned_overlay_removals:
            print(f"  remove owned override after media write: {overlay}")
        print("\nDry run only. Re-run with --yes to write files.")
        return 0

    manifest_files = [f for f in manifest_files if f["selected"]]
    language = package_manifest.get("language") if isinstance(package_manifest, dict) else None
    if PREFERRED_LANGUAGE in excluded:
        language = None
    fingerprint_path = getattr(args, "last_applied_manifest", None)
    if DEPLOYMENT_RECORD in excluded:
        fingerprint_path = None
    if not manifest_files and not language and not fingerprint_path:
        raise CliError("请至少选择一个需要写入的文件；尚未写入任何文件。")
    with tempfile.TemporaryDirectory(prefix="fh-radio-studio-deploy-") as temporary_dir:
        staging = Path(temporary_dir)
        replacements = [
            (Path(str(item["source"])), Path(str(item["destination"])), item["package_md5"])
            for item in manifest_files
        ]
        if isinstance(language, dict) and language.get("preferred_lang"):
            preferred_lang = normalize_preferred_language(str(language["preferred_lang"]))
            preferred_path = resolve_user_preferred_lang_path(getattr(args, "preferred_path", None))
            staged_language = staging / "UserPreferredLang"
            staged_language.write_text(preferred_lang, encoding="utf-8")
            replacements.append((staged_language, preferred_path, None))
        if fingerprint_path:
            fingerprint = Path(fingerprint_path).expanduser()
            staged_manifest = staging / "last_applied_package_manifest.json"
            manifest = _last_applied_manifest_data(
                fingerprint_path,
                package_manifest_path=package_manifest_path,
                package_root=package_root,
                package_manifest=package_manifest,
                game_version=game_version,
                deploy_files=manifest_files,
                retain_previous=bool(excluded),
                game_dir=game_dir,
                removed_paths={
                    path.relative_to(game_dir).as_posix() for path in owned_overlay_removals
                },
            )
            project_dir = (
                fingerprint.parent.parent if fingerprint.parent.name == ".fh-radio-studio" else None
            )
            write_project_json(staged_manifest, manifest, project_dir=project_dir)
            replacements.append((staged_manifest, fingerprint, None))
        replace_files_atomically(replacements, removals=owned_overlay_removals)
    for item in manifest_files:
        print(f"  copied {item['install_relative_path']}")
    for overlay in owned_overlay_removals:
        print(f"  removed owned override {overlay.relative_to(game_dir)}")
    if isinstance(language, dict) and language.get("preferred_lang"):
        print(f"  wrote UserPreferredLang -> {preferred_lang}")
    if fingerprint_path:
        print(f"Last applied fingerprint: {Path(args.last_applied_manifest).expanduser()}")
    return 0
