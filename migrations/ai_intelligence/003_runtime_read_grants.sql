BEGIN;

GRANT SELECT ON TABLE ai_intelligence.project_components
    TO openclaw_ai_runtime;

GRANT SELECT ON TABLE ai_intelligence.current_model_deployment
    TO openclaw_ai_runtime;

INSERT INTO ai_intelligence.schema_migrations (
    migration_id,
    description
)
VALUES (
    '003_runtime_read_grants',
    'Grant openclaw_ai_runtime read access required for runtime routing'
)
ON CONFLICT (migration_id) DO NOTHING;

COMMIT;
