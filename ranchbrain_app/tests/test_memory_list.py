from ranchbrain.memory_store import remember, list_memories

def test_list_memories_by_module():
    remember(
        tenant_id="test-tenant",
        module="property",
        category="test",
        title="Memory list test",
        body="This memory should appear in the property memory list.",
        memory_type="event",
        tags=["list", "test"],
    )

    items = list_memories(module="property", limit=10, tenant_id="test-tenant")
    assert isinstance(items, list)
    assert len(items) > 0
