# omarchy-netdata

Omarchy Quattro menubar widget for tracking GPU usage of a remote host, while running local AI, via a [Netdata](https://www.netdata.cloud/) remote host. Shows GPU utilization in the menubar and a historical chart in a popup.

![GPU usage](preview.png)

## Features

- Bar pill with a status mark and the configured hostname
- Click the pill for a theme-following popup with current usage and a historical line chart
- Scroll to zoom the time window; drag to pan
- Preset chips: 3D, 2D, 24H, 6H, 3H, 1H, and Live
- Colors follow the active Omarchy theme (`Color` / `Style`)
- Status mark states:
  - Grey square outline when polling is paused
  - Grey solid circle when polling but the host is unreachable
  - Green below 30% GPU, yellow from 30–70%, red above 70%
- Green and yellow stay semantic so themes that alias `green` to gold still read correctly

Default host is `localhost` (port `19999`). The metric is Netdata **v3** context `nvidia_smi.gpu_utilization` (not the per-GPU chart id).

## Install

```bash
omarchy plugin add https://github.com/BonesGit/omarchy-netdata.git --enable
```

The widget lands in the right section of the bar. Update with `omarchy plugin update io.github.bonesgit.omarchy-netdata`. Remove with `omarchy plugin remove io.github.bonesgit.omarchy-netdata`.

### Manual install

Omarchy refuses symlinks inside a plugin folder, so if you cloned this repo, copy it in:

```bash
mkdir -p ~/.config/omarchy/plugins/io.github.bonesgit.omarchy-netdata
rsync -a --delete --exclude .git ./ ~/.config/omarchy/plugins/io.github.bonesgit.omarchy-netdata/
omarchy plugin validate ~/.config/omarchy/plugins/io.github.bonesgit.omarchy-netdata
omarchy-shell shell rescanPlugins
omarchy plugin enable io.github.bonesgit.omarchy-netdata --section right --after omarchy.tray
```

After editing this repo, rsync again, or run `./install-dev.sh` from the clone. Files saved under `~/.config/omarchy/plugins/io.github.bonesgit.omarchy-netdata/` reload automatically; `omarchy-shell shell rescanPlugins` forces discovery.

## Dependencies

- **[Netdata](https://www.netdata.cloud/)** agent reachable from your machine (default `localhost:19999`). The plugin polls the Netdata **v3** HTTP API.
- `curl` — used for live and history fetches. Omarchy already ships it.
- `omarchy-launch-browser` — opens the Netdata dashboard when you click the hostname in the popup.
- **Default metric:** `nvidia_smi.gpu_utilization`. Your Netdata host needs the NVIDIA SMI collector and a GPU that exposes utilization. Change `context` in settings for other metrics or non-NVIDIA hosts.

The plugin only reads metrics from the host you configure. It does not install Netdata, collect GPU data itself, or modify your Netdata configuration.

## Remove

```bash
omarchy plugin remove io.github.bonesgit.omarchy-netdata
```



## Settings

Set from the bar or `shell.json`:

```bash
omarchy bar set io.github.bonesgit.omarchy-netdata host localhost
omarchy bar set io.github.bonesgit.omarchy-netdata refreshSeconds 5
omarchy bar set io.github.bonesgit.omarchy-netdata retryAttempts 5
omarchy bar set io.github.bonesgit.omarchy-netdata context nvidia_smi.gpu_utilization
omarchy bar set io.github.bonesgit.omarchy-netdata dashboardUrl http://localhost:19999/#menu_system_submenu_gpu
```

`host` accepts `hostname`, `hostname:port`, `http://hostname:port`, or an IP. Port defaults to `19999`.

`dashboardUrl` is what the popup hostname opens in the browser. Leave it empty to use `http://<host>:<port>`.

`retryAttempts` is consecutive failed live polls before the widget auto-pauses (default 5). The wait between those polls is `refreshSeconds` (default 5). A successful poll resets the counter. Play resumes polling.

`allowMultiple` is on, so you can put another copy on the bar later and point it at a different machine.

## Popup

- Left click the pill: open / close
- Click the hostname in the popup: open Netdata in the browser
- Right or middle click: refresh now
- Scroll on the chart: zoom time range around the cursor (up to 3 days)
- Drag the chart: pan in time
- Play/pause (bottom left): start/stop automatic Netdata polling. Consecutive failed polls auto-pause after `retryAttempts`.
- `3D` / `2D` / `24H` / `6H` / `3H` / `1H` / `Live` chips: jump the window
- `+` / `-` or up / down: zoom
- left / right: pan
- `0` or Live: jump back to a live 10-minute window
- `r`: refresh
- Esc: close



## Layout

```
manifest.json      plugin contract
BarWidget.qml      bar pill + panel host
Panel.qml          KeyboardPanel popup
Service.qml        Netdata v3 polling
GpuChart.qml       pan/zoom canvas
Model.js           parse / window math
```

This follows the Omarchy marketplace bar-widget + nested panel pattern.

## Coming soon

More netdata metrics and visualizations coming soon.