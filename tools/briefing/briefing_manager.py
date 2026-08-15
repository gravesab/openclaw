import json
import os
import subprocess
import redis
import psycopg2
from datetime import datetime

r = redis.Redis(
    host="127.0.0.1",
    port=6379,
    decode_responses=True
)

DB = {
    "host": os.environ.get("OPENCLAW_DB_HOST", "127.0.0.1"),
    "port": int(os.environ.get("OPENCLAW_DB_PORT", "5432")),
    "dbname": os.environ.get("OPENCLAW_DB_NAME", "openclaw"),
    "user": os.environ.get("OPENCLAW_DB_USER", "openclaw"),
    "password": os.environ.get("OPENCLAW_DB_PASSWORD"),
}

DOCKER_CONTAINER = os.environ.get("OPENCLAW_DB_CONTAINER", "postgres")
USE_DOCKER = os.environ.get("OPENCLAW_DB_VIA_DOCKER", "").strip().lower() in {
    "1",
    "true",
    "yes",
}

def get_recent_events():
    raw = r.lrange("openclaw:events", 0, 10)
    events = []

    for item in raw:
        try:
            events.append(json.loads(item))
        except Exception:
            pass

    return events

def get_recent_memories():
    if USE_DOCKER:
        sql = """
            SELECT COALESCE(json_agg(row_to_json(memory_rows)), '[]'::json)::text
            FROM (
                SELECT agent_name, category, LEFT(content, 600) AS content, created_at
                FROM long_term_memory
                WHERE category != 'gmail_summary'
                ORDER BY created_at DESC
                LIMIT 5
            ) AS memory_rows
        """
        result = subprocess.run(
            [
                "docker",
                "exec",
                DOCKER_CONTAINER,
                "psql",
                "-U",
                DB["user"],
                "-d",
                DB["dbname"],
                "-Atqc",
                sql,
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        return json.loads(result.stdout.strip() or "[]")

    conn = psycopg2.connect(**DB)
    cur = conn.cursor()

    cur.execute("""
        SELECT agent_name, category, LEFT(content, 600), created_at
        FROM long_term_memory
        WHERE category != 'gmail_summary'
        ORDER BY created_at DESC
        LIMIT 5
    """)

    rows = cur.fetchall()

    cur.close()
    conn.close()

    return [
        {
            "agent_name": row[0],
            "category": row[1],
            "content": row[2],
            "created_at": row[3],
        }
        for row in rows
    ]


def main():
    print("=" * 60)
    print("OPENCLAW DAILY BRIEFING")
    print("=" * 60)

    print()
    print("Generated:", datetime.now())

    print()
    print("=" * 60)
    print("RECENT EVENTS")
    print("=" * 60)

    events = get_recent_events()

    if not events:
        print("No recent events found.")
    else:
        for event in events:
            print()
            print(f"[{event.get('agent', 'Unknown')}] {event.get('type', 'unknown')}")
            print(event.get("message", ""))

    print()
    print("=" * 60)
    print("RECENT NON-GMAIL MEMORIES")
    print("=" * 60)

    memories = get_recent_memories()

    if not memories:
        print("No recent non-Gmail memories found.")
    else:
        for memory in memories:
            print()
            print(f"Agent: {memory['agent_name']}")
            print(f"Category: {memory['category']}")
            print(f"Content: {memory['content']}")
            print(f"Created: {memory['created_at']}")


if __name__ == "__main__":
    main()
