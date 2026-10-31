"""Map package paths to a selected, contained game media directory."""

from pathlib import Path, PurePosixPath

from .common import CliError, md5_file


def deployment_relative_path(package_path: str, target_root: str = "mediapc") -> str:
    if target_root not in {"media", "mediapc"}:
        raise CliError(f"Unsupported deployment target: {target_root}")
    raw = str(package_path).replace("\\", "/")
    parts = PurePosixPath(raw).parts
    if (
        not parts
        or parts[0] != "media"
        or len(parts) < 3
        or any(part in {"..", "."} or ":" in part for part in parts)
    ):
        raise CliError(f"Unsafe package deployment path: {raw}")
    return PurePosixPath(target_root, *parts[1:]).as_posix()


def contained_game_path(game_dir: Path, relative_path: str) -> Path:
    raw = str(relative_path).replace("\\", "/")
    if (
        not raw
        or raw.startswith("/")
        or any(part in {".", ".."} or ":" in part for part in raw.split("/"))
        or any(ord(char) < 32 or ord(char) == 127 for char in raw)
    ):
        raise CliError(f"Unsafe relative file path: {relative_path}")
    root = game_dir.resolve()
    path = game_dir / Path(*PurePosixPath(raw).parts)
    resolved = path.resolve()
    if resolved == root or root not in resolved.parents:
        raise CliError(f"Deployment path escapes game directory: {path}")
    return path


def effective_game_file(game_dir: Path, media_path: str) -> Path:
    overlay = contained_game_path(game_dir, deployment_relative_path(media_path))
    return overlay if overlay.is_file() else contained_game_path(game_dir, media_path)


def owned_overlay_for_media_write(game_dir: Path, media_path: str, ownership: dict) -> Path | None:
    """A media write must not remain shadowed by, or remove, another mod's file."""
    relative = deployment_relative_path(media_path, "mediapc")
    overlay = contained_game_path(game_dir, relative)
    if not overlay.exists():
        return None
    digest = md5_file(overlay)
    if digest is None or ownership.get(relative) != digest:
        raise CliError(
            f"{relative} would shadow the media write and is not owned by the last deployment. "
            "Use mediapc, or remove that conflicting override before writing media."
        )
    return overlay
