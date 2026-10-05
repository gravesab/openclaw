"""Exercise candidate evaluation over an isolated loopback HTTP server."""

import contextlib
import io
import json
import tempfile
import threading
import unittest
from http.client import IncompleteRead
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

from tools.ai_intelligence import run_local_candidate_eval as evaluation


def completion(content=None, *, calls=None, finish="stop", reasoning=None):
    message = {"role": "assistant", "content": content}
    if calls is not None:
        message["tool_calls"] = calls
    if reasoning is not None:
        message["reasoning_content"] = reasoning
    return {"choices": [{"message": message, "finish_reason": finish}],
            "usage": {"completion_tokens": 12}}


class CandidateEvaluationTests(unittest.TestCase):
    def setUp(self):
        self.requests = []
        self.reply = None
        self.catalog = {"data": [{"id": "muse-glimmer-30b-dev"}]}
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                owner.requests.append((self.path, None))
                self.respond(owner.catalog)

            def respond(self, data):
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps(data).encode())

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                owner.requests.append((self.path, body))
                if owner.reply is not None:
                    self.respond(owner.reply)
                elif "response_format" in body:
                    self.respond(completion('{"interval_hours":25,"source_page":3}'))
                elif "tools" in body:
                    self.respond(completion(calls=[{"id": "fixture-1", "type": "function",
                        "function": {"name": "lookup_asset", "arguments": '{"asset_id":"demo-pump"}'}}],
                        finish="tool_calls"))
                elif body["messages"][-1]["role"] == "tool":
                    self.respond(completion("inspection_due"))
                else:
                    self.respond(completion("Synthetic answer for human review."))

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.client = evaluation.LocalClient(
            f"http://127.0.0.1:{self.server.server_port}/v1", "muse-glimmer-30b-dev")

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def test_roundtrip_records_smoke_and_unscored_benchmarks(self):
        report = evaluation.run(self.client, 2)
        self.assertEqual(report["status"], "needs_human_review")
        self.assertFalse(report["promotion_eligible"])
        self.assertEqual(len(report["results"]), 14)
        self.assertEqual(sum(r["status"] == "passed" for r in report["results"]), 4)
        posts = [body for _, body in self.requests if body]
        continuation = next(b for b in posts if b["messages"][-1]["role"] == "tool")
        self.assertEqual(continuation["messages"][-1]["tool_call_id"], "fixture-1")
        self.assertTrue(all(b["model"] == self.client.model and b["stream"] is False for b in posts))

    def test_missing_model_blocks_before_generation(self):
        self.catalog = {"data": [{"id": "some-other-model"}]}
        report = evaluation.run(self.client, 1)
        self.assertEqual(report["status"], "blocked")
        self.assertEqual(len(self.requests), 1)

    def test_truncation_and_reasoning_only_never_pass(self):
        for payload in [completion("partial", finish="length"),
                        completion("answer", finish=[]), completion("answer", finish={}),
                        completion(reasoning="The answer is 25"),
                        completion("<think>hidden</think>answer"), {"choices": [None]}]:
            with self.subTest(payload=payload):
                self.reply = payload
                report = evaluation.run(self.client, 1)
                self.assertEqual(report["status"], "failed")
                self.assertTrue(all(r["status"] == "failed" for r in report["results"]))

    def test_failed_cases_retain_rejected_content_and_usage(self):
        self.reply = completion('{"interval_hours":99,"source_page":3}')
        report = evaluation.run(self.client, 1)
        first = report["results"][0]
        self.assertEqual(first["status"], "failed")
        saved = json.loads(first["response_evidence"][0]["raw_response"])
        self.assertEqual(saved, self.reply)
        self.assertFalse(first["response_evidence"][0]["truncated"])

    def test_wrong_extraction_and_tool_are_rejected(self):
        self.reply = completion('{"interval_hours":false,"source_page":3}')
        with self.assertRaises(evaluation.EvaluationError):
            evaluation.extraction_probe(self.client)
        self.reply = completion(calls=[{"id": "bad", "type": "function",
            "function": {"name": "delete_asset", "arguments": "{}"}}], finish="tool_calls")
        with self.assertRaises(evaluation.EvaluationError):
            evaluation.tool_probe(self.client)
        self.assertEqual(len(self.requests), 2)

    def test_endpoint_boundary(self):
        for url in ["https://example.com/v1", "http://localhost:80/v1",
                    "http://192.168.1.2:80/v1", "http://user:secret@127.0.0.1:80/v1",
                    "http://127.0.0.1/v1", "http://127.0.0.1:80/v1?key=secret"]:
            with self.subTest(url=url), self.assertRaises(evaluation.EvaluationError):
                evaluation.LocalClient(url, "model")

    def test_dry_run_makes_no_requests(self):
        with patch.object(evaluation.LocalClient, "request", side_effect=AssertionError("network")):
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(evaluation.main([]), 0)

    def test_report_cannot_overwrite_existing_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "existing.json"
            path.write_text("preserved")
            with self.assertRaises(FileExistsError):
                evaluation.main(["--execute", "--output", str(path)])
            self.assertEqual(path.read_text(), "preserved")
            self.assertEqual(self.requests, [])

    def test_transport_timeout_is_reported(self):
        with patch.object(self.client.opener, "open", side_effect=TimeoutError):
            report = evaluation.run(self.client, 1)
        self.assertEqual(report["status"], "blocked")
        self.assertIn("timed out", report["error"])

    def test_interrupted_http_preserves_partial_evidence_and_finishes_report(self):
        with patch.object(self.client, "verify_model"):
            with patch.object(self.client.opener, "open", side_effect=IncompleteRead(b'{"choices":')):
                report = evaluation.run(self.client, 1)
        self.assertEqual(report["status"], "failed")
        self.assertEqual(len(report["results"]), 7)
        for record in report["results"]:
            self.assertEqual(record["status"], "failed")
            self.assertEqual(record["response_evidence"][0]["raw_response"], '{"choices":')
            self.assertTrue(record["response_evidence"][0]["truncated"])

    def test_redirects_are_not_followed(self):
        self.assertIsNone(evaluation.NoRedirects().redirect_request(
            None, None, 302, "", {}, "https://example.com"))


if __name__ == "__main__":
    unittest.main()
