"""Offline tests: python3 .github/workflows/scripts/test-publish-preparation.py.

Requires PyYAML, Bash, and Git. Runs the workflow's preparation script against
temporary local Git repositories; no GitHub, build, or publishing access.
"""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml


WORKFLOW = yaml.safe_load((Path(__file__).resolve().parents[1] / "update.yml").read_text())
SCRIPT = next(step["run"] for step in WORKFLOW["jobs"]["update"]["steps"]
              if step.get("id") == "prepare")


class PublishPreparation(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="capkgs-publish-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.remote = self.root / "remote"
        self.remote.mkdir()
        self.env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
        self.git(self.remote, "init", "-q", "-b", "main")
        self.git(self.remote, "config", "user.name", "Test")
        self.git(self.remote, "config", "user.email", "test@example.invalid")
        self.sha = self.commit("initial metadata")
        self.checkout = self.root / "checkout"
        self.git(self.root, "clone", "-q", "--depth=1", self.remote.as_uri(), str(self.checkout))
        self.git(self.checkout, "checkout", "-q", "--detach")
        self.output = self.root / "output"
        self.env.update(GITHUB_SHA=self.sha, GITHUB_OUTPUT=str(self.output))

    def git(self, directory, *args):
        return subprocess.run(["git", *args], cwd=directory, env=self.env,
                              text=True, capture_output=True, check=True).stdout.strip()

    def commit(self, text):
        (self.remote / "packages.json").write_text(text + "\n")
        self.git(self.remote, "add", "packages.json")
        self.git(self.remote, "commit", "-q", "-m", text)
        return self.git(self.remote, "rev-parse", "HEAD")

    def execute(self):
        return subprocess.run(["bash", "-e", "-o", "pipefail", "-c", SCRIPT],
                              cwd=self.checkout, env=self.env, text=True, capture_output=True)

    def test_current_run_prepares_main_for_push(self):
        result = self.execute()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.output.read_text(), "current=true\n")
        self.assertEqual(self.git(self.checkout, "branch", "--show-current"), "main")
        self.assertEqual(self.git(self.checkout, "rev-parse", "HEAD"), self.sha)
        self.assertEqual(self.git(self.checkout, "config", "branch.main.remote"), "origin")
        self.assertEqual(self.git(self.checkout, "config", "branch.main.merge"), "refs/heads/main")

    def test_prior_publisher_advancing_main_skips_queued_run(self):
        latest = self.commit("metadata from first publisher")
        result = self.execute()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.output.read_text(), "current=false\n")
        self.assertIn("Skipping superseded publish", result.stdout)
        self.assertIn(latest, result.stdout)
        self.assertEqual(self.git(self.checkout, "rev-parse", "HEAD"), self.sha)
        self.assertEqual(self.git(self.checkout, "branch", "--show-current"), "")

    def test_fetch_failure_does_not_authorize_publishing(self):
        self.git(self.checkout, "remote", "set-url", "origin", (self.root / "missing").as_uri())
        result = self.execute()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
