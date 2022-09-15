--->use-luvit<---

--- Buffer v2

local bit = require 'bit'
local ffi = require 'ffi'

ffi.cdef [[
    void* malloc(size_t size);
    void free(void* mem);
    void* memset(void* ptr, int val, size_t n);
]]
local C = (ffi.os == 'Windows') and ffi.load('msvcrt') or ffi.C


---@alias endianness
---|>'"le"' # Little-endian
---| '"be"' # Big-endian

--- Byte buffer for sequential and 0-indexed reading/writing.
---@class ByteBuffer
---@field length number # Buffer length
---@field pos number    # Position to read next
---@field mode endianness # Endianness of buffer reads/writes
---@field rw boolean    # Is the buffer also writable
---@field pos_stack number[] # Position stack for push and pop operations
---@field ct ffi.cdata* # Cdata pointer to buffer memory
---@field _ct ffi.cdata* private
---@field _funcs table private
local ByteBuffer = {}

---@class ByteBuffer
local LEfn = {}

---@class ByteBuffer
local BEfn = {}


---@param self ByteBuffer
local function ByteBuffer__index(self, key)
    if type(key) == 'number' then
        assert(key >= 0 and key < self.length, "Index out of bounds")
        return self.ct[key]
    end
    return self._funcs[key] or ByteBuffer[key]
end


--- Create a new, empty buffer with size `length`.
---@return ByteBuffer
function ByteBuffer.new(length, options)
    assert(type(length) == 'number' and length >= 0, "length must be a positive integer.")
    options = options or {}

    ---@type ByteBuffer
    local self = setmetatable({}, {__index = ByteBuffer__index})
    self.mode = options.mode == 'be' and 'be' or 'le'
    self.rw = options.rw and true or false
    self.length = length
    self.pos = 0
    self.pos_stack = {}
    self._funcs = (self.mode == 'be') and BEfn or LEfn

    -- Keepalive field with type cdata<void *>, since ffi.cast
    -- doesn't keep source cdata (and gets garbage collected).
    -- Used for later realloc too, to detach the finalizer.
    -- TODO check if you could just cdef an alias with a different
    -- return type `uint8_t *`, to eliminate redundant cdata storage.
    self._ct = ffi.gc(C.malloc(self.length), C.free)

    -- the cdata of type cdata<uint8_t *> that gets actually used.
    self.ct = ffi.cast('uint8_t *', self._ct)

    if options.zerofill then
        ffi.fill(self.ct, self.length)
    end

    return self
end

function ByteBuffer.from(s, options)
    assert(type(s) == 'string', "s must be a string source.")
    local self = ByteBuffer.new(#s, options)

    ffi.copy(self.ct, s, self.length)

    return self
end


--- Other ---

function ByteBuffer:checkWrite()
    assert(self.rw, "Buffer is read-only, write operaions not supported.")
end



--- Position functions ---

--- Advance pos by `n`, returning current position before advance
function ByteBuffer:advance(n)
    local current = self.pos
    assert(current + n <= self.length, "Reached end of buffer.")
    self.pos = current + n
    return current
end

function ByteBuffer:push()
    table.insert(self.pos_stack, self.pos)
    return self
end

function ByteBuffer:pop()
    ---@type number
    self.pos = assert(table.remove(self.pos_stack), "Nothing to pop from position stack.")
    return self
end

---@param pos number
function ByteBuffer:seek(pos)
    assert(type(pos) == 'number', "pos must be a number.")
    if pos < 0 then
        pos = self.length + pos
    end
    self.pos = pos
    return self
end


--- Read functions ---

local function complement8(n)
    return (n < 0x80) and n or (n - 0x100)
end

local function complement16(n)
    return (n < 0x8000) and n or (n - 0x10000)
end

local function complement32(n)
    return bit.band(n, 0x80000000) == 0 and (n)
        or (n - 0xffffffff - 1)
end

--

function LEfn:read_u8()
    local cur = self:advance(1)

    return self.ct[cur]
end
BEfn.read_u8 = LEfn.read_u8

function LEfn:read_i8()
    return complement8(self:read_u8())
end
BEfn.read_i8 = LEfn.read_i8

--

function LEfn:read_u16()
    local cur = self:advance(2)

    return self.ct[cur] +
        bit.lshift(self.ct[cur + 1], 8)
end
function BEfn:read_u16()
    local cur = self:advance(2)

    return bit.lshift(self.ct[cur], 8) +
        self.ct[cur + 1]
end

function LEfn:read_i16()
    return complement16(self:read_u16())
end
BEfn.read_i16 = LEfn.read_i16

--

function LEfn:read_u32()
    local cur = self:advance(4)

    return self.ct[cur] +
        bit.lshift(self.ct[cur + 1], 8) +
        bit.lshift(self.ct[cur + 2], 16) +
        0x1000000* self.ct[cur + 3]         -- lshift(x, 24)
end
function BEfn:read_u32()
    local cur = self:advance(4)

    return 0x1000000 * self.ct[cur] +       -- lshift(x, 24)
        bit.lshift(self.ct[cur + 1], 16) +
        bit.lshift(self.ct[cur + 2], 8) +
        self.ct[cur + 3]
end

function LEfn:read_i32()
    return complement32(self:read_u32())
end
BEfn.read_i32 = LEfn.read_i32

--

function ByteBuffer:read_bytes(len)
    assert(type(len) == 'number' and len >= 0, "len must be a positive integer.")
    local cur = self:advance(len)

    return ffi.string(self.ct + cur, len)
end


--- Write functions ---

function LEfn:write_u8(val)
    self:checkWrite()
    local cur = self:advance(1)

    self.ct[cur] = val
    return self
end
BEfn.write_u8 = LEfn.write_u8
LEfn.write_i8 = LEfn.write_u8
BEfn.write_i8 = LEfn.write_u8

--

function LEfn:write_u16(val)
    self:checkWrite()
    local cur = self:advance(2)

    self.ct[cur + 0] = val
    self.ct[cur + 1] = bit.rshift(val, 8)
    return self
end
LEfn.write_i16 = LEfn.write_u16

function BEfn:write_u16(val)
    self:checkWrite()
    local cur = self:advance(2)

    self.ct[cur + 0] = bit.rshift(val, 8)
    self.ct[cur + 1] = val
    return self
end
BEfn.write_i16 = BEfn.write_u16

--

function LEfn:write_u32(val)
    self:checkWrite()
    local cur = self:advance(4)

    self.ct[cur + 0] = bit.band(val, 0xff)
    self.ct[cur + 1] = bit.rshift(val, 8)
    self.ct[cur + 2] = bit.rshift(val, 16)
    self.ct[cur + 3] = bit.rshift(val, 24)
    return self
end
LEfn.write_i32 = LEfn.write_u32

function BEfn:write_u32(val)
    self:checkWrite()
    local cur = self:advance(4)

    self.ct[cur + 0] = bit.rshift(val, 24)
    self.ct[cur + 1] = bit.rshift(val, 16)
    self.ct[cur + 2] = bit.rshift(val, 8)
    self.ct[cur + 3] = bit.band(val, 0xff)
    return self
end
BEfn.write_i32 = BEfn.write_u32

--

function ByteBuffer:write_bytes(val)
    self:checkWrite()
    local cur = self:advance(#val)

    ffi.copy(self.ct + cur, val)
    return self
end


return ByteBuffer