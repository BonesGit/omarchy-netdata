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

const interp = model.interpolate([{ t: 100, v: 10 }, { t: 101, v: null }, { t: 102, v: 30 }], 101.5)
assertEqual(interp, 25, "interpolate skips null cells")

if (!process.exitCode) console.log("all tests passed")
