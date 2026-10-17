"""workspace.manage deterministic harness tests."""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

from ondevice_agent_platform.agents import (
    AgentService,
    AgentStopReason,
    PromptBlock,
    WorkspaceManageHarness,
    manage_workspace,
)


def _block(text: str) -> list:
    return [PromptBlock(kind="text", text=text)]


class TestManageWorkspace(unittest.TestCase):
    def test_report_covers_purges_and_git(self):
        with tempfile.TemporaryDirectory() as d:
            ws = Path(d)
            proj = ws / "alpha"
            (proj / "node_modules" / "dep").mkdir(parents=True)
            (proj / "node_modules" / "dep" / "x.js").write_bytes(b"x" * 2048)
            (proj / "app.js").write_text("1")
            subprocess.run(["git", "init", "-q"], cwd=proj, check=True)
            subprocess.run(
                ["git", "-C", str(proj), "config", "user.email", "t@t"],
                check=True)
            (proj / "untracked.py").write_text("pass")

            report = manage_workspace({
                "workspace": str(ws),
                "metrics": {"disk_status": "CRITICAL_LOW"},
            })
            self.assertTrue(report["ok"])
            entry = next(e for e in report["entries"]
                         if e["name"] == "alpha")
            self.assertTrue(entry["purge_candidates"])
            self.assertGreater(entry["reclaimable_bytes"], 0)
            self.assertEqual(report["purge_total_bytes"],
                             entry["reclaimable_bytes"])
            actions = {a["action"] for a in report["actions"]}
            self.assertIn("purge", actions)          # CRITICAL disk
            self.assertIn("git_hygiene", actions)    # dirty/untracked
            # fresh repo, no commits: everything is untracked
            self.assertEqual(entry["git"]["dirty_files"], 3)

    def test_missing_workspace(self):
        report = manage_workspace({"workspace": "/nonexistent-xyz"})
        self.assertFalse(report["ok"])
        self.assertIn("error", report)


class TestWorkspaceManageHarness(unittest.TestCase):
    def _run(self, text: str):
        chunks = []
        reason = WorkspaceManageHarness().run(
            _block(text), context=None, emit=lambda k, t: chunks.append(t))
        return reason, chunks

    def test_json_task_returns_report(self):
        with tempfile.TemporaryDirectory() as d:
            reason, chunks = self._run(json.dumps({"workspace": d}))
            self.assertEqual(reason, AgentStopReason.END_TURN)
            report = json.loads("".join(chunks))
            self.assertTrue(report["ok"])
            self.assertEqual(report["agent"], "workspace.manage")

    def test_bare_path_accepted(self):
        with tempfile.TemporaryDirectory() as d:
            reason, chunks = self._run(d)
            self.assertEqual(reason, AgentStopReason.END_TURN)
            self.assertTrue(json.loads("".join(chunks))["ok"])

    def test_empty_prompt_refused(self):
        reason, _ = self._run("   ")
        self.assertEqual(reason, AgentStopReason.REFUSAL)


class TestRegistration(unittest.TestCase):
    def test_registered_profile(self):
        service = AgentService()
        service.register_builtin_workspace()
        self.assertIn("workspace.manage", service.profile_ids())
        session = service.new_session(
            "workspace.manage", consumer_id="c1", connection_id="k1")
        self.assertEqual(session.profile.harness_id, "workspace.manage")


if __name__ == "__main__":
    unittest.main()
