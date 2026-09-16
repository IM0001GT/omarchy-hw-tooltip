#!/usr/bin/env python3
import importlib.util
import os
import stat
import tempfile
import unittest
from importlib.machinery import SourceFileLoader

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MOD = os.path.join(ROOT, "scripts", "hw_tooltip.py")


def load_mod():
    loader = SourceFileLoader("hw_tooltip", MOD)
    spec = importlib.util.spec_from_loader(loader.name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


def write_tree(root, files):
    for rel, content in files.items():
        path = os.path.join(root, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(content)


class FdinfoLoad(unittest.TestCase):
    def setUp(self):
        self.hw = load_mod()

    def test_i915_render_ns_is_percent_of_window(self):
        before = {"1:1": {"render": 1_000_000_000}}
        after = {"1:1": {"render": 1_500_000_000}}
        dt_ns = 1_000_000_000
        self.assertEqual(self.hw.fdinfo_pct(before, after, dt_ns), 50)

    def test_xe_cycles_use_total_cycles_not_wall_clock(self):
        before = {"1:1": {"rcs@cycles": 100, "rcs@total": 1000}}
        after = {"1:1": {"rcs@cycles": 180, "rcs@total": 1100}}
        dt_ns = 2_000_000_000
        # 80 busy / 100 elapsed total cycles = 80%
        self.assertEqual(self.hw.fdinfo_pct(before, after, dt_ns), 80)

    def test_xe_prefers_rcs_over_video(self):
        before = {
            "1:1": {
                "rcs@cycles": 10,
                "rcs@total": 100,
                "vcs@cycles": 90,
                "vcs@total": 100,
            }
        }
        after = {
            "1:1": {
                "rcs@cycles": 20,
                "rcs@total": 200,
                "vcs@cycles": 190,
                "vcs@total": 200,
            }
        }
        self.assertEqual(self.hw.fdinfo_pct(before, after, 1_000_000_000), 10)

    def test_parse_i915_engine_ns(self):
        text = (
            "drm-client-id:\t4\n"
            "drm-engine-render:\t12345 ns\n"
            "drm-engine-capacity-render:\t1\n"
            "drm-engine-video:\t9 ns\n"
        )
        client, engines = self.hw.parse_fdinfo_engines(text)
        self.assertEqual(client, "4")
        self.assertEqual(engines["render"], 12345)
        self.assertEqual(engines["video"], 9)
        self.assertNotIn("capacity-render", engines)

    def test_parse_xe_cycles_and_totals(self):
        text = (
            "drm-client-id: 7\n"
            "drm-cycles-rcs: 111\n"
            "drm-total-cycles-rcs: 1000\n"
            "drm-cycles-ccs: 5\n"
            "drm-total-cycles-ccs: 1000\n"
        )
        client, engines = self.hw.parse_fdinfo_engines(text)
        self.assertEqual(client, "7")
        self.assertEqual(engines["rcs@cycles"], 111)
        self.assertEqual(engines["rcs@total"], 1000)
        self.assertEqual(engines["ccs@cycles"], 5)

    def test_idle_clients_report_zero_not_missing(self):
        before = {"1:1": {"render": 50}}
        after = {"1:1": {"render": 50}}
        self.assertEqual(self.hw.fdinfo_pct(before, after, 1_000_000_000), 0)

    def test_empty_after_is_none(self):
        self.assertIsNone(self.hw.fdinfo_pct({}, {}, 1_000_000_000))


class IdleResidency(unittest.TestCase):
    def setUp(self):
        self.hw = load_mod()
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def test_xe_gtidle_keeps_render_gt_skips_media(self):
        write_tree(self.root, {
            "class/drm/card0/device/tile0/gt0/gtidle/name": "gt0-rc\n",
            "class/drm/card0/device/tile0/gt0/gtidle/idle_residency_ms": "1200\n",
            "class/drm/card0/device/tile0/gt1/gtidle/name": "gt1-mc\n",
            "class/drm/card0/device/tile0/gt1/gtidle/idle_residency_ms": "9999\n",
            "class/drm/card1/device/tile1/gt0/gtidle/name": "gt0-rc\n",
            "class/drm/card1/device/tile1/gt0/gtidle/idle_residency_ms": "40\n",
        })
        vals = self.hw.collect_idle_residency(self.root)
        self.assertEqual(len(vals), 2)
        self.assertIn(1200, vals.values())
        self.assertIn(40, vals.values())
        self.assertNotIn(9999, vals.values())

    def test_i915_rc6_still_collected(self):
        write_tree(self.root, {
            "class/drm/card0/gt/gt0/rc6_enable": "1\n",
            "class/drm/card0/gt/gt0/rc6_residency_ms": "333\n",
        })
        vals = self.hw.collect_idle_residency(self.root)
        self.assertEqual(list(vals.values()), [333])


class HeadlineTemps(unittest.TestCase):
    def setUp(self):
        self.hw = load_mod()
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def test_cpu_prefers_package_over_cores(self):
        write_tree(self.root, {
            "class/hwmon/hwmon5/name": "coretemp\n",
            "class/hwmon/hwmon5/temp1_label": "Package id 0\n",
            "class/hwmon/hwmon5/temp1_input": "60000\n",
            "class/hwmon/hwmon5/temp2_label": "Core 0\n",
            "class/hwmon/hwmon5/temp2_input": "99000\n",
        })
        self.assertEqual(self.hw.cpu_temp_c(self.root), 60)

    def test_cpu_k10temp_uses_tctl(self):
        write_tree(self.root, {
            "class/hwmon/hwmon0/name": "k10temp\n",
            "class/hwmon/hwmon0/temp1_label": "Tctl\n",
            "class/hwmon/hwmon0/temp1_input": "47250\n",
            "class/hwmon/hwmon0/temp2_label": "Tccd1\n",
            "class/hwmon/hwmon0/temp2_input": "90000\n",
        })
        self.assertEqual(self.hw.cpu_temp_c(self.root), 47)

    def test_gpu_amd_prefers_junction_over_edge_and_mem(self):
        write_tree(self.root, {
            "class/hwmon/hwmon3/name": "amdgpu\n",
            "class/hwmon/hwmon3/temp1_label": "edge\n",
            "class/hwmon/hwmon3/temp1_input": "40000\n",
            "class/hwmon/hwmon3/temp2_label": "junction\n",
            "class/hwmon/hwmon3/temp2_input": "62000\n",
            "class/hwmon/hwmon3/temp3_label": "mem\n",
            "class/hwmon/hwmon3/temp3_input": "88000\n",
        })
        self.assertEqual(self.hw.gpu_temp_c(self.root), 62)

    def test_gpu_intel_hwmon_over_acpi_zone(self):
        write_tree(self.root, {
            "class/hwmon/hwmon7/name": "i915\n",
            "class/hwmon/hwmon7/temp1_input": "51000\n",
            "class/thermal/thermal_zone6/type": "B0D4\n",
            "class/thermal/thermal_zone6/temp": "77000\n",
            "bus/pci/devices/0000:00:02.0/vendor": "0x8086\n",
            "bus/pci/devices/0000:00:02.0/class": "0x030000\n",
        })
        self.assertEqual(self.hw.gpu_temp_c(self.root), 51)

    def test_gpu_intel_falls_back_to_b0d4(self):
        write_tree(self.root, {
            "class/thermal/thermal_zone6/type": "B0D4\n",
            "class/thermal/thermal_zone6/temp": "56000\n",
            "bus/pci/devices/0000:00:02.0/vendor": "0x8086\n",
            "bus/pci/devices/0000:00:02.0/class": "0x030000\n",
        })
        self.assertEqual(self.hw.gpu_temp_c(self.root), 56)

    def test_gpu_nvidia_query_beats_hwmon(self):
        write_tree(self.root, {
            "class/hwmon/hwmon1/name": "nvidia\n",
            "class/hwmon/hwmon1/temp1_input": "30000\n",
        })
        self.assertEqual(self.hw.gpu_temp_c(self.root, nvidia_c=71), 71)

    def test_ram_uses_sodimm_not_ambient_or_wifi(self):
        write_tree(self.root, {
            "class/hwmon/hwmon4/name": "dell_ddv\n",
            "class/hwmon/hwmon4/temp1_label": "CPU\n",
            "class/hwmon/hwmon4/temp1_input": "57000\n",
            "class/hwmon/hwmon4/temp2_label": "SODIMM\n",
            "class/hwmon/hwmon4/temp2_input": "45000\n",
            "class/hwmon/hwmon4/temp3_label": "Ambient\n",
            "class/hwmon/hwmon4/temp3_input": "35000\n",
            "class/hwmon/hwmon6/name": "iwlwifi_1\n",
            "class/hwmon/hwmon6/temp1_input": "41000\n",
        })
        self.assertEqual(self.hw.ram_temp_c(self.root), 45)

    def test_nvme_composite_not_extra_sensors(self):
        write_tree(self.root, {
            "class/nvme/nvme0/hwmon2/name": "nvme\n",
            "class/nvme/nvme0/hwmon2/temp1_label": "Composite\n",
            "class/nvme/nvme0/hwmon2/temp1_input": "38850\n",
            "class/nvme/nvme0/hwmon2/temp2_label": "Sensor 1\n",
            "class/nvme/nvme0/hwmon2/temp2_input": "71000\n",
        })
        os.makedirs(os.path.join(self.root, "class/block/nvme0n1"), exist_ok=True)
        os.symlink(
            os.path.join(self.root, "class/nvme/nvme0"),
            os.path.join(self.root, "class/block/nvme0n1/device"),
        )
        self.assertEqual(self.hw.disk_temp_c("/dev/nvme0n1p2", self.root), 39)

    def test_wifi_and_battery_are_not_cpu_or_gpu(self):
        write_tree(self.root, {
            "class/hwmon/hwmon1/name": "BAT0\n",
            "class/hwmon/hwmon1/temp1_label": "temp\n",
            "class/hwmon/hwmon1/temp1_input": "25100\n",
            "class/hwmon/hwmon6/name": "iwlwifi_1\n",
            "class/hwmon/hwmon6/temp1_input": "41000\n",
        })
        self.assertIsNone(self.hw.cpu_temp_c(self.root))
        self.assertIsNone(self.hw.gpu_temp_c(self.root))
        self.assertIsNone(self.hw.ram_temp_c(self.root))


class MultipleGpus(unittest.TestCase):
    def setUp(self):
        self.hw = load_mod()
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def test_lists_vga_and_3d_skips_network(self):
        write_tree(self.root, {
            "bus/pci/devices/0000:00:02.0/class": "0x030000\n",
            "bus/pci/devices/0000:00:02.0/vendor": "0x8086\n",
            "bus/pci/devices/0000:00:02.0/device": "0x8a56\n",
            "bus/pci/devices/0000:00:02.0/boot_vga": "1\n",
            "bus/pci/devices/0000:01:00.0/class": "0x030200\n",
            "bus/pci/devices/0000:01:00.0/vendor": "0x10de\n",
            "bus/pci/devices/0000:01:00.0/device": "0x2757\n",
            "bus/pci/devices/0000:00:1f.6/class": "0x020000\n",
            "bus/pci/devices/0000:00:1f.6/vendor": "0x8086\n",
        })
        gpus = self.hw.list_pci_gpus(self.root)
        self.assertEqual([g["pci"] for g in gpus], ["0000:00:02.0", "0000:01:00.0"])
        self.assertTrue(gpus[0]["boot_vga"])
        self.assertEqual(gpus[0]["vendor"], "0x8086")
        self.assertEqual(gpus[1]["vendor"], "0x10de")

    def test_boot_vga_is_listed_first(self):
        write_tree(self.root, {
            "bus/pci/devices/0000:01:00.0/class": "0x030000\n",
            "bus/pci/devices/0000:01:00.0/vendor": "0x1002\n",
            "bus/pci/devices/0000:01:00.0/device": "0x73df\n",
            "bus/pci/devices/0000:00:02.0/class": "0x030000\n",
            "bus/pci/devices/0000:00:02.0/vendor": "0x8086\n",
            "bus/pci/devices/0000:00:02.0/device": "0x8a56\n",
            "bus/pci/devices/0000:00:02.0/boot_vga": "1\n",
        })
        gpus = self.hw.list_pci_gpus(self.root)
        self.assertEqual(gpus[0]["pci"], "0000:00:02.0")

    def test_parse_fdinfo_pdev(self):
        text = (
            "drm-client-id:\t4\n"
            "drm-pdev:\t0000:00:02.0\n"
            "drm-engine-render:\t100 ns\n"
        )
        client, pdev, engines = self.hw.parse_fdinfo(text)
        self.assertEqual(client, "4")
        self.assertEqual(pdev, "0000:00:02.0")
        self.assertEqual(engines["render"], 100)

    def test_fdinfo_pct_is_independent_per_pdev(self):
        before = {
            "0000:00:02.0|1:1": {"render": 0},
            "0000:01:00.0|2:1": {"gfx": 0},
        }
        after = {
            "0000:00:02.0|1:1": {"render": 200_000_000},
            "0000:01:00.0|2:1": {"gfx": 800_000_000},
        }
        dt = 1_000_000_000
        igpu = {k: v for k, v in after.items() if k.startswith("0000:00:02.0|")}
        dgpu = {k: v for k, v in after.items() if k.startswith("0000:01:00.0|")}
        igpu0 = {k: v for k, v in before.items() if k.startswith("0000:00:02.0|")}
        dgpu0 = {k: v for k, v in before.items() if k.startswith("0000:01:00.0|")}
        self.assertEqual(self.hw.fdinfo_pct(igpu0, igpu, dt), 20)
        self.assertEqual(self.hw.fdinfo_pct(dgpu0, dgpu, dt), 80)

    def test_nvidia_smi_rows_keep_each_card(self):
        text = (
            "00000000:01:00.0, NVIDIA GeForce RTX 4070, 12, 45\n"
            "00000000:02:00.0, NVIDIA GeForce RTX 4090, 88, 71\n"
        )
        rows = self.hw.parse_nvidia_smi_gpus(text)
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0]["pci"], "0000:01:00.0")
        self.assertEqual(rows[0]["pct"], 12)
        self.assertEqual(rows[0]["temp"], 45)
        self.assertIn("4070", rows[0]["name"])
        self.assertEqual(rows[1]["pct"], 88)

    def test_normalize_pci_strips_extra_zeros(self):
        self.assertEqual(self.hw.normalize_pci("00000000:01:00.0"), "0000:01:00.0")
        self.assertEqual(self.hw.normalize_pci("01:00.0"), "0000:01:00.0")


class PrivateWrites(unittest.TestCase):
    def setUp(self):
        self.hw = load_mod()
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def test_write_creates_owned_regular_file(self):
        dest = os.path.join(self.root, "gpu.state")
        self.hw.write_private_file(dest, "hello\n")
        self.assertEqual(self.hw.read_private_file(dest), "hello\n")
        st = os.lstat(dest)
        self.assertTrue(stat.S_ISREG(st.st_mode))
        self.assertEqual(st.st_mode & 0o777, 0o600)
        self.assertFalse(os.path.exists(dest + ".tmp"))

    def test_write_does_not_follow_dest_symlink(self):
        target = os.path.join(self.root, "secret")
        with open(target, "w", encoding="utf-8") as fh:
            fh.write("keep\n")
        dest = os.path.join(self.root, "gpu.state")
        os.symlink(target, dest)
        self.hw.write_private_file(dest, "safe\n")
        self.assertEqual(self.hw.read_private_file(dest), "safe\n")
        self.assertFalse(os.path.islink(dest))
        with open(target, encoding="utf-8") as fh:
            self.assertEqual(fh.read(), "keep\n")

    def test_read_does_not_follow_symlink(self):
        target = os.path.join(self.root, "secret")
        with open(target, "w", encoding="utf-8") as fh:
            fh.write("keep\n")
        dest = os.path.join(self.root, "gpu.state")
        os.symlink(target, dest)
        self.assertIsNone(self.hw.read_private_file(dest))


if __name__ == "__main__":
    unittest.main()
