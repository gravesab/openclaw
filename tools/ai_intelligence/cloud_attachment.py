"""Attachment point for a future cloud model.

The default router does not construct a cloud client. A later adapter can
implement this protocol and be passed into the execution engine. Local privacy
still removes cloud candidates before execution.
"""

from __future__ import annotations

from typing import Protocol

from tools.ai_intelligence.provider import AIProvider


class CloudModelAttachment(Protocol):
    """Supplies one cloud provider when a large problem is allowed to use it."""

    def provider(self) -> AIProvider | None:
        """Return the attached provider, or None while cloud remains unattached."""


class UnattachedCloudModels:
    """The cloud slot shipped with the local router."""

    def provider(self) -> None:
        return None
