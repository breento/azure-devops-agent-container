import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
DOCKERFILE = (ROOT / "Dockerfile").read_text()
WORKFLOW = (ROOT / ".github/workflows/build-container.yml").read_text()
VERIFY = (ROOT / "scripts/verify-tools.ps1").read_text()


class NonRootImageTests(unittest.TestCase):
    def test_fixed_nonroot_user_and_home_are_configured(self):
        users = re.findall(r"^USER\s+(.+)$", DOCKERFILE, re.MULTILINE)
        self.assertEqual(users, ["1001:1003"])
        self.assertIn("ENV HOME=/home/azp", DOCKERFILE)
        self.assertIn("useradd --uid 1001 --gid 1003 --create-home --home-dir /home/azp", DOCKERFILE)
        self.assertNotIn("AGENT_ALLOW_RUNASROOT", DOCKERFILE)

    def test_agent_workspace_home_and_tool_state_are_prepared(self):
        for fragment in (
            "/azp/agent/_diag",
            "/azp/_work",
            "/home/azp/.azure",
            "/home/azp/.cache",
            "/home/azp/.config",
            "/home/azp/.terraform.d",
            "chown -R 1001:1003 /azp/agent",
            'test "$(id -u)" = 1001',
            'test "$(id -g)" = 1003',
            "test ! -w /root",
            "> /azp/_work/.directory-write-test/job-file",
            "rm /azp/_work/.directory-write-test/job-file",
            "pwsh -NoLogo -NoProfile -File /azp/verify-tools.ps1",
        ):
            with self.subTest(fragment=fragment):
                self.assertIn(fragment, DOCKERFILE)

    def test_azure_cli_extensions_use_readable_system_directory(self):
        self.assertIn("ENV AZURE_EXTENSION_SYS_DIR=/opt/azure-cli-extensions", DOCKERFILE)
        self.assertIn("az extension add --name azure-devops --yes --system", DOCKERFILE)
        self.assertIn("az extension add --name containerapp --yes --allow-preview true --system", DOCKERFILE)

    def test_toolchain_validation_runs_for_both_image_architectures(self):
        self.assertIn("platforms: linux/amd64,linux/arm64", WORKFLOW)
        for tool in ("az", "git", "jq", "packer", "pwsh", "terraform"):
            self.assertRegex(VERIFY, rf"'{re.escape(tool)}'")
        for module in (
            "Az.Accounts", "Az.Resources", "Az.Storage", "Az.Compute", "Az.Network",
            "Az.ManagedServiceIdentity", "Az.DesktopVirtualization",
        ):
            self.assertIn(module, VERIFY)


if __name__ == "__main__":
    unittest.main()
