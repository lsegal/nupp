-- The test-only Wasmtime host, driving Wasmtime 48's prebuilt C API through
-- LuaJIT's FFI. It loads every independent SIMD128 kernel a schema-3 units
-- manifest names into one store and carries the browser bridge ABI across: one
-- eight-byte argument and result slot per value, scalar and struct spans copied
-- into guest memory through the module's own allocator, and writable spans
-- copied back out once the kernel returns.
local ffi = require("ffi")
-- Held before a browser bundle replaces io in the same Lua state.
local fileOpen = io.open
local M = {}

local TRANSFER_LIMIT = 2 * 1024 * 1024

-- The declarations below follow the v48 headers exactly where a layout is
-- observable: the release library is built with GC, so a value carries the
-- 24-byte reference union, and a memory handle is a padded 24-byte struct.
ffi.cdef[[
typedef struct wasm_config_t wasm_config_t;
typedef struct wasm_engine_t wasm_engine_t;
typedef struct wasm_valtype_t wasm_valtype_t;
typedef struct wasm_functype_t wasm_functype_t;
typedef struct wasm_externtype_t wasm_externtype_t;
typedef struct wasm_importtype_t wasm_importtype_t;
typedef struct wasm_trap_t wasm_trap_t;
typedef struct wasmtime_error wasmtime_error_t;
typedef struct wasmtime_store wasmtime_store_t;
typedef struct wasmtime_context wasmtime_context_t;
typedef struct wasmtime_module wasmtime_module_t;
typedef struct wasmtime_linker wasmtime_linker_t;
typedef struct wasmtime_caller wasmtime_caller_t;
typedef struct { size_t size; uint8_t *data; } wasm_byte_vec_t;
typedef struct { size_t size; wasm_valtype_t **data; } wasm_valtype_vec_t;
typedef struct { size_t size; wasm_importtype_t **data; } wasm_importtype_vec_t;
typedef struct { uint64_t store_id; void *__private; } wasmtime_func_t;
typedef struct { struct { uint64_t store_id; uint32_t __private1; }; uint32_t __private2; } wasmtime_memory_t;
typedef struct { uint64_t store_id; size_t __private; } wasmtime_instance_t;
typedef struct {
    uint8_t kind;
    union {
        wasmtime_func_t func;
        wasmtime_memory_t memory;
        struct { uint64_t store_id; uint32_t __private1, __private2, __private3; } global;
        void *sharedmemory;
    } of;
} wasmtime_extern_t;
typedef struct {
    uint8_t kind;
    union {
        int32_t i32;
        int64_t i64;
        float f32;
        double f64;
        struct { uint64_t store_id; uint32_t __private1, __private2; void *__private3; } anyref;
        wasmtime_func_t funcref;
        uint8_t v128[16];
    } of;
} wasmtime_val_t;
typedef wasm_trap_t *(*wasmtime_func_callback_t)(void *env, wasmtime_caller_t *caller,
    const wasmtime_val_t *args, size_t nargs, wasmtime_val_t *results, size_t nresults);

wasm_config_t *wasm_config_new(void);
void wasmtime_config_wasm_simd_set(wasm_config_t *config, bool enable);
wasm_engine_t *wasm_engine_new_with_config(wasm_config_t *config);
void wasm_engine_delete(wasm_engine_t *engine);
wasmtime_store_t *wasmtime_store_new(wasm_engine_t *engine, void *data, void (*finalizer)(void *));
wasmtime_context_t *wasmtime_store_context(wasmtime_store_t *store);
void wasmtime_store_delete(wasmtime_store_t *store);
wasmtime_error_t *wasmtime_module_new(wasm_engine_t *engine, const uint8_t *wasm, size_t wasm_len,
    wasmtime_module_t **ret);
void wasmtime_module_delete(wasmtime_module_t *module);
void wasmtime_module_imports(const wasmtime_module_t *module, wasm_importtype_vec_t *out);
void wasm_importtype_vec_delete(wasm_importtype_vec_t *vec);
const wasm_byte_vec_t *wasm_importtype_module(const wasm_importtype_t *import);
const wasm_byte_vec_t *wasm_importtype_name(const wasm_importtype_t *import);
const wasm_externtype_t *wasm_importtype_type(const wasm_importtype_t *import);
uint8_t wasm_externtype_kind(const wasm_externtype_t *type);
wasm_valtype_t *wasm_valtype_new(uint8_t kind);
uint8_t wasm_valtype_kind(const wasm_valtype_t *type);
void wasm_valtype_vec_new(wasm_valtype_vec_t *out, size_t size, wasm_valtype_t *const *data);
void wasm_valtype_vec_new_empty(wasm_valtype_vec_t *out);
wasm_functype_t *wasm_functype_new(wasm_valtype_vec_t *params, wasm_valtype_vec_t *results);
const wasm_valtype_vec_t *wasm_functype_params(const wasm_functype_t *type);
const wasm_valtype_vec_t *wasm_functype_results(const wasm_functype_t *type);
void wasm_functype_delete(wasm_functype_t *type);
wasmtime_linker_t *wasmtime_linker_new(wasm_engine_t *engine);
void wasmtime_linker_delete(wasmtime_linker_t *linker);
wasmtime_error_t *wasmtime_linker_define_func(wasmtime_linker_t *linker, const char *module,
    size_t module_len, const char *name, size_t name_len, const wasm_functype_t *type,
    wasmtime_func_callback_t callback, void *data, void (*finalizer)(void *));
wasmtime_error_t *wasmtime_linker_instantiate(const wasmtime_linker_t *linker, wasmtime_context_t *store,
    const wasmtime_module_t *module, wasmtime_instance_t *instance, wasm_trap_t **trap);
bool wasmtime_instance_export_get(wasmtime_context_t *store, const wasmtime_instance_t *instance,
    const char *name, size_t name_len, wasmtime_extern_t *item);
wasm_functype_t *wasmtime_func_type(const wasmtime_context_t *store, const wasmtime_func_t *func);
wasmtime_error_t *wasmtime_func_call(wasmtime_context_t *store, const wasmtime_func_t *func,
    const wasmtime_val_t *args, size_t nargs, wasmtime_val_t *results, size_t nresults, wasm_trap_t **trap);
uint8_t *wasmtime_memory_data(wasmtime_context_t *store, const wasmtime_memory_t *memory);
size_t wasmtime_memory_data_size(const wasmtime_context_t *store, const wasmtime_memory_t *memory);
void wasmtime_error_message(const wasmtime_error_t *error, wasm_byte_vec_t *message);
void wasmtime_error_delete(wasmtime_error_t *error);
wasm_trap_t *wasmtime_trap_new(const char *message, size_t message_len);
void wasm_trap_message(const wasm_trap_t *trap, wasm_byte_vec_t *message);
void wasm_trap_delete(wasm_trap_t *trap);
void wasm_byte_vec_delete(wasm_byte_vec_t *vec);
]]

local I32 = 0
local EXTERN_FUNC = 0
local EXTERN_MEMORY = 3
local KIND_NAMES = {[0] = "i32", "i64", "f32", "f64", "v128"}

local Host = {}
Host.__index = Host

local function fail(message)
    error(message, 0)
end

-- The rendered message of a Wasmtime error or trap, which is consumed.
local function consume(api, problem, trap)
    local text = ffi.new("wasm_byte_vec_t")
    if problem ~= nil then
        api.wasmtime_error_message(problem, text)
        api.wasmtime_error_delete(problem)
    else
        api.wasm_trap_message(trap, text)
        api.wasm_trap_delete(trap)
    end
    local message = ffi.string(text.data, text.size):gsub("%z+$", "")
    api.wasm_byte_vec_delete(text)

    return message
end

local function name(vector)
    return ffi.string(vector.data, vector.size)
end

local function scalarBytes(param)
    if param.sourceType == "uint8" or param.sourceType == "int8" then
        return 1
    elseif param.sourceType == "uint16" or param.sourceType == "int16" then
        return 2
    end

    return ({bool = 1, f32 = 4, i32 = 4, u32 = 4, f64 = 8, i64 = 8, u64 = 8})[param.type]
end

-- What serde used to refuse: a manifest field of the wrong JSON kind.
local function expect(value, kind, label, optional)
    if value == nil and optional then
        return nil
    end
    if kind == "array" then
        if type(value) ~= "table" then
            fail("invalid units manifest: " .. label .. " must be an array")
        end
    elseif kind == "integer" then
        if type(value) ~= "number" or value % 1 ~= 0 or value < 0 then
            fail("invalid units manifest: " .. label .. " must be a non-negative integer")
        end
    elseif type(value) ~= kind then
        fail("invalid units manifest: " .. label .. " must be a " .. kind)
    end

    return value
end

local function signatureText(params, results)
    return "(" .. table.concat(params, ", ") .. ") -> (" .. table.concat(results, ", ") .. ")"
end

-- A Wasm call through the C API. A Lua callback may run inside it, and LuaJIT
-- refuses a callback re-entered from a compiled trace, so this never compiles.
local function invoke(host, func, args, results)
    local api = host.api
    local values = host.arguments
    for index, value in ipairs(args) do
        values[index - 1].kind = I32
        values[index - 1].of.i32 = value
    end
    local trap = host.trap
    trap[0] = nil
    local problem = api.wasmtime_func_call(host.context, func, values, #args, host.results, results, trap)
    if problem ~= nil or trap[0] ~= nil then
        return nil, consume(api, problem, trap[0])
    end

    return results > 0 and host.results[0].of.i32 or true
end
jit.off(invoke)

local function export(host, instance, label)
    local item = ffi.new("wasmtime_extern_t")
    if not host.api.wasmtime_instance_export_get(host.context, instance, label, #label, item) then
        return nil
    end

    return item
end

-- The function export `label`, held to an all-i32 signature the way a typed
-- function was in the Rust host.
local function typed(host, instance, label, params, results)
    local item = export(host, instance, label)
    if item == nil or item.kind ~= EXTERN_FUNC then
        return nil, "failed to find function export `" .. label .. "`"
    end
    local func = ffi.new("wasmtime_func_t", item.of.func)
    local api = host.api
    local signature = api.wasmtime_func_type(host.context, func)
    local function kinds(vector)
        local list = {}
        for index = 0, tonumber(vector.size) - 1 do
            local kind = api.wasm_valtype_kind(vector.data[index])
            list[#list + 1] = KIND_NAMES[kind] or tostring(kind)
        end

        return list
    end
    local actual = signatureText(kinds(api.wasm_functype_params(signature)), kinds(api.wasm_functype_results(signature)))
    api.wasm_functype_delete(signature)
    local expected = signatureText(params, results)
    if actual ~= expected then
        return nil, "type mismatch: expected " .. expected .. ", found " .. actual
    end

    return func
end

local function i32Type(api)
    local params, results = ffi.new("wasm_valtype_vec_t"), ffi.new("wasm_valtype_vec_t")
    local list = ffi.new("wasm_valtype_t *[1]", api.wasm_valtype_new(I32))
    api.wasm_valtype_vec_new(params, 1, list)
    api.wasm_valtype_vec_new_empty(results)

    return api.wasm_functype_new(params, results)
end

local function readFile(path)
    local handle, problem = fileOpen(path, "rb")
    if not handle then
        return nil, problem
    end
    local value = handle:read("*a")
    handle:close()

    return value
end

local function memoryAccess(host, unit, offset, bytes)
    local size = tonumber(host.api.wasmtime_memory_data_size(host.context, unit.memory))
    if offset < 0 or offset + bytes > size then
        return nil
    end

    return host.api.wasmtime_memory_data(host.context, unit.memory) + offset
end

local function memoryWrite(host, unit, offset, source, bytes, label)
    local target = memoryAccess(host, unit, offset, bytes) or fail(label .. ": out of bounds memory access")
    ffi.copy(target, source, bytes)
end

local function memoryRead(host, unit, offset, target, bytes, label)
    local source = memoryAccess(host, unit, offset, bytes) or fail(label .. ": out of bounds memory access")
    ffi.copy(target, source, bytes)
end

local function allocate(host, unit, bytes)
    local requested = math.max(bytes, 1)
    if requested > 0x7fffffff then
        fail("allocation exceeds Wasm32")
    end
    local pointer, problem = invoke(host, unit.malloc, {requested}, 1)
    if pointer == nil then
        fail("Wasm malloc failed: " .. problem)
    end
    if pointer <= 0 then
        fail("Wasm malloc returned a null pointer")
    end
    if pointer + bytes > tonumber(host.api.wasmtime_memory_data_size(host.context, unit.memory)) then
        fail("Wasm allocation exceeds independent memory")
    end

    return pointer
end

local function loadUnit(host, record, moduleRoot, unitName)
    local api = host.api
    local bridge = record.bridge
    if record.tier ~= "simd128" or bridge.abi ~= 1 or host.units[unitName] then
        fail("invalid independent Wasm unit " .. unitName)
    end
    local path = moduleRoot .. "/" .. record.wasm
    local bytes, readProblem = readFile(path)
    if bytes == nil then
        fail("cannot compile " .. path .. ": " .. tostring(readProblem))
    end
    local module = ffi.new("wasmtime_module_t *[1]")
    local problem = api.wasmtime_module_new(host.engine, bytes, #bytes, module)
    if problem ~= nil then
        fail("cannot compile " .. path .. ": " .. consume(api, problem, nil))
    end
    host.modules[#host.modules + 1] = module[0]

    local imports = ffi.new("wasm_importtype_vec_t")
    api.wasmtime_module_imports(module[0], imports)
    local unexpected
    for index = 0, tonumber(imports.size) - 1 do
        local import = imports.data[index]
        local moduleName = name(api.wasm_importtype_module(import))
        local importName = name(api.wasm_importtype_name(import))
        local allowed = (moduleName == "env" and importName == "emscripten_notify_memory_growth")
            or (moduleName == "wasi_snapshot_preview1" and importName == "proc_exit")
        if not allowed or api.wasm_externtype_kind(api.wasm_importtype_type(import)) ~= EXTERN_FUNC then
            unexpected = unexpected or (moduleName .. "." .. importName)
        end
    end
    api.wasm_importtype_vec_delete(imports)
    if unexpected then
        fail("unexpected independent Wasm import " .. unexpected)
    end

    local instance = ffi.new("wasmtime_instance_t")
    local trap = ffi.new("wasm_trap_t *[1]")
    problem = api.wasmtime_linker_instantiate(host.linker, host.context, module[0], instance, trap)
    if problem ~= nil or trap[0] ~= nil then
        fail("cannot instantiate " .. path .. ": " .. consume(api, problem, trap[0]))
    end
    local initialize = export(host, instance, "_initialize")
    if initialize and initialize.kind == EXTERN_FUNC then
        local func = assert(typed(host, instance, "_initialize", {}, {}))
        local ok, failure = invoke(host, func, {}, 0)
        if not ok then
            fail("Wasm initialization failed: " .. failure)
        end
    end
    local memory = export(host, instance, "memory")
    if memory == nil or memory.kind ~= EXTERN_MEMORY then
        fail("independent Wasm unit " .. unitName .. " exports no memory")
    end
    local unit = {memory = ffi.new("wasmtime_memory_t", memory.of.memory), entries = {}}
    local exportProblem
    unit.malloc, exportProblem = typed(host, instance, "malloc", {"i32"}, {"i32"})
    if not unit.malloc then
        fail("independent Wasm unit " .. unitName .. " exports no malloc: " .. exportProblem)
    end
    unit.free, exportProblem = typed(host, instance, "free", {"i32"}, {})
    if not unit.free then
        fail("independent Wasm unit " .. unitName .. " exports no free: " .. exportProblem)
    end

    local function constant(label, missing, unreadable)
        local func, typeProblem = typed(host, instance, label, {}, {"i32"})
        if not func then
            fail(missing .. ": " .. typeProblem)
        end
        local value, callProblem = invoke(host, func, {}, 1)
        if value == nil then
            fail(unreadable .. ": " .. callProblem)
        end

        return value
    end

    for entryIndex, entry in ipairs(expect(bridge.entries, "array", "bridge.entries")) do
        local label = "bridge.entries[" .. entryIndex .. "]"
        expect(entry.symbol, "string", label .. ".symbol")
        expect(entry.call, "string", label .. ".call")
        expect(entry.independentCounts, "boolean", label .. ".independentCounts")
        expect(entry.results, "array", label .. ".results")
        for paramIndex, param in ipairs(expect(entry.params, "array", label .. ".params")) do
            expect(param.kind, "string", label .. ".params[" .. paramIndex .. "].kind")
            expect(param.type, "string", label .. ".params[" .. paramIndex .. "].type")
            expect(param.sourceType, "string", label .. ".params[" .. paramIndex .. "].sourceType", true)
        end
        local layouts = {}
        for _, layout in ipairs(expect(entry.layouts, "array", label .. ".layouts")) do
            expect(layout.name, "string", label .. ".layouts.name")
            expect(layout.prefix, "string", label .. ".layouts.prefix")
            local size = constant(
                layout.prefix .. "_size",
                "missing layout size for " .. layout.name,
                "cannot read layout size for " .. layout.name
            )
            if size < 0 then
                fail("invalid layout size for " .. layout.name)
            end
            local fields = {}
            for _, field in ipairs(expect(layout.fields, "array", label .. ".layouts.fields")) do
                expect(field, "string", label .. ".layouts.fields[]")
                local qualified = layout.name .. "." .. field
                local offset = constant(
                    layout.prefix .. "_offset_" .. field,
                    "missing layout field " .. qualified,
                    "cannot read layout field " .. qualified
                )
                local fieldBytes = constant(
                    layout.prefix .. "_size_" .. field,
                    "missing layout field size " .. qualified,
                    "cannot read layout field size " .. qualified
                )
                if offset < 0 then
                    fail("invalid layout field offset " .. qualified)
                elseif fieldBytes < 0 then
                    fail("invalid layout field size " .. qualified)
                elseif offset + fieldBytes > size or fields[field] then
                    fail("invalid layout field " .. qualified)
                end
                fields[field] = {offset = offset, bytes = fieldBytes}
            end
            if layouts[layout.name] then
                fail("duplicate layout " .. layout.name)
            end
            layouts[layout.name] = {size = size, fields = fields}
        end
        local call, callProblem = typed(host, instance, entry.call, {"i32", "i32"}, {})
        if not call then
            fail("missing bridge " .. entry.call .. ": " .. callProblem)
        end
        if unit.entries[entry.symbol] then
            fail("duplicate Wasm symbol in " .. unitName)
        end
        unit.entries[entry.symbol] = {record = entry, call = call, layouts = layouts}
    end
    host.units[unitName] = unit
end

local function open(host, manifestPath, moduleRoot, decode)
    local api = host.api
    local document, readProblem = readFile(manifestPath)
    if document == nil then
        fail("cannot read " .. manifestPath .. ": " .. tostring(readProblem))
    end
    local decoded, manifest = pcall(decode, document)
    if not decoded then
        fail("invalid units manifest: " .. tostring(manifest))
    end
    expect(manifest, "table", "the document")
    if manifest.schemaVersion ~= 3 or manifest.target ~= "wasm32-unknown-emscripten" then
        fail("Wasmtime host requires a schema-3 Emscripten Wasm manifest")
    end

    local config = api.wasm_config_new()
    api.wasmtime_config_wasm_simd_set(config, true)
    host.engine = api.wasm_engine_new_with_config(config)
    host.store = api.wasmtime_store_new(host.engine, nil, nil)
    host.context = api.wasmtime_store_context(host.store)
    host.linker = api.wasmtime_linker_new(host.engine)
    local signature = i32Type(api)
    for _, import in ipairs({
        {"env", "emscripten_notify_memory_growth", host.growth},
        {"wasi_snapshot_preview1", "proc_exit", host.exit},
    }) do
        local problem = api.wasmtime_linker_define_func(
            host.linker, import[1], #import[1], import[2], #import[2], signature, import[3], nil, nil
        )
        if problem ~= nil then
            api.wasm_functype_delete(signature)
            fail(consume(api, problem, nil))
        end
    end
    api.wasm_functype_delete(signature)

    for index, record in ipairs(expect(manifest.units, "array", "units")) do
        local label = "units[" .. index .. "]"
        local unitName = expect(record.unit, "string", label .. ".unit", true)
        local wasm = expect(record.wasm, "string", label .. ".wasm", true)
        expect(record.tier, "string", label .. ".tier", true)
        local bridge = expect(record.bridge, "table", label .. ".bridge", true)
        if unitName and wasm and bridge then
            expect(bridge.abi, "integer", label .. ".bridge.abi")
            loadUnit(host, record, moduleRoot, unitName)
        end
    end
    if next(host.units) == nil then
        fail("units manifest contains no independent Wasm kernels")
    end
end

-- Open a host over the C API library at `library`. `decode` is the JSON
-- decoder the caller already holds. Returns the host, or nil and the reason.
function M.open(library, manifestPath, moduleRoot, decode)
    local loaded, api = pcall(ffi.load, library)
    if not loaded then
        return nil, "cannot load Wasmtime C API " .. library .. ": " .. tostring(api)
    end
    local host = setmetatable({
        api = api,
        units = {},
        modules = {},
        arguments = ffi.new("wasmtime_val_t[2]"),
        results = ffi.new("wasmtime_val_t[1]"),
        trap = ffi.new("wasm_trap_t *[1]"),
    }, Host)
    host.growth = ffi.cast("wasmtime_func_callback_t", function()
        return nil
    end)
    host.exit = ffi.cast("wasmtime_func_callback_t", function(_, _, args)
        local message = ("Wasm kernel aborted (%d)"):format(args[0].of.i32)
        return api.wasmtime_trap_new(message, #message)
    end)
    local ok, problem = pcall(open, host, manifestPath, moduleRoot, decode)
    if not ok then
        host:close()
        return nil, problem
    end

    return host
end

local function transfer(host, unit, entry, arguments, argumentsLength, results, resultsLength, spans, spanParams, allocated)
    local params = entry.record.params
    local argsPointer = allocate(host, unit, argumentsLength)
    allocated[#allocated + 1] = argsPointer
    local resultPointer = allocate(host, unit, resultsLength)
    allocated[#allocated + 1] = resultPointer
    memoryWrite(host, unit, argsPointer, arguments, argumentsLength, "cannot write Wasm arguments")

    local wasmSpans, transferred = {}, 0
    for spanIndex, spanParam in ipairs(spanParams) do
        local paramIndex, param, span = spanParam.index, spanParam.param, spans[spanIndex]
        local layoutName = param.type:match("^struct:(.*)$")
        local layout = layoutName and entry.layouts[layoutName]
        if layoutName and not layout then
            fail("unknown Wasm span layout " .. param.type)
        end
        local targetStride = layout and layout.size or scalarBytes(param)
            or fail("unknown scalar span type " .. param.type)
        local countSlot = #params + (entry.record.independentCounts and spanIndex - 1 or 0)
        local count = tonumber(ffi.cast("uint32_t *", arguments + countSlot * 8)[0])
        if type(span) ~= "table"
            or span.count ~= count
            or span.count * span.stride ~= span.bytes
            or span.bytes > TRANSFER_LIMIT
            or type(span.writable) ~= "boolean"
            or span.data == nil
        then
            fail("invalid scalar span for parameter " .. paramIndex)
        end
        transferred = transferred + span.bytes
        if transferred > TRANSFER_LIMIT then
            fail("Wasm span transfer exceeds two MiB")
        end
        if count * math.max(targetStride, span.stride) > TRANSFER_LIMIT then
            fail("Wasm span exceeds the transfer budget")
        end
        local mappings = {}
        local supplied = span.fields or {}
        if layout then
            if #supplied > 256 then
                fail("invalid guest struct fields")
            end
            local byName = {}
            for _, field in ipairs(supplied) do
                if type(field.name) ~= "string" then
                    fail("guest field name is not a string")
                end
                if field.offset + field.bytes > span.stride or byName[field.name] then
                    fail("invalid guest struct field " .. field.name)
                end
                byName[field.name] = field
            end
            for fieldName, target in pairs(layout.fields) do
                local sourceField = byName[fieldName] or fail("missing guest struct field " .. fieldName)
                if sourceField.bytes ~= target.bytes then
                    fail("Wasm span field size mismatch for " .. fieldName)
                end
                mappings[#mappings + 1] = {sourceField.offset, target.offset, target.bytes}
            end
        else
            if span.stride ~= targetStride or #supplied ~= 0 then
                fail("Wasm scalar span layout mismatch")
            end
            mappings[1] = {0, 0, targetStride}
        end
        local targetBytes = count * targetStride
        local pointer = allocate(host, unit, targetBytes)
        allocated[#allocated + 1] = pointer
        local source = ffi.cast("const uint8_t *", span.data)
        local target = ffi.new("uint8_t[?]", math.max(1, targetBytes))
        for row = 0, count - 1 do
            for _, mapping in ipairs(mappings) do
                ffi.copy(target + row * targetStride + mapping[2], source + row * span.stride + mapping[1], mapping[3])
            end
        end
        memoryWrite(host, unit, pointer, target, targetBytes, "cannot write Wasm span")
        ffi.cast("uint32_t *", arguments + (paramIndex - 1) * 8)[0] = pointer
        wasmSpans[#wasmSpans + 1] = {pointer = pointer, span = span, stride = targetStride, mappings = mappings}
    end
    memoryWrite(host, unit, argsPointer, arguments, argumentsLength, "cannot write Wasm bridge arguments")
    local called, problem = invoke(host, entry.call, {argsPointer, resultPointer}, 0)
    if not called then
        fail("Wasm bridge trapped: " .. problem)
    end
    memoryRead(host, unit, resultPointer, results, resultsLength, "cannot read Wasm results")
    for _, wasmSpan in ipairs(wasmSpans) do
        local span = wasmSpan.span
        if span.writable then
            local sourceBytes = span.count * wasmSpan.stride
            local source = ffi.new("uint8_t[?]", math.max(1, sourceBytes))
            memoryRead(host, unit, wasmSpan.pointer, source, sourceBytes, "cannot read Wasm span")
            local target = ffi.cast("uint8_t *", span.data)
            for row = 0, span.count - 1 do
                for _, mapping in ipairs(wasmSpan.mappings) do
                    ffi.copy(
                        target + row * span.stride + mapping[1],
                        source + row * wasmSpan.stride + mapping[2],
                        mapping[3]
                    )
                end
            end
        end
    end
end

-- Call `unit`.`symbol` with the caller's packed argument and result slots.
-- Each span is {data, bytes, stride, count, writable, fields}, a field being
-- {name, offset, bytes} of one host struct row. Returns true, or false and the
-- reason; the guest allocations are released either way.
function Host:call(unitName, symbol, arguments, argumentsLength, results, resultsLength, spans)
    if arguments == nil or (resultsLength > 0 and results == nil) or type(spans) ~= "table" then
        return false, "invalid Wasm bridge buffers"
    end
    local unit = self.units[unitName]
    if not unit then
        return false, "unknown Wasm unit " .. tostring(unitName)
    end
    local entry = unit.entries[symbol]
    if not entry then
        return false, "unknown Wasm entry " .. unitName .. "." .. tostring(symbol)
    end
    local spanParams = {}
    for index, param in ipairs(entry.record.params) do
        if param.kind:sub(-5) == "_span" then
            spanParams[#spanParams + 1] = {index = index, param = param}
        end
    end
    local countCount = entry.record.independentCounts and #spanParams or 1
    if argumentsLength ~= (#entry.record.params + countCount) * 8
        or resultsLength ~= #entry.record.results * 8
        or #spans ~= #spanParams
    then
        return false, "bridge extent mismatch for " .. unitName .. "." .. symbol
    end

    local allocated = {}
    local ok, problem = pcall(
        transfer,
        self,
        unit,
        entry,
        ffi.cast("uint8_t *", arguments),
        argumentsLength,
        ffi.cast("uint8_t *", results),
        resultsLength,
        spans,
        spanParams,
        allocated
    )
    for index = #allocated, 1, -1 do
        local freed, freeProblem = invoke(self, unit.free, {allocated[index]}, 0)
        if not freed and ok then
            ok, problem = false, "Wasm free failed: " .. freeProblem
        end
    end

    return ok, problem
end

function Host:close()
    local api = self.api
    for _, module in ipairs(self.modules) do
        api.wasmtime_module_delete(module)
    end
    self.modules = {}
    if self.linker ~= nil then
        api.wasmtime_linker_delete(self.linker)
    end
    if self.store ~= nil then
        api.wasmtime_store_delete(self.store)
    end
    if self.engine ~= nil then
        api.wasm_engine_delete(self.engine)
    end
    self.linker, self.store, self.engine, self.context = nil, nil, nil, nil
    self.units = {}
    -- The store owned every reference to the callbacks, so they go last.
    if self.growth then
        self.growth:free()
        self.exit:free()
        self.growth, self.exit = nil, nil
    end
end

return M
