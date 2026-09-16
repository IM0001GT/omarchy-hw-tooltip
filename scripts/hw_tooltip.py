#!/usr/bin/env python3
"""GPU load (i915 + xe) and one headline temperature per device."""

import glob
import os
import re
import stat
import subprocess
import sys
import time

PREFERRED_ENGINES = {"render", "gfx", "compute", "rcs", "ccs"}

CPU_HWMON = {"k10temp", "zenpower", "coretemp", "cpu_thermal", "cpuinfo"}
GPU_HWMON = {"amdgpu", "i915", "xe", "nvidia", "nouveau"}
RAM_HWMON = {"spd5118", "jc42", "ee1004"}
SKIP_HWMON = {"bat0", "ac", "iwlwifi", "ucsi_source"}


def _nofollow_flag():
    return getattr(os, "O_NOFOLLOW", 0)


def _dir_flags():
    return os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | _nofollow_flag()


def _is_owned_real_dir(path):
    try:
        st = os.lstat(path)
    except OSError:
        return False
    return stat.S_ISDIR(st.st_mode) and not os.path.islink(path) and st.st_uid == os.getuid()


def _trusted_root_for(path):
    path = os.path.abspath(path)
    home = os.path.abspath(os.path.expanduser("~"))
    try:
        if os.path.commonpath([path, home]) == home and _is_owned_real_dir(home):
            return home
    except ValueError:
        pass
    cur, found = path, None
    while True:
        if _is_owned_real_dir(cur):
            found = cur
        parent = os.path.dirname(cur)
        if parent == cur:
            break
        cur = parent
    if not found:
        raise OSError("no owned ancestor for %s" % path)
    return found


def open_owned_dirfd(path):
    path = os.path.abspath(path)
    root = _trusted_root_for(path)
    rel = os.path.relpath(path, root)
    fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        st = os.fstat(fd)
        if st.st_uid != os.getuid() or not stat.S_ISDIR(st.st_mode):
            raise OSError("untrusted root directory")
        if rel == ".":
            os.fchmod(fd, 0o700)
            out, fd = fd, None
            return out
        for part in rel.split(os.sep):
            if part in ("", ".", ".."):
                raise OSError("invalid path component")
            try:
                nxt = os.open(part, _dir_flags(), dir_fd=fd)
            except FileNotFoundError:
                try:
                    os.mkdir(part, 0o700, dir_fd=fd)
                except FileExistsError:
                    pass
                nxt = os.open(part, _dir_flags(), dir_fd=fd)
            os.close(fd)
            fd = nxt
            st = os.fstat(fd)
            if st.st_uid != os.getuid() or not stat.S_ISDIR(st.st_mode):
                raise OSError("untrusted ancestor %s" % part)
            os.fchmod(fd, 0o700)
        out, fd = fd, None
        return out
    finally:
        if fd is not None:
            os.close(fd)


def write_private_file(path, data, mode=0o600):
    if not isinstance(data, (bytes, bytearray)):
        data = str(data).encode("utf-8")
    path = os.path.abspath(path)
    directory = os.path.dirname(path)
    name = os.path.basename(path)
    if not name or name in (".", "..") or os.sep in name:
        raise OSError("invalid destination")
    dir_fd = open_owned_dirfd(directory)
    tmp_name = None
    fd = None
    try:
        flags = os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | _nofollow_flag()
        for _ in range(32):
            candidate = ".hw-tooltip-%s" % os.urandom(8).hex()
            try:
                fd = os.open(candidate, flags, 0o600, dir_fd=dir_fd)
                tmp_name = candidate
                break
            except FileExistsError:
                continue
        if fd is None:
            raise OSError("could not create exclusive staging file")
        st = os.fstat(fd)
        if st.st_uid != os.getuid() or not stat.S_ISREG(st.st_mode):
            raise OSError("staging file untrusted")
        os.fchmod(fd, mode)
        view = memoryview(data)
        while view:
            written = os.write(fd, view)
            if written <= 0:
                raise OSError("short write")
            view = view[written:]
        os.fsync(fd)
        os.close(fd)
        fd = None
        os.replace(tmp_name, name, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
        tmp_name = None
    finally:
        if fd is not None:
            os.close(fd)
        if tmp_name:
            try:
                os.unlink(tmp_name, dir_fd=dir_fd)
            except OSError:
                pass
        os.close(dir_fd)
    return True


def read_private_file(path):
    path = os.path.abspath(path)
    directory = os.path.dirname(path)
    name = os.path.basename(path)
    if not name or name in (".", "..") or os.sep in name:
        return None
    try:
        dir_fd = open_owned_dirfd(directory)
    except OSError:
        return None
    fd = None
    try:
        fd = os.open(name, os.O_RDONLY | os.O_CLOEXEC | _nofollow_flag(), dir_fd=dir_fd)
        st = os.fstat(fd)
        if st.st_uid != os.getuid() or not stat.S_ISREG(st.st_mode):
            return None
        chunks = []
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            chunks.append(chunk)
        return b"".join(chunks).decode("utf-8", errors="replace")
    except OSError:
        return None
    finally:
        if fd is not None:
            os.close(fd)
        os.close(dir_fd)


def runtime_file(name):
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    if runtime:
        return os.path.join(runtime, "hw-tooltip-" + name)
    cache = os.path.join(os.path.expanduser("~"), ".cache", "hw-tooltip")
    open_owned_dirfd(cache)
    return os.path.join(cache, name)


def read(path):
    try:
        with open(path, encoding="utf-8", errors="ignore") as fh:
            return fh.read().strip()
    except OSError:
        return ""


def milli_c(raw):
    text = (raw or "").strip()
    sign = ""
    if text.startswith("-"):
        sign, text = "-", text[1:]
    if not text.isdigit():
        return None
    val = int(sign + text)
    if val <= -273000 or val > 200000:
        return None
    return int(round(val / 1000.0))


def normalize_pci(addr):
    addr = (addr or "").strip().lower()
    if addr.startswith("00000000:"):
        addr = "0000:" + addr[9:]
    if re.match(r"^[0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f]$", addr):
        addr = "0000:" + addr
    return addr


def parse_fdinfo(text):
    client = None
    pdev = None
    engines = {}
    for line in text.splitlines():
        label, _, value = line.partition(":")
        label = label.strip()
        if label == "drm-client-id":
            client = value.strip()
            continue
        if label == "drm-pdev":
            pdev = normalize_pci(value)
            continue
        if label.startswith("drm-engine-") and not label.startswith("drm-engine-capacity-"):
            name = label[len("drm-engine-"):]
        elif label.startswith("drm-total-cycles-"):
            name = label[len("drm-total-cycles-"):] + "@total"
        elif label.startswith("drm-cycles-"):
            name = label[len("drm-cycles-"):] + "@cycles"
        else:
            continue
        digits = "".join(c for c in value if c.isdigit())
        if not digits:
            continue
        ns = int(digits)
        if ns > engines.get(name, 0):
            engines[name] = ns
    return client, pdev, engines


def parse_fdinfo_engines(text):
    client, _pdev, engines = parse_fdinfo(text)
    return client, engines


def fdinfo_pct(before, after, dt_ns):
    if dt_ns <= 0 or not after:
        return None
    totals, cycles, spans = {}, {}, {}
    for key, engines in after.items():
        prev = before.get(key, {})
        for name, ns in engines.items():
            delta = ns - prev.get(name, ns)
            if name.endswith("@total"):
                base = name[:-len("@total")]
                spans[base] = max(spans.get(base, 0), delta)
            elif name.endswith("@cycles"):
                base = name[:-len("@cycles")]
                if delta > 0:
                    cycles[base] = cycles.get(base, 0) + delta
            elif delta > 0:
                totals[name] = totals.get(name, 0) + delta
    for name, busy in cycles.items():
        span = spans.get(name, 0)
        if span > 0:
            totals[name] = totals.get(name, 0) + busy * dt_ns / span
    if not any(engines for engines in after.values()):
        return None
    if not totals:
        return 0
    preferred = [totals[n] for n in totals if n in PREFERRED_ENGINES]
    chosen = max(preferred) if preferred else max(totals.values())
    return max(0, min(100, round(chosen * 100 / dt_ns)))


def collect_idle_residency(sysfs_root="/sys"):
    vals = {}
    drm = os.path.join(sysfs_root, "class", "drm")
    for path in glob.glob(os.path.join(drm, "card*", "gt", "gt*", "rc6_residency_ms")):
        enable = path.replace("rc6_residency_ms", "rc6_enable")
        try:
            if os.path.exists(enable) and int(read(enable) or "1") == 0:
                continue
            vals[path] = int(read(path))
        except (OSError, ValueError):
            continue
    for path in glob.glob(os.path.join(drm, "card*", "device", "tile*", "gt*", "gtidle", "idle_residency_ms")):
        try:
            name = read(os.path.join(os.path.dirname(path), "name"))
            if not name.endswith("-rc"):
                continue
            vals[path] = int(read(path))
        except (OSError, ValueError):
            continue
    return vals


def rc6_pct(before, after, dt_ms):
    if dt_ms <= 0 or not after:
        return None
    best = None
    for path, end in after.items():
        start = before.get(path)
        if start is None:
            continue
        idle = (end - start) * 100 / dt_ms
        busy = max(0, min(100, round(100 - idle)))
        best = busy if best is None else max(best, busy)
    return best


def state_path():
    try:
        return runtime_file("gpu.state")
    except OSError:
        return None


def snap_fdinfo():
    clients = {}
    try:
        pids = os.listdir("/proc")
    except OSError:
        return clients
    for pid in pids:
        if not pid.isdigit():
            continue
        fd_dir = "/proc/%s/fd" % pid
        info_dir = "/proc/%s/fdinfo" % pid
        try:
            fds = os.listdir(fd_dir)
        except OSError:
            continue
        for fd in fds:
            try:
                tgt = os.readlink(os.path.join(fd_dir, fd))
            except OSError:
                continue
            if "/dri/" not in tgt and not tgt.startswith("/dev/dri"):
                continue
            try:
                with open(os.path.join(info_dir, fd), "r", errors="ignore") as fh:
                    text = fh.read()
            except OSError:
                continue
            if "drm-engine-" not in text and "drm-cycles-" not in text:
                continue
            client, pdev, engines = parse_fdinfo(text)
            if not engines:
                continue
            key = "%s|%s:%s" % (pdev or "-", pid, client or fd)
            slot = clients.setdefault(key, {})
            for name, ns in engines.items():
                if ns > slot.get(name, 0):
                    slot[name] = ns
    return clients


def load_state(path):
    if not path:
        return None
    text = read_private_file(path)
    if not text:
        return None
    lines = text.splitlines()
    if len(lines) < 2:
        return None
    try:
        t_ns = int(lines[0])
        rc6 = {}
        clients = {}
        for line in lines[1:]:
            parts = line.split()
            if len(parts) == 2:
                rc6[parts[0]] = int(parts[1])
            elif len(parts) == 3:
                clients.setdefault(parts[0], {})[parts[1]] = int(parts[2])
            else:
                return None
    except ValueError:
        return None
    return t_ns, clients, rc6


def save_state(path, t_ns, clients, rc6):
    if not path:
        return
    lines = ["%d" % t_ns]
    for p, val in rc6.items():
        lines.append("%s %d" % (p, val))
    for key, engines in clients.items():
        for name, ns in engines.items():
            lines.append("%s %s %d" % (key, name, ns))
    try:
        write_private_file(path, "\n".join(lines) + "\n")
    except OSError:
        pass


def _pdev_of(key):
    return key.split("|", 1)[0]


def clients_for_pdev(clients, pdev):
    prefix = pdev + "|"
    return {k: v for k, v in clients.items() if k.startswith(prefix)}


def sample_gpu_snapshots(sysfs_root="/sys"):
    path = state_path()
    now_ns = time.monotonic_ns()
    fd1, rc1 = snap_fdinfo(), collect_idle_residency(sysfs_root)
    prev = load_state(path)
    save_state(path, now_ns, fd1, rc1)
    fd0, rc0, dt_ns = {}, {}, 0
    if prev is not None:
        t0, fd0, rc0 = prev
        dt_ns = now_ns - t0
        if not (400_000_000 <= dt_ns <= 10_000_000_000):
            fd0, rc0, dt_ns = {}, {}, 0
    if not fd0 and not rc0:
        time.sleep(0.2)
        t1 = time.monotonic_ns()
        fd2, rc2 = snap_fdinfo(), collect_idle_residency(sysfs_root)
        save_state(path, t1, fd2, rc2)
        fd0, rc0, fd1, rc1, dt_ns = fd1, rc1, fd2, rc2, t1 - now_ns
    return fd0, rc0, fd1, rc1, dt_ns


def drm_pcts_from_snapshots(fd0, fd1, rc0, rc1, dt_ns):
    pcts = {}
    pdevs = set()
    for key in list(fd0) + list(fd1):
        pdev = _pdev_of(key)
        if pdev and pdev != "-":
            pdevs.add(pdev)
    for pdev in pdevs:
        pct = fdinfo_pct(clients_for_pdev(fd0, pdev), clients_for_pdev(fd1, pdev), dt_ns)
        if pct is not None:
            pcts[pdev] = pct
    if not pcts:
        pct = fdinfo_pct(fd0, fd1, dt_ns)
        if pct is None:
            pct = rc6_pct(rc0, rc1, dt_ns / 1e6)
        if pct is not None:
            pcts["*"] = pct
    return pcts


def sample_gpu_pct(sysfs_root="/sys"):
    fd0, rc0, fd1, rc1, dt_ns = sample_gpu_snapshots(sysfs_root)
    pcts = drm_pcts_from_snapshots(fd0, fd1, rc0, rc1, dt_ns)
    if not pcts:
        return None
    return max(pcts.values())


def hwmon_dirs(sysfs_root="/sys"):
    return sorted(glob.glob(os.path.join(sysfs_root, "class", "hwmon", "hwmon*")))


def skip_hwmon_name(name):
    low = (name or "").lower()
    return any(low == skip or low.startswith(skip) for skip in SKIP_HWMON)


def hwmon_temps(hw):
    found = []
    labels = sorted(glob.glob(os.path.join(hw, "temp*_label")))
    for label_path in labels:
        label = read(label_path).lower()
        c = milli_c(read(label_path.replace("_label", "_input")))
        if c is not None:
            found.append((label, c))
    if not found:
        c = milli_c(read(os.path.join(hw, "temp1_input")))
        if c is not None:
            found.append(("", c))
    return found


def pick_label(found, wanted):
    for want in wanted:
        for label, c in found:
            if want in label:
                return c
    return None


def cpu_temp_c(sysfs_root="/sys"):
    for hw in hwmon_dirs(sysfs_root):
        name = read(os.path.join(hw, "name")).lower()
        if name not in CPU_HWMON:
            continue
        found = hwmon_temps(hw)
        if name in ("k10temp", "zenpower"):
            c = pick_label(found, ("tctl", "tdie"))
        elif name == "coretemp":
            c = pick_label(found, ("package",))
        else:
            c = None
        if c is None and found:
            c = found[0][1]
        if c is not None:
            return c
    for zone in glob.glob(os.path.join(sysfs_root, "class", "thermal", "thermal_zone*")):
        ztype = read(os.path.join(zone, "type")).lower()
        if ztype in ("x86_pkg_temp", "cpu-thermal"):
            c = milli_c(read(os.path.join(zone, "temp")))
            if c is not None:
                return c
    return None


def nvidia_smi_temp():
    if not os.path.exists("/proc/driver/nvidia/version"):
        return None
    try:
        out = subprocess.run(
            ["nvidia-smi", "--query-gpu=temperature.gpu", "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=2,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    line = (out.stdout or "").strip().splitlines()
    if out.returncode == 0 and line:
        digits = "".join(c for c in line[0] if c.isdigit())
        if digits:
            return int(digits)
    return None


def intel_display(sysfs_root="/sys"):
    return any(g["vendor"] == "0x8086" for g in list_pci_gpus(sysfs_root))


def list_pci_gpus(sysfs_root="/sys"):
    found = []
    pci_root = os.path.join(sysfs_root, "bus", "pci", "devices")
    try:
        ents = os.scandir(pci_root)
    except OSError:
        return found
    with ents:
        for ent in ents:
            cls = read(os.path.join(ent.path, "class")).lower()
            if not cls.startswith("0x03"):
                continue
            vendor = read(os.path.join(ent.path, "vendor")).lower()
            device = read(os.path.join(ent.path, "device")).lower()
            found.append({
                "pci": normalize_pci(ent.name),
                "vendor": vendor,
                "device": device,
                "boot_vga": read(os.path.join(ent.path, "boot_vga")) == "1",
                "path": ent.path,
            })
    found.sort(key=lambda g: (0 if g["boot_vga"] else 1, g["pci"]))
    return found


def clean_gpu_name(raw):
    name = " ".join((raw or "").split())
    name = re.sub(r"\s*\([^)]*rev[^)]*\)", "", name, flags=re.I)
    name = re.sub(
        r"\s*\((Ice Lake|Comet Lake|Tiger Lake|Alder Lake|Raptor Lake|Meteor Lake|"
        r"Arrow Lake|Coffee Lake|Haswell|Skylake|Kaby Lake|Whiskey Lake|Amber Lake)[^)]*\)",
        "", name, flags=re.I,
    )
    name = re.sub(r"^Advanced Micro Devices, Inc\.?\s*", "", name, flags=re.I)
    name = re.sub(r"^(AMD/ATI|ATI)\s*", "AMD ", name, flags=re.I)
    name = re.sub(r"^Intel Corporation\s*", "Intel ", name, flags=re.I)
    name = re.sub(r"^NVIDIA Corporation\s*", "NVIDIA ", name, flags=re.I)
    name = name.replace(" Corporation", "")
    return " ".join(name.split()) or "GPU"


def parse_nvidia_smi_gpus(text):
    rows = []
    for line in (text or "").splitlines():
        parts = [p.strip() for p in line.split(",")]
        if len(parts) < 3:
            continue
        pci = normalize_pci(parts[0])
        if len(parts) >= 4:
            name = clean_gpu_name(", ".join(parts[1:-2]))
            util, temp = parts[-2], parts[-1]
        else:
            name = clean_gpu_name(parts[1])
            util, temp = parts[2], ""
        pct = None
        digits = "".join(c for c in util if c.isdigit())
        if digits:
            pct = max(0, min(100, int(digits)))
        tc = None
        tdigits = "".join(c for c in temp if c.isdigit())
        if tdigits:
            tc = int(tdigits)
        rows.append({"pci": pci, "name": name, "pct": pct, "temp": tc})
    return rows


def nvidia_smi_gpus():
    if not os.path.exists("/proc/driver/nvidia/version"):
        return []
    try:
        out = subprocess.run(
            ["nvidia-smi", "--query-gpu=pci.bus_id,name,utilization.gpu,temperature.gpu",
             "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=2,
        )
    except (OSError, subprocess.TimeoutExpired):
        return []
    if out.returncode != 0:
        return []
    return parse_nvidia_smi_gpus(out.stdout)


def pci_gpu_name(pci, sysfs_root="/sys"):
    try:
        out = subprocess.run(
            ["lspci", "-mm", "-s", pci],
            capture_output=True, text=True, timeout=2,
        )
    except (OSError, subprocess.TimeoutExpired):
        out = None
    if out and out.returncode == 0:
        for line in (out.stdout or "").splitlines():
            parts = re.findall(r'"([^"]*)"', line)
            if len(parts) >= 3:
                return clean_gpu_name(parts[1] + " " + parts[2])
            if ": " in line:
                return clean_gpu_name(line.split(": ", 1)[1])
    return "GPU"


def amd_busy_pct(pci, sysfs_root="/sys"):
    bases = [
        os.path.join(sysfs_root, "bus", "pci", "devices", pci),
    ]
    for base in bases:
        for path in glob.glob(os.path.join(base, "gpu_busy_percent")) + glob.glob(
            os.path.join(base, "drm", "card*", "device", "gpu_busy_percent")
        ):
            raw = "".join(c for c in read(path) if c.isdigit())
            if raw:
                return max(0, min(100, int(raw)))
    return None


def gpu_temp_for_path(path, vendor):
    hw = first_hwmon(path)
    if not hw:
        return None
    found = hwmon_temps(hw)
    if vendor == "0x1002":
        c = pick_label(found, ("junction", "hotspot", "edge", "gpu"))
    elif vendor == "0x8086":
        c = pick_label(found, ("gpu", "pkg"))
    else:
        c = pick_label(found, ("gpu", "temp"))
    if c is None and found:
        c = found[0][1]
    return c


def gpu_temp_c(sysfs_root="/sys", nvidia_c=None):
    if nvidia_c is not None:
        return int(nvidia_c)
    if os.path.realpath(sysfs_root) == os.path.realpath("/sys"):
        nv = nvidia_smi_temp()
        if nv is not None:
            return nv
    for hw in hwmon_dirs(sysfs_root):
        name = read(os.path.join(hw, "name")).lower()
        if name not in GPU_HWMON and not name.startswith("i915") and not name.startswith("xe"):
            continue
        found = hwmon_temps(hw)
        if name == "amdgpu":
            c = pick_label(found, ("junction", "hotspot", "edge", "gpu"))
        elif name in ("i915", "xe") or name.startswith("i915") or name.startswith("xe"):
            c = pick_label(found, ("gpu", "pkg"))
        else:
            c = pick_label(found, ("gpu", "temp"))
        if c is None and found:
            c = found[0][1]
        if c is not None:
            return c
    if intel_display(sysfs_root):
        for zone in glob.glob(os.path.join(sysfs_root, "class", "thermal", "thermal_zone*")):
            ztype = read(os.path.join(zone, "type"))
            if ztype == "B0D4" or ztype.lower() in ("igpu",):
                c = milli_c(read(os.path.join(zone, "temp")))
                if c is not None:
                    return c
    return None


def ram_temp_c(sysfs_root="/sys"):
    for hw in hwmon_dirs(sysfs_root):
        name = read(os.path.join(hw, "name")).lower()
        if skip_hwmon_name(name):
            continue
        found = hwmon_temps(hw)
        if name in RAM_HWMON:
            if found:
                return found[0][1]
            continue
        c = pick_label(found, ("sodimm", "dimm", "memory", "tmem", "dram"))
        if c is not None:
            return c
    for zone in glob.glob(os.path.join(sysfs_root, "class", "thermal", "thermal_zone*")):
        if read(os.path.join(zone, "type")).lower() == "tmem":
            c = milli_c(read(os.path.join(zone, "temp")))
            if c is not None:
                return c
    return None


def partition_parent(name):
    for pat in (
        r"(nvme\d+n\d+)p\d+$",
        r"(mmcblk\d+)p\d+$",
        r"([hs]d[a-z]+)\d+$",
        r"(vd[a-z]+)\d+$",
    ):
        m = re.match(pat, name)
        if m:
            return m.group(1)
    return None


def resolve_block(dev, sysfs_root="/sys"):
    name = os.path.basename(dev)
    if os.path.exists(dev):
        try:
            name = os.path.basename(os.path.realpath(dev))
        except OSError:
            pass
    seen = set()
    while name and name not in seen:
        seen.add(name)
        block = os.path.join(sysfs_root, "class", "block", name)
        slaves = os.path.join(block, "slaves")
        try:
            kids = os.listdir(slaves)
        except OSError:
            kids = []
        if kids:
            name = kids[0]
            continue
        parent = partition_parent(name)
        if parent and parent != name and os.path.isdir(os.path.join(sysfs_root, "class", "block", parent)):
            name = parent
            continue
        return name
    return name


def first_hwmon(path):
    for pattern in (
        os.path.join(path, "hwmon", "hwmon*"),
        os.path.join(path, "hwmon*"),
    ):
        for hw in sorted(glob.glob(pattern)):
            if glob.glob(os.path.join(hw, "temp*_input")):
                return hw
    return None


def disk_hwmon(dev, sysfs_root="/sys"):
    name = resolve_block(dev, sysfs_root)
    block = os.path.join(sysfs_root, "class", "block", name)
    hw = first_hwmon(block)
    if hw:
        return hw
    device = os.path.join(block, "device")
    if os.path.exists(device):
        hw = first_hwmon(os.path.realpath(device))
        if hw:
            return hw
        hw = first_hwmon(device)
        if hw:
            return hw
    return None


def disk_temp_c(dev, sysfs_root="/sys"):
    hw = disk_hwmon(dev, sysfs_root)
    if not hw:
        return None
    found = hwmon_temps(hw)
    c = pick_label(found, ("composite",))
    if c is not None:
        return c
    return found[0][1] if found else None


def mounted_disks():
    mounts = []
    try:
        out = subprocess.run(
            ["df", "-P", "-x", "tmpfs", "-x", "devtmpfs", "-x", "squashfs", "-x", "overlay", "-x", "iso9660"],
            capture_output=True, text=True, timeout=2,
        )
    except (OSError, subprocess.TimeoutExpired):
        return mounts
    seen = set()
    for line in (out.stdout or "").splitlines()[1:]:
        parts = line.split()
        if len(parts) < 6:
            continue
        src, mnt = parts[0], parts[5]
        if not src.startswith("/dev/") or src in seen:
            continue
        seen.add(src)
        mounts.append((mnt, src))
    return mounts


def collect_gpu_cards(sysfs_root="/sys"):
    live = os.path.realpath(sysfs_root) == os.path.realpath("/sys")
    pci_cards = list_pci_gpus(sysfs_root)
    nvidia = {}
    drm_pcts = {}
    if live:
        nvidia = {r["pci"]: r for r in nvidia_smi_gpus()}
        fd0, rc0, fd1, rc1, dt_ns = sample_gpu_snapshots(sysfs_root)
        drm_pcts = drm_pcts_from_snapshots(fd0, fd1, rc0, rc1, dt_ns)
    cards = []
    for g in pci_cards:
        pci, vendor = g["pci"], g["vendor"]
        nv = nvidia.get(pci)
        name = (nv or {}).get("name") or "GPU"
        pct = None if nv is None else nv.get("pct")
        temp = None if nv is None else nv.get("temp")
        if pct is None and vendor == "0x1002":
            pct = amd_busy_pct(pci, sysfs_root)
        if pct is None:
            pct = drm_pcts.get(pci)
        if pct is None and drm_pcts.get("*") is not None and len(pci_cards) == 1:
            pct = drm_pcts["*"]
        if name == "GPU" and live:
            name = pci_gpu_name(pci, sysfs_root)
        if temp is None:
            temp = gpu_temp_for_path(g["path"], vendor)
        if temp is None and vendor == "0x8086" and g.get("boot_vga"):
            for zone in glob.glob(os.path.join(sysfs_root, "class", "thermal", "thermal_zone*")):
                if read(os.path.join(zone, "type")) == "B0D4":
                    temp = milli_c(read(os.path.join(zone, "temp")))
                    break
        cards.append({"pci": pci, "name": name, "pct": pct, "temp": temp})
    if not cards and drm_pcts.get("*") is not None:
        cards.append({"pci": "gpu", "name": "GPU", "pct": drm_pcts["*"], "temp": None})
    return cards


def emit_gpus(sysfs_root="/sys"):
    cards = collect_gpu_cards(sysfs_root)
    if not cards:
        print("gpu n/a")
        return False
    best = None
    for c in cards:
        if best is None or (c["pct"] is not None and (best["pct"] is None or c["pct"] > best["pct"])):
            best = c
        print("gpu_dev %s %s" % (c["pci"], "n/a" if c["pct"] is None else c["pct"]))
        if c["name"]:
            print("gpu_dev_name %s %s" % (c["pci"], c["name"]))
        if c["temp"] is not None:
            print("gpu_dev_temp %s %d" % (c["pci"], c["temp"]))
    if best and best["pct"] is not None:
        print("gpu %d" % best["pct"])
        if best["name"]:
            print("gpu_name %s" % best["name"])
        if best["temp"] is not None:
            print("gpu_temp %d" % best["temp"])
        return True
    print("gpu n/a")
    return False


def emit_temps(sysfs_root="/sys"):
    def tok(v):
        return str(v) if v is not None else "n/a"
    print("cpu_temp %s" % tok(cpu_temp_c(sysfs_root)))
    print("ram_temp %s" % tok(ram_temp_c(sysfs_root)))
    if os.path.realpath(sysfs_root) != os.path.realpath("/sys"):
        return
    seen = {}
    for mnt, src in mounted_disks():
        key = resolve_block(src, sysfs_root)
        if key not in seen:
            seen[key] = disk_temp_c(src, sysfs_root)
        c = seen[key]
        if c is not None:
            print("disk_temp %s %d" % (mnt, c))


def main(argv):
    cmd = argv[1] if len(argv) > 1 else "tick"
    if cmd == "gpu":
        pct = sample_gpu_pct()
        if pct is None:
            return 0
        print("gpu %d" % pct)
        return 0
    if cmd == "temps":
        emit_temps()
        return 0
    if cmd == "tick":
        ok = emit_gpus()
        emit_temps()
        return 0 if ok else 1
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
