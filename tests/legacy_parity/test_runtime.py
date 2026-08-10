import json
import os
import stat
import tempfile
import unittest
from pathlib import Path

from tools.legacy_parity.runtime import (
    load_scenario,
    loads_scenario,
    render_harness,
    run_scenario,
)


FIXTURE = Path(__file__).resolve().parent / "fixtures" / "runtime"


class RuntimeHarnessTests(unittest.TestCase):
    def setUp(self):
        self.scenario = load_scenario(FIXTURE / "sample_scenario.json")
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def test_schema_binds_safe_scenario_and_target_identity(self):
        self.assertEqual(self.scenario.key, "sample-runtime")
        self.assertEqual(self.scenario.target_key, "sample-target")
        base = json.loads(
            (FIXTURE / "sample_scenario.json").read_text(encoding="utf-8")
        )
        cases = (
            ("key", None),
            ("key", ""),
            ("key", "../escape"),
            ("key", "nested/escape"),
            ("target_key", None),
            ("target_key", ""),
            ("target_key", "/alternate"),
            ("target_key", "nested\\escape"),
        )
        for index, (field, value) in enumerate(cases):
            with self.subTest(field=field, value=value):
                changed = dict(base)
                if value is None:
                    changed.pop(field)
                else:
                    changed[field] = value
                path = self.root / f"identity-{index}.json"
                path.write_text(json.dumps(changed), encoding="utf-8")
                with self.assertRaisesRegex(
                    ValueError, "invalid_runtime_scenario"
                ):
                    load_scenario(path)

    def test_bytes_loader_parses_the_exact_captured_scenario(self):
        path = self.root / "mutable-scenario.json"
        path.write_bytes(
            (FIXTURE / "sample_scenario.json").read_bytes()
        )
        captured = path.read_bytes()
        path.write_text("{}", encoding="utf-8")

        self.assertEqual(loads_scenario(captured), self.scenario)
        with self.assertRaisesRegex(
            ValueError, "invalid_runtime_scenario"
        ):
            load_scenario(path)

    def test_bytes_loader_rejects_malformed_nested_types(self):
        base = json.loads(
            (FIXTURE / "sample_scenario.json").read_text(encoding="utf-8")
        )
        cases = (
            {
                **base,
                "expected": {
                    "effects": None,
                    "registrations": base["expected"]["registrations"],
                },
            },
            {
                **base,
                "operations": [
                    {
                        "op": "call",
                        "name": None,
                        "args": [],
                        "expect": None,
                    }
                ],
            },
        )
        for value in cases:
            with self.subTest(value=value):
                with self.assertRaisesRegex(
                    ValueError, "invalid_runtime_scenario"
                ):
                    loads_scenario(json.dumps(value).encode("utf-8"))

    def fake_lera(self, *, sleeping=False):
        executable = self.root / ("sleeping-lera" if sleeping else "fake-lera")
        log = executable.with_suffix(".log")
        sleep_line = "sleep 5\n" if sleeping else ""
        executable.write_text(
            "#!/bin/sh\n"
            f"{sleep_line}"
            f"printf '%s\\n' \"$#\" > '{log}'\n"
            f"printf '%s\\n' \"$1\" >> '{log}'\n"
            f"find \"$1\" -mindepth 1 -printf '%P\\n' | sort >> '{log}'\n"
            "printf 'fake stdout\\n'\n"
            "printf 'fake stderr\\n' >&2\n",
            encoding="utf-8",
        )
        executable.chmod(
            executable.stat().st_mode | stat.S_IXUSR
        )
        return executable, log

    def test_temporary_profile_is_minimal_captured_and_removed(self):
        executable, log = self.fake_lera()
        os.environ["PARITY_PRIVATE_SENTINEL"] = "must-not-propagate"
        try:
            result = run_scenario(
                executable,
                FIXTURE,
                self.scenario,
                timeout=2,
            )
        finally:
            os.environ.pop("PARITY_PRIVATE_SENTINEL", None)
        lines = log.read_text(encoding="utf-8").splitlines()
        self.assertEqual(lines[0], "1")
        profile = Path(lines[1])
        self.assertFalse(profile.exists())
        self.assertEqual(
            set(lines[2:]),
            {
                ".storage",
                "init.lua",
                "plugins",
                "plugins/sample_plugin.lua",
                "profile.conf",
            },
        )
        self.assertEqual(result.exit_code, 0)
        self.assertEqual(result.stdout, "fake stdout\n")
        self.assertEqual(result.stderr, "fake stderr\n")
        self.assertNotIn(str(Path.home()), result.harness)

    def test_harness_saves_real_loader_then_installs_closed_stubs(self):
        harness = render_harness(self.scenario)
        self.assertIn("local real_plugin_load = plugin.load", harness)
        self.assertIn(
            'real_plugin_load(assert(os.getenv("PARITY_PLUGIN")))',
            harness,
        )
        for captured in (
            "mud.send",
            "send_raw",
            "push.send",
            "ipc.broadcast",
            "websocket.broadcast",
            "timer.every",
            "ui.text",
            "print",
            "store.save",
            "mip.on",
            "alias.add",
            "trigger.add",
        ):
            self.assertIn(captured, harness)
        self.assertIn("undeclared plugin dependency", harness)
        self.assertIn("mud.connect = function", harness)
        self.assertIn("lera.quit()", harness)
        self.assertNotIn("sleep(", harness)

    def test_schema_rejects_executable_or_external_escape_values(self):
        base = json.loads(
            (FIXTURE / "sample_scenario.json").read_text(encoding="utf-8")
        )
        cases = (
            {**base, "lua": "mud.connect('host', 1)"},
            {**base, "plugin": "/home/example/live.lua"},
            {**base, "plugin": "../escape.lua"},
            {**base, "operations": [{"op": "sleep", "seconds": 1}]},
            {**base, "operations": [{"op": "shell", "command": "true"}]},
            {**base, "operations": [{"op": "socket", "host": "localhost"}]},
            {**base, "dependencies": {"undeclared/../../bad": {}}},
        )
        for index, value in enumerate(cases):
            with self.subTest(index=index):
                path = self.root / f"unsafe-{index}.json"
                path.write_text(json.dumps(value), encoding="utf-8")
                with self.assertRaisesRegex(
                    ValueError, "invalid_runtime_scenario"
                ):
                    load_scenario(path)

    def test_timeout_is_enforced_and_profile_is_removed(self):
        executable, log = self.fake_lera(sleeping=True)
        with self.assertRaisesRegex(RuntimeError, "runtime_timeout"):
            run_scenario(
                executable,
                FIXTURE,
                self.scenario,
                timeout=0.05,
            )
        self.assertFalse(log.exists())

    @unittest.skipUnless(
        os.environ.get("LERA_TEST_BIN")
        and Path(os.environ["LERA_TEST_BIN"]).is_file(),
        "LERA_TEST_BIN is not available",
    )
    def test_real_lera_loads_only_synthetic_fixture_without_connecting(self):
        result = run_scenario(
            Path(os.environ["LERA_TEST_BIN"]),
            FIXTURE,
            self.scenario,
            timeout=10,
        )
        self.assertEqual(result.exit_code, 0, result.stderr)
        self.assertNotIn("connect", result.stderr.lower())


if __name__ == "__main__":
    unittest.main()
