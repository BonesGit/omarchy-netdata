const fs = require("fs")
const path = require("path")
const vm = require("vm")

const src = fs.readFileSync(path.join(__dirname, "Model.js"), "utf8").replace(".pragma library", "")
const model = {}
vm.createContext(model)
vm.runInContext(src, model)

function assertEqual(actual, expected, label) {
  const left = JSON.stringify(actual)
  const right = JSON.stringify(expected)
  if (left !== right) {
    console.error("FAIL", label, "\n  got     ", left, "\n  expected", right)
    process.exitCode = 1
    return
  }
  console.log("ok", label)
}

assertEqual(
  model.derivedTempQuery("nvidia_smi.gpu_utilization"),
  { context: "nvidia_smi.gpu_temperature", scopeInstances: "" },
  "nvidia util -> gpu_temperature"
)
assertEqual(
  model.derivedTempQuery("nvidia_smi.gpu_temperature"),
  { context: "", scopeInstances: "" },
  "nvidia temp primary skips companion"
)
assertEqual(
  model.derivedTempQuery("amdgpu.gpu_utilization"),
  { context: "system.hw.sensor.temperature.input", scopeInstances: "*amdgpu*" },
  "amd util -> sensors amdgpu scope"
)
assertEqual(
  model.derivedTempQuery("system.cpu"),
  { context: "", scopeInstances: "" },
  "unknown context skips companion"
)

assertEqual(model.resolvedGpu({}), "nvidia", "missing gpu -> nvidia")
assertEqual(model.resolvedGpu({ gpu: "" }), "nvidia", "blank gpu -> nvidia")
assertEqual(model.resolvedGpu({ gpu: "nvidia" }), "nvidia", "explicit nvidia")
assertEqual(model.resolvedGpu({ gpu: "amd" }), "amd", "explicit amd")
assertEqual(model.resolvedGpu({ gpu: "custom" }), "nvidia", "unknown gpu -> nvidia")

assertEqual(model.configuredContext({}), "nvidia_smi.gpu_utilization", "blank settings use nvidia context")
assertEqual(model.configuredContext({ gpu: "amd" }), "amdgpu.gpu_utilization", "amd preset context")
assertEqual(model.configuredContext({ gpu: "nvidia", context: "amdgpu.gpu_utilization" }), "amdgpu.gpu_utilization", "context overrides gpu")
assertEqual(model.configuredContext({ context: "system.cpu" }), "system.cpu", "context override without gpu")

assertEqual(
  model.configuredTempQuery({}),
  { context: "nvidia_smi.gpu_temperature", scopeInstances: "" },
  "blank settings use nvidia temp"
)
assertEqual(
  model.configuredTempQuery({ gpu: "amd" }),
  { context: "system.hw.sensor.temperature.input", scopeInstances: "*amdgpu*" },
  "amd preset temp"
)
assertEqual(
  model.configuredTempQuery({ context: "amdgpu.gpu_utilization" }),
  { context: "system.hw.sensor.temperature.input", scopeInstances: "*amdgpu*" },
  "context override auto-picks amd temp"
)
assertEqual(
  model.configuredTempQuery({ gpu: "amd", tempContext: "nvidia_smi.gpu_temperature" }),
  { context: "nvidia_smi.gpu_temperature", scopeInstances: "" },
  "tempContext overrides gpu temp"
)
assertEqual(
  model.configuredTempQuery({ context: "nvidia_smi.gpu_temperature", tempContext: "nvidia_smi.gpu_temperature" }),
  { context: "", scopeInstances: "" },
  "same context as primary skips companion"
)

assertEqual(model.formatPercent(41.25), "41", "truncate percent")
assertEqual(model.formatPercent(41.9), "41", "truncate percent does not round")
assertEqual(model.formatPercent(null), "—", "missing percent")
assertEqual(model.formatTemp(47.166), "47°", "truncate temp")

// Backoff: the first retryAttempts polls stay at base, then each wait
// doubles, capped at the 5-minute liveness probe. (f = failures so far;
// the wait shown is the one before the next poll.)
assertEqual(model.backoffMs(0, 5000, 5), 5000, "no failures -> base (poll 1)")
assertEqual(model.backoffMs(4, 5000, 5), 5000, "fail 4 -> still base (poll 5)")
assertEqual(model.backoffMs(5, 5000, 5), 10000, "fail 5 -> 2x (poll 6)")
assertEqual(model.backoffMs(6, 5000, 5), 20000, "fail 6 -> 4x (poll 7)")
assertEqual(model.backoffMs(7, 5000, 5), 40000, "fail 7 -> 8x (poll 8)")
assertEqual(model.backoffMs(9, 5000, 5), 160000, "fail 9 -> 32x")
assertEqual(model.backoffMs(10, 5000, 5), 300000, "capped at 5 min")
assertEqual(model.backoffMs(3, 5000, 2), 20000, "attempts=2: doubling starts at poll 3")
assertEqual(model.backoffMs(10, 2000, 1), 300000, "capped with custom base")

// Retry window: user-set max continuous retry time (minutes -> ms),
// clamped to [1, 1440], default 2 hours (120 min).
assertEqual(model.configuredRetryWindowMs({}), 120 * 60 * 1000, "default -> 2h")
assertEqual(model.configuredRetryWindowMs({ retryWindowMinutes: 30 }), 30 * 60 * 1000, "30 min")
assertEqual(model.configuredRetryWindowMs({ retryWindowMinutes: 1440 }), 1440 * 60 * 1000, "max 1440")
assertEqual(model.configuredRetryWindowMs({ retryWindowMinutes: 10000 }), 1440 * 60 * 1000, "clamped to 1440")
assertEqual(model.configuredRetryWindowMs({ retryWindowMinutes: 0 }), 60 * 1000, "clamped to 1 min")
assertEqual(model.configuredRetryWindowMs({ retryWindowMinutes: "notanumber" }), 120 * 60 * 1000, "NaN -> default")
assertEqual(model.configuredRetryWindowMs(null), 120 * 60 * 1000, "null settings -> default")

assertEqual(model.formatTemp(47.9), "47°", "truncate temp does not round")
assertEqual(model.formatTemp(null), "—", "missing temp")

const url = model.latestUrl("localhost", "system.hw.sensor.temperature.input", { scopeInstances: "*amdgpu*" })
if (url.indexOf("scope_instances=" + encodeURIComponent("*amdgpu*")) < 0) {
  console.error("FAIL latestUrl missing scope", url)
  process.exitCode = 1
} else {
  console.log("ok latestUrl includes scope_instances")
}

const hist = model.historyUrl("localhost", "system.hw.sensor.temperature.input", 100, 200, 40, { scopeInstances: "*amdgpu*" })
if (hist.indexOf("scope_instances=" + encodeURIComponent("*amdgpu*")) < 0) {
  console.error("FAIL historyUrl missing scope", hist)
  process.exitCode = 1
} else {
  console.log("ok historyUrl includes scope_instances")
}
assertEqual(model.defaultTempTitle(), "GPU temperature", "temp title")
assertEqual(model.defaultMemTitle(), "GPU memory", "mem title")
assertEqual(model.defaultPowerTitle(), "GPU power", "power title")

// Memory + power query resolution: nvidia defaults, amd defaults (power
// scoped to amdgpu sensors), and the used-dimension rule for memory.
assertEqual(
  model.configuredMemQuery({}),
  { context: "nvidia_smi.gpu_frame_buffer_memory_usage", scopeInstances: "", dimension: "used", title: "GPU memory", units: "" },
  "blank settings -> nvidia mem used"
)
assertEqual(
  model.configuredPowerQuery({}),
  { context: "nvidia_smi.gpu_power_draw", scopeInstances: "", dimension: "", title: "GPU power", units: "" },
  "blank settings -> nvidia power"
)
assertEqual(
  model.configuredMemQuery({ gpu: "amd" }),
  { context: "amdgpu.gpu_mem_vram_usage", scopeInstances: "", dimension: "used", title: "GPU memory", units: "" },
  "amd preset mem used"
)
assertEqual(
  model.configuredPowerQuery({ gpu: "amd" }),
  { context: "system.hw.sensor.power.input", scopeInstances: "*amdgpu*", dimension: "", title: "GPU power", units: "" },
  "amd preset power scoped to amdgpu"
)
// A primary context override re-derives the vendor for memory/power.
assertEqual(
  model.configuredPowerQuery({ context: "amdgpu.gpu_utilization" }),
  { context: "system.hw.sensor.power.input", scopeInstances: "*amdgpu*", dimension: "", title: "GPU power", units: "" },
  "amd context override -> amd power"
)
assertEqual(
  model.configuredMemQuery({ context: "amdgpu.gpu_utilization" }),
  { context: "amdgpu.gpu_mem_vram_usage", scopeInstances: "", dimension: "used", title: "GPU memory", units: "" },
  "amd context override -> amd mem"
)
// An explicit memory context override keeps the used-dimension rule.
assertEqual(
  model.metricQuery({ memContext: "nvidia_smi.gpu_frame_buffer_memory_usage" }, "mem"),
  { context: "nvidia_smi.gpu_frame_buffer_memory_usage", scopeInstances: "", dimension: "used", title: "GPU memory", units: "" },
  "memContext override keeps used dimension"
)
// powerContext override wins.
assertEqual(
  model.metricQuery({ powerContext: "system.hw.sensor.power.input" }, "power").context,
  "system.hw.sensor.power.input",
  "powerContext override context"
)
// Same context as the primary skips the companion.
assertEqual(
  model.metricQuery({ context: "nvidia_smi.gpu_power_draw", powerContext: "nvidia_smi.gpu_power_draw" }, "power"),
  { context: "", scopeInstances: "", dimension: "", title: "", units: "" },
  "power same as primary -> empty"
)

assertEqual(model.configuredSplit({}), false, "missing split -> false")
assertEqual(model.configuredSplit({ split: true }), true, "split true")
assertEqual(model.configuredSplit({ split: false }), false, "split false")
assertEqual(model.configuredSplit({ split: "true" }), true, "split \"true\"")
assertEqual(model.configuredSplit({ split: "false" }), false, "split \"false\"")
assertEqual(model.configuredSplit({ split: 1 }), true, "split 1")
assertEqual(model.configuredSplit({ split: 0 }), false, "split 0")
assertEqual(model.configuredSplit({ split: "1" }), true, "split \"1\"")

const noGroup = model.latestUrl("localhost", "nvidia_smi.gpu_utilization")
if (noGroup.indexOf("group_by=") >= 0) {
  console.error("FAIL latestUrl leaked group_by", noGroup)
  process.exitCode = 1
} else {
  console.log("ok latestUrl without extra has no group_by")
}
const histNoGroup = model.historyUrl("localhost", "nvidia_smi.gpu_utilization", 100, 200, 40)
if (histNoGroup.indexOf("group_by=") >= 0) {
  console.error("FAIL historyUrl leaked group_by", histNoGroup)
  process.exitCode = 1
} else {
  console.log("ok historyUrl without extra has no group_by")
}

const grouped = model.latestUrl("localhost", "nvidia_smi.gpu_utilization", { groupBy: "instance" })
if (grouped.indexOf("group_by=instance") < 0) {
  console.error("FAIL latestUrl missing group_by", grouped)
  process.exitCode = 1
} else {
  console.log("ok latestUrl includes group_by=instance")
}
const histGrouped = model.historyUrl("localhost", "nvidia_smi.gpu_utilization", 100, 200, 40, { groupBy: "instance" })
if (histGrouped.indexOf("group_by=instance") < 0) {
  console.error("FAIL historyUrl missing group_by", histGrouped)
  process.exitCode = 1
} else {
  console.log("ok historyUrl includes group_by=instance")
}

const extraIn = { scopeInstances: "*amdgpu*" }
const extraBefore = { scopeInstances: extraIn.scopeInstances }
const bothExtra = model.queryExtra(extraIn, true)
assertEqual(extraIn, extraBefore, "queryExtra does not mutate input")
assertEqual(bothExtra.groupBy, "instance", "queryExtra sets groupBy when split")
assertEqual(bothExtra.scopeInstances, "*amdgpu*", "queryExtra keeps scope")
const bothUrl = model.latestUrl("localhost", "system.hw.sensor.temperature.input", bothExtra)
if (bothUrl.indexOf("group_by=instance") < 0 || bothUrl.indexOf("scope_instances=" + encodeURIComponent("*amdgpu*")) < 0) {
  console.error("FAIL latestUrl missing group_by+scope", bothUrl)
  process.exitCode = 1
} else {
  console.log("ok latestUrl includes group_by and scope_instances")
}
assertEqual(model.queryExtra(null, false), {}, "queryExtra empty when not split")
assertEqual(model.queryExtra(null, true), { groupBy: "instance" }, "queryExtra groupBy only")
assertEqual(model.queryExtra({ dimension: "used" }, false), { dimensions: "used" }, "queryExtra carries dimension")
assertEqual(
  model.queryExtra({ scopeInstances: "*amdgpu*", dimension: "used" }, true),
  { scopeInstances: "*amdgpu*", dimensions: "used", groupBy: "instance" },
  "queryExtra scope+dimension+split"
)

// dimensions=used is emitted on the URL so only the used dim is returned.
const memUrl = model.latestUrl("localhost", "nvidia_smi.gpu_frame_buffer_memory_usage", { dimensions: "used" })
if (memUrl.indexOf("dimensions=" + encodeURIComponent("used")) < 0) {
  console.error("FAIL latestUrl missing dimensions=used", memUrl)
  process.exitCode = 1
} else {
  console.log("ok latestUrl includes dimensions=used")
}
const memHist = model.historyUrl("localhost", "nvidia_smi.gpu_frame_buffer_memory_usage", 100, 200, 40, { dimensions: "used", groupBy: "instance" })
if (memHist.indexOf("dimensions=" + encodeURIComponent("used")) < 0 || memHist.indexOf("group_by=instance") < 0) {
  console.error("FAIL historyUrl missing dimensions+group_by", memHist)
  process.exitCode = 1
} else {
  console.log("ok historyUrl includes dimensions=used and group_by")
}
const utilNoDim = model.latestUrl("localhost", "nvidia_smi.gpu_utilization")
if (utilNoDim.indexOf("dimensions=") >= 0) {
  console.error("FAIL latestUrl leaked dimensions on util", utilNoDim)
  process.exitCode = 1
} else {
  console.log("ok latestUrl util has no dimensions param")
}

// Byte + watt formatting.
assertEqual(model.formatBytes(18520995000), "17.2 GiB", "bytes -> GiB")
assertEqual(model.formatBytes(2014726200), "1.9 GiB", "bytes ~2 GiB")
assertEqual(model.formatBytes(5 * 1024 * 1024), "5 MiB", "bytes -> MiB")
assertEqual(model.formatBytes(null), "—", "bytes null")
assertEqual(model.formatWatts(254), "254 W", "watts trunc")
assertEqual(model.formatWatts(13.86), "13.9 W", "watts one decimal")
assertEqual(model.formatWatts(null), "—", "watts null")
assertEqual(model.formatMetric(18520995000, "B"), "17.2 GiB", "metric bytes by unit")
assertEqual(model.formatMetric(254, "Watts"), "254 W", "metric watts by unit")
assertEqual(model.formatMetric(41.2, "percentage"), "41%", "metric percent by unit")

// pollerKey forks when memory/power configs differ.
assertEqual(
  model.pollerKey({ host: "razorback" }),
  model.pollerKey({ host: "razorback", refreshSeconds: 10 }),
  "refresh does not fork poller with mem+power"
)
if (model.pollerKey({ host: "localhost" }) === model.pollerKey({ host: "localhost", memContext: "system.cpu" })) {
  console.error("FAIL memContext override must fork a poller")
  process.exitCode = 1
} else {
  console.log("ok memContext override forks a poller")
}
if (model.pollerKey({ host: "localhost" }) === model.pollerKey({ host: "localhost", powerContext: "system.cpu" })) {
  console.error("FAIL powerContext override must fork a poller")
  process.exitCode = 1
} else {
  console.log("ok powerContext override forks a poller")
}

// Per-metric on/off toggles.
assertEqual(model.configuredShowTemp({}), true, "showTemp default on")
assertEqual(model.configuredShowMem({}), true, "showMem default on")
assertEqual(model.configuredShowPower({}), true, "showPower default on")
assertEqual(model.configuredShowMem({ showMem: false }), false, "showMem explicit false")
assertEqual(model.configuredShowPower({ showPower: "false" }), false, "showPower string false")
assertEqual(model.configuredShowTemp({ showTemp: "1" }), true, "showTemp string 1")

// Hidden mem -> no context (section hidden, polling skipped).
var memOff = model.configuredMemQuery({ host: "localhost", showMem: false })
assertEqual(memOff.context, "", "showMem=false empties mem context")
assertEqual(model.configuredMemQuery({ host: "localhost" }).context, "nvidia_smi.gpu_frame_buffer_memory_usage", "mem context on by default")
// Hidden power -> no context.
var powerOff = model.configuredPowerQuery({ host: "localhost", showPower: false })
assertEqual(powerOff.context, "", "showPower=false empties power context")
assertEqual(model.configuredPowerQuery({ host: "localhost", gpu: "amd" }).context, "system.hw.sensor.power.input", "amd power context on by default")
// Hidden temp -> no context (both override and default paths).
assertEqual(model.configuredTempQuery({ host: "localhost", showTemp: false }).context, "", "showTemp=false empties temp context")
assertEqual(model.configuredTempQuery({ host: "localhost", showTemp: false, tempContext: "system.cpu" }).context, "", "showTemp=false wins over temp override")
assertEqual(model.configuredTempQuery({ host: "localhost" }).context, "nvidia_smi.gpu_temperature", "nvidia temp context on by default")
// Toggles fork pollers (sibling widgets with different visibility).
if (model.pollerKey({ host: "localhost" }) === model.pollerKey({ host: "localhost", showMem: false })) {
  console.error("FAIL showMem toggle must fork a poller")
  process.exitCode = 1
} else {
  console.log("ok showMem toggle forks a poller")
}
if (model.pollerKey({ host: "localhost" }) === model.pollerKey({ host: "localhost", showTemp: false, showPower: false })) {
  console.error("FAIL temp+power toggles must fork a poller")
  process.exitCode = 1
} else {
  console.log("ok temp+power toggles fork a poller")
}

const uuidA = "gpu-ef49ee8f-aaaa-4aaa-8aaa-04fa56b0aaaa"
const uuidB = "gpu-913c9115-bbbb-4bbb-8bbb-cdd016049eba"
assertEqual(
  model.seriesKey("nvidia_smi.gpu_" + uuidA + "_gpu_utilization@razorback"),
  uuidA,
  "seriesKey extracts nvidia util uuid"
)
assertEqual(
  model.seriesKey("nvidia_smi.gpu_" + uuidA + "_gpu_temperature@razorback"),
  uuidA,
  "seriesKey extracts nvidia temp uuid"
)
const amdUtil = "amdgpu.gpu_utilization_unknown_AMD_GPU_card1@omarchy-bee"
const amdTemp = "sensors.temperature_amdgpu-pci-c400_temp1_edge_input@omarchy-bee"
assertEqual(model.seriesKey(amdUtil), amdUtil, "seriesKey falls back to AMD util label")
assertEqual(model.seriesKey(amdTemp), amdTemp, "seriesKey falls back to AMD temp label")
if (model.seriesKey(amdUtil) === model.seriesKey(amdTemp)) {
  console.error("FAIL AMD util/temp keys should not match")
  process.exitCode = 1
} else {
  console.log("ok AMD util/temp keys differ")
}

function splitPayload(labels, rows) {
  return { result: { labels: labels, data: rows } }
}

const utilPayload = splitPayload(
  [
    "time",
    "nvidia_smi.gpu_" + uuidB + "_gpu_utilization@razorback",
    "nvidia_smi.gpu_" + uuidA + "_gpu_utilization@razorback"
  ],
  [[100, 51, 31.5], [101, 50, 32]]
)
const utilSeries = model.parseSeriesSplit(utilPayload)
assertEqual(utilSeries.length, 2, "parseSeriesSplit 2 columns")
assertEqual(utilSeries[0].name, "GPU1", "first column name")
assertEqual(utilSeries[1].name, "GPU2", "second column name")
assertEqual(utilSeries.map(function(s) { return s.key }), [uuidB, uuidA], "keeps util column order")
assertEqual(utilSeries[0].points.map(function(p) { return p.v }), [51, 50], "GPU 1 is first util column")
assertEqual(utilSeries[1].points.map(function(p) { return p.v }), [31.5, 32], "GPU 2 is second util column")

const tempPayload = splitPayload(
  [
    "time",
    "nvidia_smi.gpu_" + uuidA + "_gpu_temperature@razorback",
    "nvidia_smi.gpu_" + uuidB + "_gpu_temperature@razorback"
  ],
  [[100, 81, 65]]
)
const tempSeries = model.parseSeriesSplit(tempPayload)
assertEqual(tempSeries.map(function(s) { return s.key }), [uuidA, uuidB], "temp keeps its column order")
assertEqual(tempSeries[0].points[0].v, 81, "temp first column is uuidA")
assertEqual(tempSeries[1].points[0].v, 65, "temp second column is uuidB")

const alignedTemp = model.alignSeriesByKey(utilSeries, tempSeries)
assertEqual(alignedTemp.map(function(s) { return s.key }), [uuidB, uuidA], "align temp to util keys")
assertEqual(alignedTemp.map(function(s) { return s.name }), ["GPU1", "GPU2"], "align copies util names")
assertEqual(alignedTemp[0].points[0].v, 65, "aligned GPU 1 is uuidB temp")
assertEqual(alignedTemp[1].points[0].v, 81, "aligned GPU 2 is uuidA temp")
assertEqual(model.alignSeriesByKey([], tempSeries), tempSeries, "align with no util leaves temp")

const oneCol = model.parseSeriesSplit(splitPayload(["time", "gpu"], [[100, 41.25]]))
assertEqual(oneCol.length, 1, "1-column payload -> one series")
assertEqual(oneCol[0].name, "GPU1", "1-column name")
assertEqual(oneCol[0].points[0].v, 41.25, "1-column value")

const withNull = model.parseSeriesSplit(splitPayload(
  ["time", "a", "b"],
  [[100, null, 12], [101, 8, null]]
))
assertEqual(withNull[0].points[0].v, null, "null cell preserved")
assertEqual(model.latestValuePerSeries(withNull), [8, 12], "latest skips null")
assertEqual(model.maxOf(model.latestValuePerSeries(withNull)), 12, "maxOf skips null")

const averaged = model.parseSeries(splitPayload(["time", "a", "b"], [[100, 10, 30]]))
assertEqual(averaged.length, 1, "parseSeries one averaged series")
assertEqual(averaged[0].v, 20, "parseSeries averages columns")

assertEqual(model.maxOf([5, 95]), 95, "maxOf 5/95")
assertEqual(model.maxOf([null, 12]), 12, "maxOf null/12")
assertEqual(model.maxOf([null]), null, "maxOf only null")

const merged = model.mergeSeriesPoint(utilSeries, 102, [49, 33])
assertEqual(merged[0].points[merged[0].points.length - 1], { t: 102, v: 49 }, "merge last GPU 1")
assertEqual(merged[1].points[merged[1].points.length - 1], { t: 102, v: 33 }, "merge last GPU 2")
const mismatch = model.mergeSeriesPoint(utilSeries, 102, [49])
assertEqual(mismatch.map(function(s) { return s.points.length }), [2, 2], "length mismatch does not merge")

const pruned = model.pruneSeries(merged, 102)
assertEqual(pruned.length, 2, "pruneSeries keeps both")
assertEqual(pruned[0].points[pruned[0].points.length - 1].t, 102, "pruneSeries keeps newest")

assertEqual(model.formatValueList([5, 95], model.formatPercent, "%"), "5% / 95%", "format percent list")
assertEqual(model.formatValueList([47.9, 52], model.formatTemp), "47° / 52°", "format temp list")
assertEqual(model.formatValueList([5], model.formatPercent, "%"), "5%", "format single percent")

// valueAtTime: fills from the nearest real sample within the gap tolerance,
// never bridges a data hole (the 2h-outage case), and nulls outside data.
const dense = [{ t: 100, v: 10 }, { t: 105, v: null }, { t: 110, v: 30 }]
assertEqual(model.valueAtTime(dense, 107), 10, "fills forward from last real sample")
assertEqual(model.valueAtTime(dense, 102), 10, "fills backward from next real sample")
assertEqual(model.valueAtTime(dense, 100), 10, "exact sample time")

// A long outage: 2h hole between t=0 and t=7200. 5s cadence nearby.
const outage = [
  { t: 0, v: 20 }, { t: 5, v: 21 }, { t: 10, v: 22 },
  { t: 7200, v: 40 }, { t: 7205, v: 41 }, { t: 7210, v: 42 }
]
assertEqual(model.valueAtTime(outage, 3600), null, "2h outage reads as a gap")
assertEqual(model.valueAtTime(outage, 11), 22, "just before the hole still shows data")
assertEqual(model.valueAtTime(outage, 7199), 40, "just after the hole shows new data")
assertEqual(model.valueAtTime(outage, -100), 20, "window edge before data fills from first sample")

// Threshold scales with sampling interval but is capped at 40 min: hourly
// points get a 40-min fill, so a 2h hole is still a gap but a 30-min hover
// off the nearest sample still shows that sample.
const hourly = [{ t: 0, v: 1 }, { t: 7200, v: 2 }]
assertEqual(model.valueAtTime(hourly, 3600), null, "capped fill: 2h hole stays a gap")
assertEqual(model.valueAtTime(hourly, 1500), 1, "30-min hover fills from nearest sample")
assertEqual(model.valueAtTime(hourly, 2500), null, "beyond 40-min cap is a gap")

assertEqual(model.valueAtTime(null, 5), null, "no points is null")
assertEqual(model.valueAtTime([], 5), null, "empty points is null")

assertEqual(
  model.pollerKey({ host: "razorback" }),
  model.pollerKey({ host: "http://razorback:19999" }),
  "razorback host aliases share a poller"
)
assertEqual(
  model.pollerKey({ host: "razorback", split: true }),
  model.pollerKey({ host: "razorback", split: false, refreshSeconds: 10 }),
  "split and refresh do not fork a poller"
)
assertEqual(
  model.pollerKey({}),
  model.pollerKey({ host: "localhost" }),
  "blank settings share the localhost nvidia poller"
)
if (model.pollerKey({ host: "razorback" }) === model.pollerKey({ host: "localhost", gpu: "amd" })) {
  console.error("FAIL razorback nvidia and localhost amd must not share a poller")
  process.exitCode = 1
} else {
  console.log("ok razorback nvidia and localhost amd are distinct pollers")
}
if (model.pollerKey({ host: "localhost", gpu: "amd" }) === model.pollerKey({ host: "localhost", gpu: "nvidia" })) {
  console.error("FAIL localhost amd and nvidia must not share a poller")
  process.exitCode = 1
} else {
  console.log("ok localhost amd and nvidia are distinct pollers")
}
assertEqual(
  model.pollerKey({ host: "localhost", context: "system.cpu" }) === model.pollerKey({ host: "localhost" }),
  false,
  "context override forks a poller"
)

if (!process.exitCode) console.log("all tests passed")
