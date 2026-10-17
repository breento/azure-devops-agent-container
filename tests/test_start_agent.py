import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = (ROOT / "scripts/start-agent.sh").read_text()


class StartAgentTests(unittest.TestCase):
    def run_agent(self, mode=None, token=None, identity=True, client_id=None, config_fails=False, run_fails=False):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = pathlib.Path(temporary.name)
        agent = root / "agent"
        bin_dir = root / "bin"
        agent.mkdir()
        bin_dir.mkdir()
        (agent / "config.sh").write_text(
            '#!/usr/bin/env bash\nprintf "%s:%s\\n" "$*" "${VSTS_AGENT_INPUT_TOKEN:-}" >> "$CALL_LOG"\n'
            + ('exit 9\n' if config_fails else 'exit 0\n')
        )
        (agent / "run.sh").write_text('#!/usr/bin/env bash\n' + ('exit 8\n' if run_fails else 'exit 0\n'))
        (agent / "config.sh").chmod(0o755)
        (agent / "run.sh").chmod(0o755)
        counter = root / "identity-count"
        (bin_dir / "curl").write_text(
            '#!/usr/bin/env bash\n'
            'cat >/dev/null\n'
            'n=0; [[ ! -f "$IDENTITY_COUNT" ]] || n=$(cat "$IDENTITY_COUNT")\n'
            'n=$((n+1)); printf "%s" "$n" > "$IDENTITY_COUNT"\n'
            'printf "{\\"access_token\\":\\"identity-token-%s\\"}" "$n"\n'
        )
        (bin_dir / "curl").chmod(0o755)
        (bin_dir / "setsid").write_text('#!/usr/bin/env bash\nexec "$@"\n')
        (bin_dir / "timeout").write_text('#!/usr/bin/env bash\nwhile [[ "$1" == -* ]]; do shift; [[ "$1" == *s ]] && shift; done\nshift\nexec "$@"\n')
        (bin_dir / "ps").write_text('#!/usr/bin/env bash\nexit 0\n')
        for utility in ("setsid", "timeout", "ps"):
            (bin_dir / utility).chmod(0o755)
        script_path = root / "start-agent.sh"
        script_path.write_text(SCRIPT.replace('readonly agent_root="/azp/agent"', f'readonly agent_root="{agent}"'))
        script_path.chmod(0o755)

        env = os.environ.copy()
        env.update({
            "PATH": f"{bin_dir}:{env['PATH']}", "AZP_URL": "https://dev.azure.com/example",
            "AZP_POOL": "test", "AZP_WORK": str(root / "work"), "CALL_LOG": str(root / "calls"),
            "IDENTITY_COUNT": str(counter), "AZP_AGENT_NAME": "test-agent",
        })
        if mode:
            env["AZP_AUTH"] = mode
        if token:
            env["AZP_TOKEN"] = token
        if identity:
            env.update({"IDENTITY_ENDPOINT": "http://identity.invalid/token", "IDENTITY_HEADER": "header-secret",
                        "AZP_MANAGED_IDENTITY_CLIENT_ID": client_id or "4ff6f360-6886-4bff-8ca2-d664e186bab5"})
        if config_fails:
            env["CONFIG_FAIL"] = "1"
        result = subprocess.run([str(script_path)], env=env, text=True, capture_output=True, timeout=30)
        calls = (root / "calls").read_text() if (root / "calls").exists() else ""
        count = int(counter.read_text()) if counter.exists() else 0
        return result, calls, count

    def test_default_pat_and_explicit_pat(self):
        for mode in (None, "pat"):
            with self.subTest(mode=mode):
                result, calls, count = self.run_agent(mode=mode, token="pat-secret")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("--acceptTeeEula", calls)
                self.assertIn("remove", calls)
                self.assertEqual(count, 0)
                self.assertIn("pat-secret", calls)  # config received token through environment
                self.assertNotIn("--token", calls)

    def test_managed_identity_uses_fresh_cleanup_token(self):
        result, calls, count = self.run_agent(mode="managedidentity", identity=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(count, 2)
        self.assertIn("--acceptTeeEula", calls)
        self.assertIn("identity-token-1", calls)
        self.assertIn("remove", calls)
        self.assertIn("identity-token-2", calls)
        self.assertNotIn("header-secret", result.stdout + result.stderr)

    def test_missing_identity_configuration_fails_without_pat_fallback(self):
        result, _, count = self.run_agent(mode="managedidentity", token="should-not-be-used", identity=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("IDENTITY_ENDPOINT", result.stderr)
        self.assertEqual(count, 0)

    def test_invalid_client_id_fails(self):
        result, _, count = self.run_agent(mode="managedidentity", client_id="not-a-guid")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("valid GUID", result.stderr)
        self.assertEqual(count, 0)

    def test_registration_failure_does_not_run_job(self):
        result, calls, _ = self.run_agent(mode="pat", token="pat-secret", config_fails=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Running one Azure DevOps pipeline job", result.stdout)
        self.assertIn("remove", calls)


if __name__ == "__main__":
    unittest.main()
