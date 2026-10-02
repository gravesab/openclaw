from .indexer import load_index, build_index
from .logging_config import get_logger
from .tenancy import require_tenant_id

logger = get_logger(__name__)

def search(query: str, limit: int = 25, profile: str = "knowledge", tenant_id: str | None = None) -> tuple[list[dict], int]:
    """Tenant-scoped line search. Records without this tenant are invisible."""
    tenant = require_tenant_id(tenant_id)
    q = query.lower()
    index = load_index(profile)

    if not index:
        index = build_index(profile, tenant_id=tenant)

    hits = []

    for record in index:
        if record.get("tenant_id", "") != tenant:
            continue
        path = record.get("path", "")
        for line in record.get("lines", []):
            line_text = line.get("text", "")
            if q in line_text.lower():
                hits.append({
                    "path": path,
                    "line": line.get("line", 0),
                    "text": line_text,
                    "tenant_id": tenant,
                    "modified_at": record.get("modified_at", ""),
                    "indexed_at": record.get("indexed_at", ""),
                })

    logger.info(f"Line search query={query!r} profile={profile} hits={len(hits)}")
    return hits[:limit], len(hits)
