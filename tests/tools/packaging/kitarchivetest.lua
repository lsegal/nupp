-- Link kit archives: verified against their catalog record, then unpacked by
-- the compiler's own tar reader.

local fileops = require("nupp.runtime.standardos")
local fs = require("nupp.compiler.fs")
local kitarchive = require("nupp.tools.build.kitarchive")

local M = {}

local function pad(text, width)
    return text .. ("\0"):rep(width - #text)
end

-- A ustar header for `name`, of tar type `kind`, with `size` bytes of data.
local function header(name, kind, size)
    local fields = {
        pad(name, 100),
        pad("0000644", 8),
        pad("", 16),
        pad(("%011o"):format(size), 12),
        pad("", 12),
        "        ",
        kind,
        pad("", 100),
        pad("ustar", 6),
        "00",
    }
    local block = pad(table.concat(fields), 512)
    local sum = 0
    for position = 1, #block do
        sum = sum + block:byte(position)
    end

    return block:sub(1, 148) .. ("%06o\0 "):format(sum) .. block:sub(157)
end

local function tar(members)
    local blocks = {}
    for _, member in ipairs(members) do
        local name, kind, data = member[1], member[2], member[3]
        blocks[#blocks + 1] = header(name, kind, #data)
        blocks[#blocks + 1] = data .. ("\0"):rep((512 - #data % 512) % 512)
    end
    blocks[#blocks + 1] = ("\0"):rep(1024)

    return table.concat(blocks)
end

local function crc32(text)
    local crc = 0xffffffff
    for position = 1, #text do
        crc = bit.bxor(crc, text:byte(position))
        for _ = 1, 8 do
            crc = bit.band(crc, 1) ~= 0 and bit.bxor(bit.rshift(crc, 1), 0xedb88320) or bit.rshift(crc, 1)
        end
    end

    return bit.bnot(crc)
end

local function le32(value)
    return string.char(
        bit.band(value, 0xff),
        bit.band(bit.rshift(value, 8), 0xff),
        bit.band(bit.rshift(value, 16), 0xff),
        bit.band(bit.rshift(value, 24), 0xff)
    )
end

-- `text` as a gzip member of stored DEFLATE blocks: what any inflater reads,
-- built here so the fixtures need no compressor.
local function gzip(text)
    local parts = {"\31\139\8\0\0\0\0\0\0\255"}
    local at = 1
    repeat
        local chunk = text:sub(at, at + 65534)
        at = at + #chunk
        local final = at > #text and 1 or 0
        parts[
            #parts + 1
        ] = string.char(
            final,
            #chunk % 256,
            math.floor(#chunk / 256)
        ) .. string.char(255 - #chunk % 256, 255 - math.floor(#chunk / 256)) .. chunk
    until at > #text
    parts[#parts + 1] = le32(crc32(text)) .. le32(#text)

    return table.concat(parts)
end

local function archive(members)
    return gzip(tar(members))
end

local function scratch(name)
    local root = os.tmpname()
    os.remove(root)
    root = root .. "-kit-" .. name
    assert(fs.mkdir(root), "cannot create " .. root)

    return root
end

local function read(path)
    return assert(fs.readFile(path))
end

function M.unpacksFilesAndDirectories()
    local dir = scratch("unpack")
    local bytes = archive({
        {"sdk/", "5", ""},
        {"sdk/usr/lib/libSystem.tbd", "0", "stub"},
        {"kit.json", "0", "{}"},
        {"./nested/./plain", "\0", ("x"):rep(700)},
    })
    assert(kitarchive.unpack(bytes, dir) == nil)
    assert(read(fs.join(dir, "sdk/usr/lib/libSystem.tbd")) == "stub")
    assert(read(fs.join(dir, "kit.json")) == "{}")
    assert(read(fs.join(dir, "nested/plain")) == ("x"):rep(700))
    fileops.remove(dir, true)
end

function M.refusesPathsOutsideTheKit()
    local dir = scratch("escape")
    for _, name in ipairs({"../escaped", "sdk/../../escaped", "/absolute", "C:/drive", "a\\..\\..\\b"}) do
        local err = kitarchive.unpack(archive({{name, "0", "x"}}), dir)
        assert(err == "the kit archive names a path outside itself: " .. name, tostring(err))
    end
    fileops.remove(dir, true)
end

function M.refusesLinks()
    local dir = scratch("link")
    for _, kind in ipairs({"1", "2", "3", "6"}) do
        local err = kitarchive.unpack(archive({{"runtime", kind, ""}}), dir)
        assert(tostring(err):find("never carries", 1, true), tostring(err))
        assert(tostring(err):find("of tar type '" .. kind .. "'", 1, true), tostring(err))
    end
    assert(not fs.exists(fs.join(dir, "runtime")))
    fileops.remove(dir, true)
end

function M.verifiesSizeAndDigest()
    local empty = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    assert(kitarchive.verify("", 0, empty) == nil)
    assert(tostring(kitarchive.verify("x", 0, empty)):find("1 bytes; its catalog record says 0", 1, true))
    assert(tostring(kitarchive.verify("", 0, ("0"):rep(64))):find("SHA-256 is " .. empty, 1, true))
end

function M.followsPaxPaths()
    local dir = scratch("pax")
    local record = "29 path=a/very/long/name.tbd\n"
    local bytes = archive({{"PaxHeader", "x", record}, {"ignored", "0", "body"}, {"after", "0", "next"}})
    assert(kitarchive.unpack(bytes, dir) == nil)
    assert(read(fs.join(dir, "a/very/long/name.tbd")) == "body")
    assert(read(fs.join(dir, "after")) == "next")
    assert(not fs.exists(fs.join(dir, "ignored")))
    fileops.remove(dir, true)
end

function M.followsGnuLongNamesAndUstarPrefixes()
    local dir = scratch("long")
    local prefixed = header("file.txt", "0", 3)
    prefixed = prefixed:sub(1, 345) .. pad("deep/prefix", 155) .. prefixed:sub(501)
    local sum = 0
    local blank = prefixed:sub(1, 148) .. "        " .. prefixed:sub(157)
    for position = 1, #blank do
        sum = sum + blank:byte(position)
    end
    prefixed = prefixed:sub(1, 148) .. ("%06o\0 "):format(sum) .. prefixed:sub(157)
    local body = tar({{"././@LongLink", "L", "gnu/long/name\0"}, {"short", "0", "gnu"}})
    body = body:sub(1, -1025) .. prefixed .. pad("abc", 512) .. ("\0"):rep(1024)
    local bytes = gzip(body)
    assert(kitarchive.unpack(bytes, dir) == nil)
    assert(read(fs.join(dir, "gnu/long/name")) == "gnu")
    assert(read(fs.join(dir, "deep/prefix/file.txt")) == "abc")
    fileops.remove(dir, true)
end

function M.refusesBrokenArchives()
    local dir = scratch("broken")
    assert(tostring(kitarchive.unpack("not gzip", dir)):find("^the kit archive is not gzip"))

    local whole = tar({{"kit.json", "0", "{}"}})
    local unclosed = gzip(whole:sub(1, 1024))
    assert(kitarchive.unpack(unclosed, dir) == "the kit archive ends without its closing blocks")
    local truncated = gzip(header("kit.json", "0", 4096))
    assert(kitarchive.unpack(truncated, dir) == "the kit archive is truncated")
    local badSize = header("kit.json", "0", 0):sub(1, 124) .. pad("9z", 12) .. header("kit.json", "0", 0):sub(137)
    local err = kitarchive.unpack(gzip(badSize .. ("\0"):rep(1024)), dir)
    assert(err == 'a tar header number is not octal: "9z"', tostring(err))
    fileops.remove(dir, true)
end

function M.unpackFileVerifiesBeforeUnpacking()
    local dir = scratch("file")
    local bytes = archive({{"kit.json", "0", "{}"}})
    local path = fs.join(dir, "kit.tar.gz")
    assert(fs.writeFile(path, bytes))
    local root = fs.join(dir, "root")
    assert(fs.mkdir(root))
    local digest = require("nupp.compiler.hash").sha256(bytes)
    local err = kitarchive.unpackFile(path, ("0"):rep(64), #bytes, root)
    assert(tostring(err):find("SHA-256", 1, true), tostring(err))
    assert(not fs.exists(fs.join(root, "kit.json")))
    assert(kitarchive.unpackFile(path, digest, #bytes, root) == nil)
    assert(read(fs.join(root, "kit.json")) == "{}")
    assert(tostring(kitarchive.unpackFile(fs.join(dir, "missing"), digest, 1, root)):find("^cannot read "))
    fileops.remove(dir, true)
end

return M
