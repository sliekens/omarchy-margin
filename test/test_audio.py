#!/usr/bin/env python3
"""Source-selection regression tests for bin/margin-audio."""

import importlib.machinery
import importlib.util
import io
import os
import subprocess
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
AUDIO = os.path.abspath(os.path.join(HERE, os.pardir, "bin", "margin-audio"))


def load_module():
    loader = importlib.machinery.SourceFileLoader("margin_audio", AUDIO)
    spec = importlib.util.spec_from_loader("margin_audio", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


class CaptureTests(unittest.TestCase):
    def setUp(self):
        self.audio = load_module()

    def test_captures_only_the_default_output_monitor(self):
        child = mock.Mock()
        child.poll.return_value = 0
        with mock.patch.object(self.audio.shutil, "which",
                               return_value="/usr/bin/parec"), \
                mock.patch.object(self.audio.subprocess, "Popen",
                                  return_value=child) as popen:
            self.assertIs(self.audio.open_capture(), child)

        self.assertEqual(popen.call_args.args[0], [
            "/usr/bin/parec", "--record", "--device=@DEFAULT_MONITOR@",
            "--format=s16le", "--rate=22050", "--channels=1",
            "--latency-msec=20", "--raw",
        ])
        self.assertEqual(popen.call_args.kwargs, {
            "stdout": subprocess.PIPE,
            "stderr": subprocess.DEVNULL,
        })

    def test_stops_when_parec_is_unavailable(self):
        with mock.patch.object(self.audio.shutil, "which", return_value=None), \
                mock.patch.object(self.audio.subprocess, "Popen") as popen, \
                mock.patch.object(self.audio.sys, "stderr", new=io.StringIO()):
            with self.assertRaisesRegex(SystemExit, "1"):
                self.audio.open_capture()
            popen.assert_not_called()


if __name__ == "__main__":
    unittest.main()
