"""Exercise real sysfs traversal against isolated topology fixtures."""
import ctypes
import pathlib
import subprocess
import sys
import tempfile
import unittest

SOURCE = pathlib.Path(sys.argv.pop(1)).resolve()
BUILD = tempfile.TemporaryDirectory(prefix="xy-system-disk-tests-")
LIB = pathlib.Path(BUILD.name) / "disk.so"
subprocess.run([
    "cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-shared", "-fPIC",
    str(SOURCE / "system_disk.c"), str(SOURCE / "system_disk_linux.c"),
    "-o", str(LIB),
], check=True)


class Disk(ctypes.Structure):
    _fields_ = [("serial", ctypes.c_char * 256), ("device", ctypes.c_char * 128)]


NATIVE = ctypes.CDLL(str(LIB))
NATIVE.xy_linux_disk_from_sysfs.argtypes = [
    ctypes.c_char_p, ctypes.c_uint, ctypes.c_uint, ctypes.POINTER(Disk), ctypes.c_char_p,
]
NATIVE.xy_linux_disk_from_sysfs.restype = ctypes.c_bool


class SystemDisk(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="xy-sysfs-")
        self.addCleanup(self.tmp.cleanup)
        self.root = pathlib.Path(self.tmp.name)
        (self.root / "dev/block").mkdir(parents=True)

    def disk(self, name, serial="SYSTEM_123.45", nvme=False):
        d = self.root / "devices/block" / name
        (d / "slaves").mkdir(parents=True)
        (d / "device").mkdir()
        if serial is not None:
            (d / ("serial" if nvme else "device/serial")).write_bytes(serial.encode() + b"\n")
        return d

    def partition(self, disk, name):
        p = disk / name
        p.mkdir()
        (p / "partition").write_text("2\n")
        return p

    def root_device(self, target):
        (self.root / "dev/block/8:2").symlink_to(target)

    def collect(self, expected=None, error=None):
        disk, stage = Disk(), ctypes.create_string_buffer(128)
        ok = NATIVE.xy_linux_disk_from_sysfs(str(self.root).encode(), 8, 2, ctypes.byref(disk), stage)
        if expected is not None:
            self.assertTrue(ok, stage.value.decode())
            self.assertEqual(disk.serial.decode(), expected)
        else:
            self.assertFalse(ok)
            self.assertIn(error, stage.value.decode())
        return disk

    def test_root_partition_ignores_earlier_data_and_usb_disks(self):
        self.disk("sda", "DATA_DISK")
        self.disk("usb0", "USB_DISK")
        self.root_device(self.partition(self.disk("sdb"), "sdb2"))
        self.assertEqual(self.collect("SYSTEM_123.45").device.decode(), "/dev/sdb")

    def test_disk_number_changes_do_not_change_identity(self):
        system = self.disk("nvme5n1", "NVME_OS_123", nvme=True)
        self.root_device(self.partition(system, "nvme5n1p2"))
        self.collect("NVME_OS_123")
        moved = system.with_name("nvme9n1")
        system.rename(moved)
        link = self.root / "dev/block/8:2"
        link.unlink()
        link.symlink_to(moved / "nvme5n1p2")
        self.collect("NVME_OS_123")

    def test_lvm_and_encryption_follow_slaves(self):
        osdisk = self.disk("sdc")
        partition = self.partition(osdisk, "sdc3")
        crypt, lvm = self.disk("dm-crypt", None), self.disk("dm-lvm", None)
        (crypt / "slaves/sdc3").symlink_to(partition)
        (lvm / "slaves/crypt").symlink_to(crypt)
        self.root_device(lvm)
        self.collect("SYSTEM_123.45")

    def test_same_disk_multiple_extents_are_deduplicated(self):
        osdisk, lvm = self.disk("sdc"), self.disk("dm-0", None)
        for name in ["sdc2", "sdc3"]:
            (lvm / "slaves" / name).symlink_to(self.partition(osdisk, name))
        self.root_device(lvm)
        self.collect("SYSTEM_123.45")

    def test_multi_disk_root_is_rejected(self):
        raid = self.disk("md0", None)
        for name in ["sda", "sdb"]:
            (raid / "slaves" / name).symlink_to(self.disk(name, name + "_SERIAL"))
        self.root_device(raid)
        self.collect(error="multiple-system-disks")

    def test_no_serial_never_chooses_data_disk(self):
        self.disk("sda", "VALID_DATA_DISK")
        self.root_device(self.disk("sdb", None))
        self.collect(error="serial-unavailable")

    def test_invalid_serials_and_field_injection_are_rejected(self):
        osdisk = self.disk("sdb")
        self.root_device(osdisk)
        for value in ["", "000000", "FFFFFFFF", "unknown", "none", "disk\nIV_USER=attacker", "disk\x00tail", "x" * 300]:
            with self.subTest(value=value[:30]):
                (osdisk / "device/serial").write_bytes(value.encode() + b"\n")
                self.collect(error="serial-invalid")
        (osdisk / "device/serial").write_text("  SYSTEM_123.45  \n")
        self.collect("SYSTEM_123.45")

    def test_invalid_first_serial_is_not_replaced_by_another_id(self):
        osdisk = self.disk("sdb", "unknown")
        (osdisk / "serial").write_text("OTHER_ID_123\n")
        self.root_device(osdisk)
        self.collect(error="serial-invalid")

    def test_cycles_are_rejected(self):
        dm = self.disk("dm-0", None)
        (dm / "slaves/self").symlink_to(dm)
        self.root_device(dm)
        self.collect(error="storage-cycle")

    def test_missing_device_fails(self):
        self.collect(error="resolve-device")


unittest.main()
