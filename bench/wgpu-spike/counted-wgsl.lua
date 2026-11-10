-- Untimed conformance for compiler-emitted WGSL, independent of SPIR-V.
-- The argument names the directory containing the four counted-loop shaders.
--
-- Drives wgpu-native through the runtime's FFI binding directly: each shader
-- declares its own three bindings in group 0, which the device derives a
-- layout for, rather than the generated kernels' fixed group scheme.
local ffi = require("ffi")
local bit = require("bit")
local wgpu = require("nupp.runtime.provider.wgpu")

local root = assert(arg[1], "usage: counted-wgsl.lua ARTIFACT_DIRECTORY")
local lib = wgpu.library()
local callbacks = wgpu.callbacks()

local function callbackInfo(callback)
    local userdata, key = wgpu.token()
    local info = ffi.new("WGPUCallbackInfo")
    info.mode = 2
    info.callback = callback
    info.userdata1 = userdata
    return info, key
end

local faultUserdata, faultKey = wgpu.faultsink()
local function faults()
    local recorded = wgpu.takefaults(faultKey)
    assert(#recorded == 0, table.concat(recorded, "; "))
end

local instance
do
    local backends = wgpu.requestedbackends()
    local descriptor
    if backends ~= 0 then
        local extras = ffi.new("WGPUInstanceExtras")
        extras.chain.sType = wgpu.STYPE_INSTANCE_EXTRAS
        extras.backends = backends
        descriptor = ffi.new("WGPUInstanceDescriptor")
        descriptor.nextInChain = ffi.cast("WGPUChainedStruct *", extras)
        instance = lib.wgpuCreateInstance(descriptor)
    else
        instance = lib.wgpuCreateInstance(nil)
    end
end
local info, key = callbackInfo(callbacks.adapter)
lib.wgpuInstanceRequestAdapter(instance, nil, info)
lib.wgpuInstanceProcessEvents(instance)
local adapter = assert(wgpu.take(key), "no adapter answered")
assert(adapter.status == wgpu.STATUS_SUCCESS, adapter.message)
adapter = adapter.value
do
    local described = ffi.new("WGPUAdapterInfo")
    lib.wgpuAdapterGetInfo(adapter, described)
    print(("adapter=%s: %s"):format(wgpu.backendname(described.backendType),
        ffi.string(described.device.data, described.device.length)))
    lib.wgpuAdapterInfoFreeMembers(described)
end
local request = ffi.new("WGPUDeviceDescriptor")
request.uncapturedErrorCallbackInfo.callback = callbacks.error
request.uncapturedErrorCallbackInfo.userdata1 = faultUserdata
info, key = callbackInfo(callbacks.device)
lib.wgpuAdapterRequestDevice(adapter, request, info)
lib.wgpuInstanceProcessEvents(instance)
local device = assert(wgpu.take(key), "no device answered")
assert(device.status == wgpu.STATUS_SUCCESS, device.message)
device = device.value
local queue = lib.wgpuDeviceGetQueue(device)

local count = 257
local function buffer(size, usage)
    local descriptor = ffi.new("WGPUBufferDescriptor")
    descriptor.size = size
    descriptor.usage = usage
    return lib.wgpuDeviceCreateBuffer(device, descriptor)
end
local input = buffer(count * 4, wgpu.BUFFER_USAGE_STORAGE + wgpu.BUFFER_USAGE_COPY_DST)
local output = buffer(count * 4, wgpu.BUFFER_USAGE_STORAGE + wgpu.BUFFER_USAGE_COPY_SRC)
local uniform = buffer(32, wgpu.BUFFER_USAGE_UNIFORM + wgpu.BUFFER_USAGE_COPY_DST)
local readback = buffer(count * 4, wgpu.BUFFER_USAGE_MAP_READ + wgpu.BUFFER_USAGE_COPY_DST)
local initial = ffi.new("uint32_t[?]", count)
for index = 0, count - 1 do
    initial[index] = index * 17 + 3
end
lib.wgpuQueueWriteBuffer(queue, input, 0, initial, count * 4)

-- The exact sums the shaders compute, by the 64-bit loops the Rust oracle ran.
local function expected(name, first, last)
    if name == "literal" then
        return 68
    elseif name == "snapshots" then
        return 1000 + (first <= last and last - first + 1 or 0)
    elseif name == "boundaries" then
        local total = 0
        for index = first, last do
            total = total + 1 + (index < 0 and 100 or 0) + (index == 2147483647 and 1000 or 0)
        end
        return total
    end
    local total = 0
    for index = first, last do
        if index ~= first then
            total = total + 11
            if index == 3 then
                break
            end
        end
    end
    return total
end

local checked = 0
for _, name in ipairs({"literal", "boundaries", "snapshots", "control"}) do
    local file = assert(io.open(root .. "/" .. name .. ".wgsl", "rb"))
    local text = file:read("*a")
    file:close()
    local source = ffi.new("WGPUShaderSourceWGSL")
    source.chain.sType = wgpu.STYPE_SHADER_SOURCE_WGSL
    source.code = wgpu.view(text)
    local moduleDescriptor = ffi.new("WGPUShaderModuleDescriptor")
    moduleDescriptor.nextInChain = ffi.cast("WGPUChainedStruct *", source)
    local shader = lib.wgpuDeviceCreateShaderModule(device, moduleDescriptor)
    local pipelineDescriptor = ffi.new("WGPUComputePipelineDescriptor")
    pipelineDescriptor.compute.module = shader
    -- wgpu-native reads a null entry point as an empty name, so name the one
    -- compute entry point the emitter wrote.
    local entryPoint = assert(text:match("@compute[^\n]*\n%s*fn%s+([%w_]+)"), name .. " has no compute entry point")
    pipelineDescriptor.compute.entryPoint = wgpu.view(entryPoint)
    local pipeline = lib.wgpuDeviceCreateComputePipeline(device, pipelineDescriptor)
    faults()
    local entries = ffi.new("WGPUBindGroupEntry[3]")
    for index, value in ipairs({input, output, uniform}) do
        entries[index - 1].binding = index - 1
        entries[index - 1].buffer = value
        entries[index - 1].size = ffi.cast("uint64_t", -1)
    end
    local groupDescriptor = ffi.new("WGPUBindGroupDescriptor")
    groupDescriptor.layout = lib.wgpuComputePipelineGetBindGroupLayout(pipeline, 0)
    groupDescriptor.entryCount = 3
    groupDescriptor.entries = entries
    local group = lib.wgpuDeviceCreateBindGroup(device, groupDescriptor)
    local cases
    if name == "literal" then
        cases = {{0, 0}}
    elseif name == "snapshots" then
        cases = {{1, 4}, {3, 2}}
    else
        cases = {{1, 4}, {0, 0}, {3, 2}, {-2, 1}, {2147483645, 2147483647}, {-2147483648, -2147483646}}
    end
    for _, case in ipairs(cases) do
        local first, last = case[1], case[2]
        local values = ffi.new("uint32_t[8]", {count, count, count, 0, 0, bit.tobit(first), bit.tobit(last), 0})
        lib.wgpuQueueWriteBuffer(queue, uniform, 0, values, 32)
        local encoder = lib.wgpuDeviceCreateCommandEncoder(device, nil)
        local pass = lib.wgpuCommandEncoderBeginComputePass(encoder, nil)
        lib.wgpuComputePassEncoderSetPipeline(pass, pipeline)
        lib.wgpuComputePassEncoderSetBindGroup(pass, 0, group, 0, nil)
        lib.wgpuComputePassEncoderDispatchWorkgroups(pass, math.ceil(count / 256), 1, 1)
        lib.wgpuComputePassEncoderEnd(pass)
        lib.wgpuComputePassEncoderRelease(pass)
        lib.wgpuCommandEncoderCopyBufferToBuffer(encoder, output, 0, readback, 0, count * 4)
        local commands = ffi.new("WGPUCommandBuffer[1]")
        commands[0] = lib.wgpuCommandEncoderFinish(encoder, nil)
        lib.wgpuQueueSubmit(queue, 1, commands)
        lib.wgpuCommandBufferRelease(commands[0])
        lib.wgpuCommandEncoderRelease(encoder)
        info, key = callbackInfo(callbacks.map)
        lib.wgpuBufferMapAsync(readback, wgpu.MAP_MODE_READ, 0, count * 4, info)
        lib.wgpuDevicePoll(device, true, nil)
        lib.wgpuInstanceProcessEvents(instance)
        local mapped = assert(wgpu.take(key), "the readback never mapped")
        assert(mapped.status == wgpu.STATUS_SUCCESS, mapped.message)
        local data = ffi.cast("const uint32_t *", lib.wgpuBufferGetConstMappedRange(readback, 0, count * 4))
        local sum = expected(name, first, last)
        for index = 0, count - 1 do
            local want = (index * 17 + 3 + sum) % 4294967296
            assert(data[index] == want, ("%s %d..%d index%d: %d, expected %d"):format(name, first, last, index,
                data[index], want))
        end
        lib.wgpuBufferUnmap(readback)
        faults()
        checked = checked + 1
    end
    lib.wgpuBindGroupRelease(group)
    lib.wgpuComputePipelineRelease(pipeline)
    lib.wgpuShaderModuleRelease(shader)
end
print(("WGSL counted loops: %d cases, %d output values checked"):format(checked, checked * count))
