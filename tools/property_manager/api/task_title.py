"""Canonical task item titles: `Asset Name: Task Name` without duplicated prefixes."""

from __future__ import annotations


def strip_leading_group_prefix(item: str, group: str) -> str:
    """Remove leading `{group}:` prefixes (case-insensitive), collapsing repeats."""
    title = str(item or "").strip()
    group_name = str(group or "").strip()
    if not group_name or not title:
        return title

    prefix = f"{group_name}:"
    while True:
        if not title.lower().startswith(prefix.lower()):
            break
        title = title[len(prefix) :].lstrip(" \t:-")
    return title.strip()


def canonical_task_item(*, group: str, item: str) -> str:
    """
    Build `Group: Title`.

    Aligns with ManualImport's don't-double-prefix guard: if the bare title already
    starts with the group label as a colon prefix, strip first then rebuild once.
    """
    group_name = str(group or "").strip() or "House"
    bare = strip_leading_group_prefix(item, group_name)
    if not bare:
        bare = "Maintenance item"
    # ManualImport-style: skip re-prefix when bare already contains the group token
    # as a leading "Group:" (handled above). Rebuild always so storage is canonical.
    return f"{group_name}: {bare}"


def resolve_task_group_name(*, area: str, asset_id, fetch_asset_name) -> str:
    """
    Group key: linked asset name when asset_id is set, else area.

    `fetch_asset_name(asset_id) -> str | None` looks up the active asset name.
    """
    area_name = str(area or "").strip() or "House"
    if asset_id is None or str(asset_id).strip() == "":
        return area_name
    name = fetch_asset_name(str(asset_id).strip())
    if name and str(name).strip():
        return str(name).strip()
    return area_name


def normalize_task_area_and_item(*, area: str, item: str, asset_id, fetch_asset_name) -> tuple[str, str]:
    """
    Return (area, item) for write paths.

    `area` aligns to the group label (asset name when linked). `item` is canonical.
    """
    group = resolve_task_group_name(area=area, asset_id=asset_id, fetch_asset_name=fetch_asset_name)
    return group, canonical_task_item(group=group, item=item)
