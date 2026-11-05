import importlib.machinery
import importlib.util
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
loader = importlib.machinery.SourceFileLoader("obsbot_xu", str(ROOT / "obsbot-xu"))
spec = importlib.util.spec_from_loader("obsbot_xu", loader)
obsbot_xu = importlib.util.module_from_spec(spec)
loader.exec_module(obsbot_xu)


def make_node(sysfs, name, index, vendor, product):
    """Mirror /sys/class/video4linux/<name> as seen on 22/10 for this laptop."""
    usb_device = sysfs / "devices" / f"usb-{vendor}-{product}"
    interface = usb_device / "1-1:1.0"
    interface.mkdir(parents=True, exist_ok=True)
    (usb_device / "idVendor").write_text(vendor + "\n")
    (usb_device / "idProduct").write_text(product + "\n")
    node = sysfs / "class" / "video4linux" / name
    node.mkdir(parents=True)
    (node / "index").write_text(f"{index}\n")
    (node / "device").symlink_to(interface)


class FindDeviceTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.sysfs = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_picks_obsbot_capture_node_over_metadata_and_other_cameras(self):
        make_node(self.sysfs, "video0", 0, "3277", "0036")
        make_node(self.sysfs, "video1", 1, "3277", "0036")
        make_node(self.sysfs, "video2", 0, "3564", "fefe")
        make_node(self.sysfs, "video3", 1, "3564", "fefe")

        self.assertEqual(obsbot_xu.find_device(self.sysfs), "/dev/video2")

    def test_reports_none_when_camera_is_unplugged(self):
        make_node(self.sysfs, "video0", 0, "3277", "0036")

        self.assertIsNone(obsbot_xu.find_device(self.sysfs))


class RunTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.sysfs = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def assertFailsWith(self, code, argv):
        with self.assertRaises(obsbot_xu.TransportError) as caught:
            obsbot_xu.run(argv, sysfs=self.sysfs)
        self.assertEqual(caught.exception.code, code)

    def test_get_without_camera_reports_missing(self):
        self.assertFailsWith("missing", ["get"])

    def test_set_rejects_packets_that_are_not_60_bytes_before_touching_device(self):
        make_node(self.sysfs, "video2", 0, "3564", "fefe")

        self.assertFailsWith("invalid-packet", ["set", "0401"])
        self.assertFailsWith("invalid-packet", ["set", "zz" * 60])

    def test_unknown_command_is_a_usage_error(self):
        self.assertFailsWith("usage", ["reboot"])
        self.assertFailsWith("usage", ["set"])


if __name__ == "__main__":
    unittest.main()
