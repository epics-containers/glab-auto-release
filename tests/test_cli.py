import subprocess
import sys

from glab_auto_release import __version__


def test_cli_version():
    cmd = [sys.executable, "-m", "glab_auto_release", "--version"]
    assert subprocess.check_output(cmd).decode().strip() == __version__
