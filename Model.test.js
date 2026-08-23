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

assertEqual(model.formatTemp(47.166), "47°", "round temp")
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

if (!process.exitCode) console.log("all tests passed")
