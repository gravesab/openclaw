from ranchbrain.memory_store import remember
from ranchbrain.relationship_suggestions import suggest_relationships


def test_suggest_relationships_uses_shared_tags():
    source = remember(
        tenant_id="test-tenant",
        module="property",
        category="maintenance",
        title="Suggestion source",
        body="Source for suggestion testing.",
        memory_type="event",
        tags=["suggestion-unique", "stump"],
    )

    target = remember(
        tenant_id="test-tenant",
        module="property",
        category="maintenance",
        title="Suggestion target",
        body="Target for suggestion testing.",
        memory_type="event",
        tags=["suggestion-unique", "follow-up"],
    )

    suggestions = suggest_relationships(
        source.memory_id,
        min_score=20,
        tenant_id="test-tenant",
    )

    assert any(
        item.memory.id == target.memory_id
        for item in suggestions
    )


def test_suggestions_exclude_existing_relationships():
    source = remember(
        tenant_id="test-tenant",
        module="property",
        category="test",
        title="Existing link suggestion source",
        body="Source.",
        tags=["existing-link-unique"],
    )

    target = remember(
        tenant_id="test-tenant",
        module="property",
        category="test",
        title="Existing link suggestion target",
        body="Target.",
        tags=["existing-link-unique"],
    )

    from ranchbrain.memory_store import link_memories

    link_memories(source.memory_id, target.memory_id, tenant_id="test-tenant")

    suggestions = suggest_relationships(
        source.memory_id,
        min_score=0,
        tenant_id="test-tenant",
    )

    assert all(
        item.memory.id != target.memory_id
        for item in suggestions
    )

def test_suggestions_hide_test_like_titles_by_default():
    source = remember(
        tenant_id="test-tenant",
        module="property",
        category="maintenance",
        title="Operational suggestion source",
        body="Operational source.",
        tags=["hidden-test-check"],
    )

    candidate = remember(
        tenant_id="test-tenant",
        module="property",
        category="maintenance",
        title="Temporary filter test memory",
        body="Should be hidden unless tests are requested.",
        tags=["hidden-test-check", "test"],
    )

    default_results = suggest_relationships(
        source.memory_id,
        min_score=20,
        tenant_id="test-tenant",
    )
    included_results = suggest_relationships(
        source.memory_id,
        min_score=20,
        include_tests=True,
        tenant_id="test-tenant",
    )

    assert all(
        item.memory.id != candidate.memory_id
        for item in default_results
    )
    assert any(
        item.memory.id == candidate.memory_id
        for item in included_results
    )
