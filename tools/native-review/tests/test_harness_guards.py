"""The setup and relay scripts must never act on a machine, port or database that
is not the harness's own. These run the real shell scripts against stub binaries."""
import os
import pathlib
import stat
import subprocess
import tempfile
import unittest

TOOL = pathlib.Path(__file__).parents[1]
REPO = TOOL.parents[1]
CHECK = TOOL / "bin/check-harness-database"
SETUP = TOOL / "bin/setup-macos-vm"
RELAY = REPO / "scripts/start-isolated-test-relay.sh"

# A psql that answers from environment variables and records every statement.
STUB_PSQL = """#!/bin/bash
sql=""
while [[ $# -gt 0 ]]; do
  case "$1" in -c|-qtAc|-qc) sql="$2"; shift 2 ;; *) shift ;; esac
done
echo "$sql" >> "$STUB_LOG"
case "$sql" in
  # Stop the relay script right after the reset: nothing after it may run in a test.
  *"DROP SCHEMA"*) exit 3 ;;
  "SHOW data_directory") [[ -n "${STUB_DATA_DIR:-}" ]] && echo "$STUB_DATA_DIR" || exit 2 ;;
  *shobj_description*) [[ -n "${STUB_COMMENT+x}" ]] && echo "$STUB_COMMENT" ;;
esac
exit 0
"""


def write_exe(path: pathlib.Path, body: str) -> None:
    path.write_text(body)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class Sandbox(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = pathlib.Path(self.tmp.name).resolve()
        self.stubs = root / "stubs"
        self.stubs.mkdir()
        self.state = root / "state"
        (self.state / "postgres").mkdir(parents=True)
        self.foreign = root / "foreign-postgres"
        self.foreign.mkdir()
        self.log = root / "psql.log"
        self.log.write_text("")
        write_exe(self.stubs / "psql", STUB_PSQL)

    def mark_state(self):
        (self.state / ".buzz-native-review-harness").write_text("buzz-native-review-harness\n")

    def env(self, **extra):
        env = {
            "PATH": f"{self.stubs}:/usr/bin:/bin",
            "HOME": self.tmp.name,
            "STUB_LOG": str(self.log),
        }
        env.update(extra)
        return env

    def run_script(self, args, **extra):
        return subprocess.run(args, env=self.env(**extra), capture_output=True, text=True, timeout=60)

    def statements(self):
        return self.log.read_text()


class CheckHarnessDatabaseTests(Sandbox):
    def check(self, **extra):
        return self.run_script([str(CHECK), "--state-dir", str(self.state)], **extra)

    def test_accepts_the_harness_database(self):
        self.mark_state()
        result = self.check(STUB_DATA_DIR=str(self.state / "postgres"), STUB_COMMENT="buzz-native-review-harness")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_refuses_a_server_running_from_another_data_directory(self):
        self.mark_state()
        result = self.check(STUB_DATA_DIR=str(self.foreign), STUB_COMMENT="buzz-native-review-harness")
        self.assertEqual(result.returncode, 1)
        self.assertIn("not the harness data dir", result.stderr)

    def test_refuses_an_unmarked_database(self):
        self.mark_state()
        for comment in ("", "someone else's database"):
            result = self.check(STUB_DATA_DIR=str(self.state / "postgres"), STUB_COMMENT=comment)
            self.assertEqual(result.returncode, 1, comment)
            self.assertIn("not marked", result.stderr)

    def test_refuses_without_the_state_dir_marker_file(self):
        result = self.check(STUB_DATA_DIR=str(self.state / "postgres"), STUB_COMMENT="buzz-native-review-harness")
        self.assertEqual(result.returncode, 1)
        self.assertIn("not a harness state dir", result.stderr)

    def test_refuses_when_the_server_cannot_be_read(self):
        self.mark_state()
        result = self.check(STUB_COMMENT="buzz-native-review-harness")  # no data dir: psql fails
        self.assertEqual(result.returncode, 1)
        self.assertIn("cannot read data_directory", result.stderr)

    def test_refuses_without_a_state_dir(self):
        result = self.run_script([str(CHECK)])
        self.assertEqual(result.returncode, 1)


class SetupVmGuardTests(Sandbox):
    def setUp(self):
        super().setUp()
        write_exe(self.stubs / "uname", '#!/bin/bash\n[[ "$1" == "-m" ]] && echo arm64 || echo Darwin\n')

    def sysctl(self, vmm: str):
        write_exe(self.stubs / "sysctl", f'#!/bin/bash\n[[ "$2" == "kern.hv_vmm_present" ]] && echo {vmm} || echo Mac15,9\n')

    def setup(self, *flags):
        return self.run_script([str(SETUP), "--state-dir", str(self.state), *flags])

    def test_refuses_outside_a_vm_before_touching_anything(self):
        self.sysctl("0")
        result = self.setup()
        self.assertEqual(result.returncode, 1)
        self.assertIn("does not look like a virtual machine", result.stderr)
        self.assertFalse((self.state / ".buzz-native-review-harness").exists())

    def test_allow_non_vm_is_an_explicit_opt_in(self):
        self.sysctl("0")
        result = self.setup("--allow-non-vm")
        self.assertIn("continuing because --allow-non-vm", result.stdout)
        self.assertNotIn("does not look like a virtual machine", result.stderr)
        self.assertIn("Homebrew is required", result.stderr)  # got past the guard, stopped at the stubbed PATH

    def test_a_vm_passes_the_guard(self):
        self.sysctl("1")
        result = self.setup()
        self.assertNotIn("virtual machine", result.stderr)
        self.assertIn("Homebrew is required", result.stderr)


class RelayResetGuardTests(Sandbox):
    def relay(self, **extra):
        write_exe(self.stubs / "pg_isready", "#!/bin/bash\nexit 0\n")
        return self.run_script([str(RELAY)], BUZZ_HARNESS_NATIVE_SERVICES="1", **extra)

    def assertNoReset(self, result):
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("DROP SCHEMA", self.statements())

    def test_native_mode_without_a_state_dir_never_drops(self):
        result = self.relay(STUB_DATA_DIR=str(self.state / "postgres"), STUB_COMMENT="buzz-native-review-harness")
        self.assertNoReset(result)
        self.assertIn("BUZZ_HARNESS_STATE_DIR", result.stderr)

    def test_native_mode_against_a_foreign_postgres_never_drops(self):
        self.mark_state()
        result = self.relay(BUZZ_HARNESS_STATE_DIR=str(self.state), STUB_DATA_DIR=str(self.foreign),
                            STUB_COMMENT="buzz-native-review-harness")
        self.assertNoReset(result)
        self.assertIn("refusing to reset", result.stderr)

    def test_native_mode_against_an_unmarked_database_never_drops(self):
        self.mark_state()
        result = self.relay(BUZZ_HARNESS_STATE_DIR=str(self.state), STUB_DATA_DIR=str(self.state / "postgres"),
                            STUB_COMMENT="")
        self.assertNoReset(result)

    def test_the_harness_database_is_reset(self):
        self.mark_state()
        result = self.relay(BUZZ_HARNESS_STATE_DIR=str(self.state), STUB_DATA_DIR=str(self.state / "postgres"),
                   STUB_COMMENT="buzz-native-review-harness")
        self.assertIn("DROP SCHEMA", self.statements())
        self.assertEqual(result.returncode, 3)  # the stub aborts the script at the reset


if __name__ == "__main__":
    unittest.main()
