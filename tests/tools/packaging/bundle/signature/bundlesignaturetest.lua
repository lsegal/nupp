local fixture = require("helpers.bundlefixture")
local packaging = fixture.packaging
local tempProject = fixture.tempProject
local readFile = fixture.readFile

local M = {}

local function little(value, width)
    local bytes = {}
    for index = 1, width do
        bytes[index] = string.char(value % 256)
        value = math.floor(value / 256)
    end

    return table.concat(bytes)
end

--- A signed arm64 Mach-O stub: a header, a __LINKEDIT segment, and a code
--- signature load command whose blob ends the file.
local function signedMachOStub()
    local header = "\207\250\237\254" .. little(
        0x0100000c,
        4
    ) .. little(0, 4) .. little(2, 4) .. little(2, 4) .. little(88, 4) .. little(0, 4) .. little(0, 4)
    local linkedit = little(
        0x19,
        4
    ) .. little(
        72,
        4
    ) .. "__LINKEDIT" .. (
        "\0"
    ):rep(
        6
    ) .. little(
        0x1000,
        8
    ) .. little(
        0x1000,
        8
    ) .. little(120, 8) .. little(8, 8) .. little(1, 4) .. little(1, 4) .. little(0, 4) .. little(0, 4)
    local signature = little(0x1d, 4) .. little(16, 4) .. little(120, 4) .. little(8, 4)

    return header .. linkedit .. signature .. "SIGNHERE"
end

function M.machOPackagingReplacesTheStubSignatureWithASignableLayout()
    local stub = signedMachOStub()
    local dir = tempProject({})
    local output = dir .. "/app"
    assert(packaging.stampFile(output, stub, "return true\n", "aarch64-apple-darwin"))
    local bytes = assert(readFile(output))
    assert(bytes:sub(-48, -41) == "NUPPLOAD", "the unsigned trailer ends the stamped file")
    assert(bytes:sub(17, 20) == little(1, 4), "the old signature load command is removed")
    assert(bytes:sub(21, 24) == little(72, 4), "the load-command byte count is updated")
    assert(
        bytes:sub(81, 88) == little(#bytes - 120, 8),
        "__LINKEDIT covers the payload and trailer for the next signer"
    )
    os.execute("rm -rf '" .. dir .. "'")
end

local function writeBytes(path, bytes)
    local file = assert(io.open(path, "wb"))
    file:write(bytes)
    file:close()
end

-- A host that links LLVM in is about 140 MB, so the build stamps it from its
-- path a block at a time instead of reading it into a string (#310). What it
-- writes has to be what stamping the string writes, for every kind of stub:
-- a signed Mach-O whose head is rewritten and signature dropped, and a stub
-- several copy blocks long whose cross-target archive is copied the same way.
function M.stampingAStubFromItsPathWritesWhatStampingItsBytesDoes()
    -- Stamped under one name in two directories: an archive records the name.
    local dir = tempProject({["bytes/.keep"] = "", ["path/.keep"] = ""})
    local payload = "return true\n"
    local plain = {}
    for index = 1, 2600 do
        plain[index] = ("%08d"):format(index):rep(128)
    end
    local cases = {
        {name = "macho", stub = signedMachOStub(), platform = "aarch64-apple-darwin"},
        {name = "large", stub = table.concat(plain), platform = "x86_64-unknown-linux-gnu"},
    }
    for _, case in ipairs(cases) do
        local stubPath = dir .. "/" .. case.name .. "-stub"
        writeBytes(stubPath, case.stub)
        local fromBytes = dir .. "/bytes/" .. case.name
        local fromPath = dir .. "/path/" .. case.name
        local _, bytesErr, bytesArchive = packaging.stampFile(fromBytes, case.stub, payload, case.platform, 1)
        assert(bytesErr == nil, tostring(bytesErr))
        local _, pathErr, pathArchive = packaging.stampStub(fromPath, stubPath, payload, case.platform, 1)
        assert(pathErr == nil, tostring(pathErr))
        local expected = assert(readFile(fromBytes))
        assert(readFile(fromPath) == expected, case.name .. ": the stamped binary is the same either way")
        assert(expected:sub(-48, -41) == "NUPPLOAD", case.name .. ": the trailer ends the stamped file")
        assert((bytesArchive == nil) == (pathArchive == nil), case.name .. ": both archive or neither does")
        if bytesArchive then
            assert(readFile(pathArchive) == readFile(bytesArchive), case.name .. ": the archive is the same either way")
        end
    end
    os.execute("rm -rf '" .. dir .. "'")
end

return M
