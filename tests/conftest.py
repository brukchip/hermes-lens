"""Load the plugin directory as the package `hermes_lens`, the way Hermes imports it."""
import importlib.util
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def _load_package():
    if "hermes_lens" in sys.modules:
        return sys.modules["hermes_lens"]
    spec = importlib.util.spec_from_file_location(
        "hermes_lens", ROOT / "__init__.py", submodule_search_locations=[str(ROOT)])
    module = importlib.util.module_from_spec(spec)
    sys.modules["hermes_lens"] = module
    try:
        spec.loader.exec_module(module)
    except ImportError:
        # Outside Hermes the adapter's gateway imports are missing; grant/voice still load.
        pass
    return module


_load_package()
