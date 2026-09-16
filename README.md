# Hardware Tooltip

An Omarchy bar widget that names the silicon in the machine, then stays out of the way.

Click the chip for a Power-style panel: CPU model, temperature, and per-core bars, RAM type/speed and temp, GPU name, temperature, and load, disk model, fill, and temp. It follows the active Omarchy theme. Right-click opens `btop` if you want the full TUI.

<p align="center">
  <img src="preview.gif" alt="Left-click opens the Hardware Tooltip panel; click again to close" width="360">
</p>

<p align="center">
  <img src="preview.png" alt="Hardware Tooltip click panel" width="240">
  <img src="docs/theme-night.png" alt="Hardware Tooltip after switching to a dark pink theme" width="240">
</p>

| Left click | Right click |
| --- | --- |
| CPU name/temp, per-core bars, RAM type/speed/temp, GPU name/temp, storage model, fill, and temp | Launch or focus `btop` |

Load-aware status lines rotate the same way the Power panel does — idle machines loaf, busy GPUs push pixels, a local model run starts chewing context.

## Why this exists

Omarchy Quattro's bar no longer ships a glance for *what this computer is*. Other listed plugins cover adjacent jobs:

- **btop Activity** — a btop companion: launch, window mode, process sort, compact meters
- **System Stats / Vitals / Activity Monitor** — full monitors with tabs, graphs, or process control

Hardware Tooltip is the other thing: a themed click panel you can read in one look, with hardware identity on the labels, not just percentages. It is not a btop frontend.

## ASRock BC-250

Tuned for the BC-250 / Cyan Skillfish board (`1002:13fe`). Linux binds the GPU as `amdgpu`, but SMU telemetry on this cut-down Oberon part is empty, so generic AMD tools report a stuck `0%`:

| Signal | What Linux does on a BC-250 |
| --- | --- |
| `gpu_busy_percent` | node exists, `read()` returns `ENOTSUPP` |
| `gpu_metrics` `average_gfx_activity` | stays `0xFFFF` |
| `radeontop` | unknown card, stuck `0%` |
| DIMM / SPD | none — 16 GB soldered GDDR6, `dmidecode` / `inxi` show type `N/A` and a `1750 MT/s` command clock |

This widget:

- samples GPU load from `/proc/*/fdinfo` `drm-engine-*` time (Render/3D) instead of the broken busy node
- labels memory as **GDDR6 14000 MT/s** from the published 14 Gbps-per-pin spec, not the command clock

Ordinary Radeons still use `gpu_busy_percent`. Intel uses DRM fdinfo / RC6. NVIDIA uses `nvidia-smi` only when the driver is actually loaded.

The 16 GB of unified memory is soldered GDDR6, not DIMMs, so `dmidecode` / `inxi` report `type: N/A` (the panel used to show a lone **N**) and a single `1750 MT/s` command clock. There is no SPD to read. On PCI `1002:13fe` / DMI `BC-250` the widget uses the published 14 Gbps-per-pin spec as **GDDR6 14000 MT/s**.

## Install

Plugins run as unsandboxed code inside `omarchy-shell`. Only add repos you trust. No sudo or pkexec is required.

```bash
omarchy plugin add https://github.com/IM0001GT/omarchy-hw-tooltip --enable
```

That clones into `~/.config/omarchy/plugins/im0001gt.hw-tooltip/`, validates the manifest, and can drop the widget on the right side of the bar, next to Power.

Intel and AMD need no extra packages. NVIDIA GPU load uses `nvidia-smi` from `nvidia-utils`, which Omarchy already ships with the NVIDIA driver stack. If that tool is missing on NVIDIA hardware, the widget shows it on the GPU line and sends one desktop notice. The widget still works without it; GPU load just reads `n/a`.

## Use

- **Left click** the chip — panel with CPU, memory, GPU, and storage
- **Right click** — launch or focus `btop`
- Click the chip again, or anywhere outside, to close

The panel sizes itself to the hardware in the machine: more CPU threads add columns and height, extra disks grow the storage block, and the card still stops at the screen edge. On a 16-core / 32-thread desktop the thread grid uses four columns so Memory, GPU, and Storage stay on screen.

Move it with `omarchy bar move im0001gt.hw-tooltip`.

## Update

```bash
omarchy plugin update im0001gt.hw-tooltip --yes
omarchy restart shell
```

`omarchy plugin update` only fast-forwards the git checkout. Quickshell can keep the previous QML in memory until the shell restarts.

## Uninstall

```bash
omarchy plugin remove im0001gt.hw-tooltip
```

## Requirements

- [Omarchy](https://omarchy.org/) with the shell plugin CLI (`omarchy plugin add`)
- `btop` and `jq` (already on Omarchy)
- Optional `nvidia-utils`, only if `nvidia-smi` is missing (Omarchy usually already has it)

| GPU | Extra package | How load is read |
| --- | --- | --- |
| Intel | none | DRM fdinfo engine busy (`drm-engine-*` on i915, `drm-cycles-*` on xe), then RC6 / GT idle residency. No `kernel.perf_event_paranoid` change |
| NVIDIA | `nvidia-utils` | `nvidia-smi`, and only when the NVIDIA driver is loaded |
| AMD | none | `gpu_busy_percent`. If that node is missing or `ENOTSUPP` (BC-250), DRM fdinfo engine time |

Hybrid laptops and multi-GPU desktops list each card the same way storage lists each mount: name, load, and one headline temperature.

## Temperatures

Each device in the panel shows one headline temperature when the kernel exposes it: CPU package / Tctl, GPU junction (AMD) or GPU die, a DIMM/SODIMM reading, and NVMe Composite (or the drive's primary sensor). Extra per-core, per-junction, and ambient/wifi/battery sensors stay out of the tooltip.

## Layout

```text
manifest.json          Omarchy plugin manifest (must live at repo root)
HardwareTooltip.qml    Bar icon + click panel
preview.gif            README demo
preview.png            Marketplace still (teal theme)
docs/theme-night.png   Same panel after a theme change
scripts/system-usage   CPU / RAM / GPU / disk sampler
scripts/hw_tooltip.py  Intel xe load + headline temperatures
tests/test_hw_tooltip.py
```

The repo root **is** the plugin. That is what `omarchy plugin add` and `omarchy plugin validate` expect.

## Credits

- [pisolutions-es](https://github.com/pisolutions-es) — Intel xe GPU load from fdinfo cycles and GT idle residency
- [hlasensky](https://github.com/hlasensky) — CPU and GPU temperature display
- [jotapesse](https://github.com/jotapesse) — memory and storage temperatures

## License

MIT. See [LICENSE](LICENSE).
