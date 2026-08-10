"""Offline runtime validation in a disposable Lera profile."""

from __future__ import annotations

import json
import math
import os
import re
import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath


_NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
_EFFECT_KINDS = frozenset(
    {
        "alias.add",
        "trigger.add",
        "timer.every",
        "timer.after",
        "mip.on",
        "mud.send",
        "send_raw",
        "push.send",
        "push.notify",
        "push.alert",
        "ipc.send",
        "ipc.broadcast",
        "websocket.send",
        "websocket.broadcast",
        "ui.text",
        "ui.box",
        "buffer.color_print",
        "print",
        "store.load",
        "store.get",
        "store.set",
        "store.save",
        "plugin.get",
        "plugin.load",
    }
)
_UNSAFE_TEXT = (
    "/home/",
    "/Users/",
    "\\Users\\",
    "../",
    ".storage",
    "mud.connect",
    "os.execute",
    "io.popen",
)


@dataclass(frozen=True)
class Scenario:
    version: int
    plugin: str
    clock_ms: int
    store_seed: dict
    dependencies: dict
    operations: tuple[dict, ...]
    expected_effects: tuple[dict, ...]
    expected_registrations: dict


@dataclass(frozen=True, slots=True)
class RuntimeOutcome:
    exit_code: int
    stdout: str
    stderr: str
    harness: str


def _json_data(value):
    if value is None or isinstance(value, (str, bool, int)):
        return True
    if isinstance(value, float):
        return math.isfinite(value)
    if isinstance(value, list):
        return all(_json_data(item) for item in value)
    if isinstance(value, dict):
        return all(
            isinstance(key, str) and _json_data(item)
            for key, item in value.items()
        )
    return False


def _unsafe_text(value):
    if isinstance(value, str):
        return any(marker in value for marker in _UNSAFE_TEXT)
    if isinstance(value, list):
        return any(_unsafe_text(item) for item in value)
    if isinstance(value, dict):
        return any(
            _unsafe_text(key) or _unsafe_text(item)
            for key, item in value.items()
        )
    return False


def _operation(value):
    if not isinstance(value, dict):
        raise ValueError("invalid_runtime_scenario")
    operation = value.get("op")
    if operation in {"call", "hook"}:
        if set(value) != {"op", "name", "args", "expect"}:
            raise ValueError("invalid_runtime_scenario")
        if not _NAME_RE.fullmatch(value["name"]):
            raise ValueError("invalid_runtime_scenario")
        if not isinstance(value["args"], list) or not _json_data(
            value["expect"]
        ):
            raise ValueError("invalid_runtime_scenario")
    elif operation in {"invoke_alias", "invoke_trigger"}:
        if set(value) != {"op", "index", "args", "expect"}:
            raise ValueError("invalid_runtime_scenario")
        if (
            not isinstance(value["index"], int)
            or value["index"] < 1
            or not isinstance(value["args"], list)
            or not _json_data(value["expect"])
        ):
            raise ValueError("invalid_runtime_scenario")
    elif operation == "invoke_mip":
        if set(value) != {"op", "name", "args", "expect"}:
            raise ValueError("invalid_runtime_scenario")
        if (
            not isinstance(value["name"], str)
            or not value["name"]
            or not isinstance(value["args"], list)
            or not _json_data(value["expect"])
        ):
            raise ValueError("invalid_runtime_scenario")
    elif operation == "advance":
        if set(value) != {"op", "ms"} or (
            not isinstance(value["ms"], int) or value["ms"] < 0
        ):
            raise ValueError("invalid_runtime_scenario")
    else:
        raise ValueError("invalid_runtime_scenario")
    if not _json_data(value) or _unsafe_text(value):
        raise ValueError("invalid_runtime_scenario")
    return dict(value)


def load_scenario(path) -> Scenario:
    try:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError("invalid_runtime_scenario") from error
    required = {
        "version",
        "plugin",
        "clock_ms",
        "store_seed",
        "dependencies",
        "operations",
        "expected",
    }
    if not isinstance(value, dict) or set(value) != required:
        raise ValueError("invalid_runtime_scenario")
    plugin = value["plugin"]
    if (
        value["version"] != 1
        or not isinstance(plugin, str)
        or not plugin.endswith(".lua")
        or plugin.startswith("/")
        or "\\" in plugin
        or any(part in {"", ".", ".."} for part in PurePosixPath(plugin).parts)
        or not isinstance(value["clock_ms"], int)
        or value["clock_ms"] < 0
        or not isinstance(value["store_seed"], dict)
        or not isinstance(value["dependencies"], dict)
        or not isinstance(value["operations"], list)
        or _unsafe_text(value)
        or not _json_data(value)
    ):
        raise ValueError("invalid_runtime_scenario")
    if any(
        not _NAME_RE.fullmatch(key)
        or not isinstance(interface, dict)
        for key, interface in value["dependencies"].items()
    ):
        raise ValueError("invalid_runtime_scenario")
    expected = value["expected"]
    if not isinstance(expected, dict) or set(expected) != {
        "effects",
        "registrations",
    }:
        raise ValueError("invalid_runtime_scenario")
    effects = []
    for effect in expected["effects"]:
        if (
            not isinstance(effect, dict)
            or set(effect) not in ({"kind"}, {"kind", "args"})
            or effect.get("kind") not in _EFFECT_KINDS
            or ("args" in effect and not isinstance(effect["args"], list))
        ):
            raise ValueError("invalid_runtime_scenario")
        effects.append(dict(effect))
    registrations = expected["registrations"]
    if (
        not isinstance(registrations, dict)
        or set(registrations) != {"aliases", "triggers", "timers", "mip"}
        or any(
            not isinstance(count, int) or count < 0
            for count in registrations.values()
        )
    ):
        raise ValueError("invalid_runtime_scenario")
    return Scenario(
        version=1,
        plugin=plugin,
        clock_ms=value["clock_ms"],
        store_seed=dict(value["store_seed"]),
        dependencies=dict(value["dependencies"]),
        operations=tuple(_operation(item) for item in value["operations"]),
        expected_effects=tuple(effects),
        expected_registrations=dict(registrations),
    )


def _lua(value):
    if value is None:
        return "nil"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, (int, float)):
        return repr(value)
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, (list, tuple)):
        return "{" + ",".join(_lua(item) for item in value) + "}"
    if isinstance(value, dict):
        return (
            "{"
            + ",".join(
                f"[{_lua(key)}]={_lua(value[key])}"
                for key in sorted(value)
            )
            + "}"
        )
    raise ValueError("invalid_runtime_scenario")


def _operation_lua(operation):
    args = _lua(operation.get("args", []))
    expected = _lua(operation.get("expect"))
    if operation["op"] in {"call", "hook"}:
        return (
            f'do local actual = target[{_lua(operation["name"])}]'
            f"(unpack({args})); "
            f"assert(deep_equal(actual, {expected}), "
            f"{_lua('unexpected operation return')}) end"
        )
    if operation["op"] == "invoke_alias":
        return (
            f"do local actual = aliases[{operation['index']}].callback"
            f"(unpack({args})); assert(deep_equal(actual, {expected}), "
            f"{_lua('unexpected alias return')}) end"
        )
    if operation["op"] == "invoke_trigger":
        return (
            f"do local actual = triggers[{operation['index']}].callback"
            f"(unpack({args})); assert(deep_equal(actual, {expected}), "
            f"{_lua('unexpected trigger return')}) end"
        )
    if operation["op"] == "invoke_mip":
        return (
            f"do local actual = mip_handlers[{_lua(operation['name'])}]"
            f"(unpack({args})); assert(deep_equal(actual, {expected}), "
            f"{_lua('unexpected MIP return')}) end"
        )
    return (
        f"advance_clock({operation['ms']})"
    )


def render_harness(scenario) -> str:
    operations = "\n".join(
        _operation_lua(operation) for operation in scenario.operations
    )
    effect_assertions = []
    for index, effect in enumerate(scenario.expected_effects, 1):
        effect_assertions.append(
            f"assert(effects[{index}] and "
            f"effects[{index}].kind == {_lua(effect['kind'])}, "
            f"{_lua('unexpected effect order')})"
        )
        if "args" in effect:
            effect_assertions.append(
                f"assert(deep_equal(effects[{index}].args, "
                f"{_lua(effect['args'])}), {_lua('unexpected effect arguments')})"
            )
    effect_assertions.append(
        f"assert(#effects == {len(scenario.expected_effects)}, "
        f"{_lua('unexpected effect count')})"
    )
    effects = "\n".join(effect_assertions)
    registration_assertions = "\n".join(
        (
            f"assert(#{name} == {scenario.expected_registrations[label]}, "
            f"{_lua('unexpected registration count')})"
        )
        for label, name in (
            ("aliases", "aliases"),
            ("triggers", "triggers"),
            ("timers", "timers"),
        )
    )
    registration_assertions += (
        "\nassert(table_count(mip_handlers) == "
        f"{scenario.expected_registrations['mip']}, "
        f"{_lua('unexpected MIP registration count')})"
    )
    return f"""local real_plugin_load = plugin.load
local real_print = print
local effects, aliases, triggers, timers, mip_handlers = {{}}, {{}}, {{}}, {{}}, {{}}
local now_ms = {scenario.clock_ms}
local store_data = {_lua(scenario.store_seed)}
local dependencies = {_lua(scenario.dependencies)}

local function capture(kind, ...)
  effects[#effects + 1] = {{ kind = kind, args = {{...}} }}
end
local function deep_equal(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k, v in pairs(a) do if not deep_equal(v, b[k]) then return false end end
  for k, v in pairs(b) do if not deep_equal(v, a[k]) then return false end end
  return true
end
local function table_count(value)
  local count = 0
  for _ in pairs(value) do count = count + 1 end
  return count
end

mud.send = function(...) capture("mud.send", ...) end
mud.connect = function() error("mud.connect forbidden in parity harness") end
send_raw = function(...) capture("send_raw", ...) end
push.send = function(...) capture("push.send", ...); return 1 end
push.notify = function(...) capture("push.notify", ...); return 1 end
push.alert = function(...) capture("push.alert", ...); return 1 end
ipc.send = function(...) capture("ipc.send", ...); return true end
ipc.broadcast = function(...) capture("ipc.broadcast", ...); return true end
websocket.send = function(...) capture("websocket.send", ...) end
websocket.broadcast = function(...) capture("websocket.broadcast", ...) end
ui.text = function(...) capture("ui.text", ...) end
ui.box = function(...) capture("ui.box", ...) end
buffer.color_print = function(...) capture("buffer.color_print", ...) end
print = function(...) capture("print", ...) end

store.load = function() capture("store.load") end
store.get = function() capture("store.get"); return store_data end
store.set = function(value) capture("store.set", value); store_data = value end
store.save = function() capture("store.save") end
store.path = function() error("real storage path forbidden") end

alias.add = function(pattern, callback)
  capture("alias.add", pattern)
  aliases[#aliases + 1] = {{ pattern = pattern, callback = callback }}
  return #aliases
end
trigger.add = function(pattern, callback)
  capture("trigger.add", pattern)
  triggers[#triggers + 1] = {{ pattern = pattern, callback = callback }}
  return #triggers
end
timer.every = function(interval, callback)
  capture("timer.every", interval)
  timers[#timers + 1] = {{ interval = interval, next_at = now_ms + interval,
    callback = callback, repeating = true }}
  return #timers
end
timer.after = function(interval, callback)
  capture("timer.after", interval)
  timers[#timers + 1] = {{ interval = interval, next_at = now_ms + interval,
    callback = callback, repeating = false }}
  return #timers
end
mip.on = function(name, callback)
  capture("mip.on", name)
  mip_handlers[name] = callback
end

plugin.get = function(name)
  capture("plugin.get", name)
  return dependencies[name]
end
plugin.load = function(name)
  capture("plugin.load", name)
  if dependencies[name] then return dependencies[name] end
  return nil, "undeclared plugin dependency"
end

lera.time = function() return now_ms / 1000 end
os.time = function() return math.floor(now_ms / 1000) end
os.execute = function() error("shell commands forbidden") end
io.popen = function() error("shell commands forbidden") end
http = setmetatable({{}}, {{ __index = function() error("undeclared external API") end }})
socket = nil

local function advance_clock(amount)
  now_ms = now_ms + amount
  for _, item in ipairs(timers) do
    while item.next_at and item.next_at <= now_ms do
      item.callback()
      if item.repeating then
        item.next_at = item.next_at + item.interval
      else
        item.next_at = nil
      end
    end
  end
end

local target, err = real_plugin_load(assert(os.getenv("PARITY_PLUGIN")))
assert(target, err)
{operations}
{effects}
{registration_assertions}
lera.quit()
"""


def run_scenario(
    lera_bin,
    plugin_root,
    scenario,
    *,
    timeout=10,
) -> RuntimeOutcome:
    executable = Path(lera_bin).resolve()
    root = Path(plugin_root).resolve()
    source = (root / scenario.plugin).resolve()
    try:
        source.relative_to(root)
    except ValueError as error:
        raise ValueError("invalid_runtime_scenario") from error
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise ValueError("missing_lera_binary")
    if not source.is_file():
        raise ValueError("missing_runtime_plugin")
    harness = render_harness(scenario)
    try:
        with tempfile.TemporaryDirectory(prefix="lera-parity-") as temporary:
            profile = Path(temporary)
            plugins = profile / "plugins"
            plugins.mkdir()
            storage = profile / ".storage"
            storage.mkdir()
            target = plugins / Path(scenario.plugin).name
            shutil.copy2(source, target)
            (profile / "profile.conf").write_text(
                "script = init.lua\n", encoding="utf-8"
            )
            (profile / "init.lua").write_text(harness, encoding="utf-8")
            environment = {
                "HOME": str(profile),
                "XDG_CONFIG_HOME": str(profile / "config"),
                "XDG_STATE_HOME": str(profile / "state"),
                "PATH": "/usr/bin:/bin",
                "LANG": "C",
                "LC_ALL": "C",
                "PARITY_PLUGIN": str(target),
            }
            result = subprocess.run(
                (str(executable), str(profile)),
                cwd=profile,
                env=environment,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=timeout,
                check=False,
            )
            return RuntimeOutcome(
                exit_code=result.returncode,
                stdout=result.stdout,
                stderr=result.stderr,
                harness=harness,
            )
    except subprocess.TimeoutExpired as error:
        raise RuntimeError("runtime_timeout") from error
