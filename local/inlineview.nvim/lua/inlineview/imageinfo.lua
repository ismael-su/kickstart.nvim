--- Pixel dimensions straight out of image headers.
---
--- Done in Lua so that viewing a PNG or JPEG needs no external tooling at all;
--- `file(1)` covers the long tail of formats, and only then do we give up.
local M = {}

local byte = string.byte

local function be16(s, i) return byte(s, i) * 256 + byte(s, i + 1) end

local function be32(s, i) return byte(s, i) * 16777216 + byte(s, i + 1) * 65536 + byte(s, i + 2) * 256 + byte(s, i + 3) end

local function le16(s, i) return byte(s, i) + byte(s, i + 1) * 256 end

local function le24(s, i) return byte(s, i) + byte(s, i + 1) * 256 + byte(s, i + 2) * 65536 end

local function le32(s, i) return byte(s, i) + byte(s, i + 1) * 256 + byte(s, i + 2) * 65536 + byte(s, i + 3) * 16777216 end

--- Read at most `n` leading bytes of a file.
---@param path string
---@param n integer
---@return string|nil
local function read_head(path, n)
  local fd = vim.uv.fs_open(path, 'r', 438)
  if not fd then return nil end
  local data = vim.uv.fs_read(fd, n, 0)
  vim.uv.fs_close(fd)
  return data
end

--------------------------------------------------------------------------
-- Per-format parsers. Each returns width, height or nil.
--------------------------------------------------------------------------

local parsers = {}

--- PNG: the IHDR chunk is mandated to come first, at a fixed offset.
function parsers.png(d)
  if #d < 24 or d:sub(1, 8) ~= '\137PNG\r\n\26\n' then return nil end
  if d:sub(13, 16) ~= 'IHDR' then return nil end
  return be32(d, 17), be32(d, 21)
end

function parsers.gif(d)
  if #d < 10 then return nil end
  local sig = d:sub(1, 6)
  if sig ~= 'GIF87a' and sig ~= 'GIF89a' then return nil end
  return le16(d, 7), le16(d, 9)
end

function parsers.bmp(d)
  if #d < 26 or d:sub(1, 2) ~= 'BM' then return nil end
  local header_size = le32(d, 15)
  if header_size == 12 then -- BITMAPCOREHEADER uses 16-bit fields
    return le16(d, 19), le16(d, 21)
  end
  local w, h = le32(d, 19), le32(d, 23)
  -- Height is signed; negative means a top-down bitmap.
  if h > 0x7FFFFFFF then h = 0x100000000 - h end
  return w, h
end

function parsers.ico(d)
  if #d < 8 or le16(d, 1) ~= 0 or le16(d, 3) ~= 1 then return nil end
  local w, h = byte(d, 7), byte(d, 8)
  -- 0 is how the format spells 256.
  return w == 0 and 256 or w, h == 0 and 256 or h
end

--- JPEG: walk the marker chain to the start-of-frame segment.
function parsers.jpeg(d)
  if #d < 4 or byte(d, 1) ~= 0xFF or byte(d, 2) ~= 0xD8 then return nil end
  -- Frame markers carrying dimensions. DHT/JPG/DAC share the 0xC_ range but
  -- are not frames, hence the explicit set.
  local sof = {
    [0xC0] = true,
    [0xC1] = true,
    [0xC2] = true,
    [0xC3] = true,
    [0xC5] = true,
    [0xC6] = true,
    [0xC7] = true,
    [0xC9] = true,
    [0xCA] = true,
    [0xCB] = true,
    [0xCD] = true,
    [0xCE] = true,
    [0xCF] = true,
  }
  local i = 3
  while i + 3 <= #d do
    if byte(d, i) ~= 0xFF then
      i = i + 1 -- resynchronise on padding
    else
      local marker = byte(d, i + 1)
      if marker == 0xFF then
        i = i + 1
      elseif marker == 0xD8 or (marker >= 0xD0 and marker <= 0xD9) then
        i = i + 2 -- standalone marker, no payload
      else
        local len = be16(d, i + 2)
        if len < 2 then return nil end
        if sof[marker] then
          if i + 8 > #d then return nil end
          -- payload: precision(1) height(2) width(2)
          return be16(d, i + 7), be16(d, i + 5)
        end
        i = i + 2 + len
      end
    end
  end
  return nil
end

--- WebP has three sub-formats, each storing the size differently -- and each
--- needing a different minimum length, so the bounds are checked per branch
--- rather than up front (a valid VP8L header is only 25 bytes).
function parsers.webp(d)
  if #d < 16 or d:sub(1, 4) ~= 'RIFF' or d:sub(9, 12) ~= 'WEBP' then return nil end
  local chunk = d:sub(13, 16)

  if chunk == 'VP8X' then
    -- 4 flag bytes, then 24-bit canvas dimensions stored minus one.
    if #d < 30 then return nil end
    return le24(d, 25) + 1, le24(d, 28) + 1
  elseif chunk == 'VP8 ' then
    -- Lossy: keyframe header, 3-byte sync code, then 14-bit dimensions.
    if #d < 30 or d:sub(24, 26) ~= '\157\001\42' then return nil end
    return le16(d, 27) % 16384, le16(d, 29) % 16384
  elseif chunk == 'VP8L' then
    -- Lossless: 0x2F signature then 14 bits width-1, 14 bits height-1.
    if #d < 25 or byte(d, 21) ~= 0x2F then return nil end
    local bits = le32(d, 22)
    local w = bits % 16384
    local h = math.floor(bits / 16384) % 16384
    return w + 1, h + 1
  end
  return nil
end

--- Baseline TIFF: read the IFD and pick out tags 0x0100/0x0101.
function parsers.tiff(d)
  if #d < 8 then return nil end
  local order = d:sub(1, 2)
  local little
  if order == 'II' and le16(d, 3) == 42 then
    little = true
  elseif order == 'MM' and be16(d, 3) == 42 then
    little = false
  else
    return nil
  end
  local u16 = little and le16 or be16
  local u32 = little and le32 or be32

  local ifd = u32(d, 5) + 1 -- file offsets are 0-based
  if ifd + 2 > #d then return nil end
  local count = u16(d, ifd)
  local w, h
  for n = 0, count - 1 do
    local entry = ifd + 2 + n * 12
    if entry + 11 > #d then break end
    local tag = u16(d, entry)
    local typ = u16(d, entry + 2)
    -- Values this small are stored inline in the entry.
    local value = (typ == 3) and u16(d, entry + 9) or u32(d, entry + 9)
    if tag == 0x0100 then
      w = value
    elseif tag == 0x0101 then
      h = value
    end
    if w and h then return w, h end
  end
  return nil
end

--- AVIF/HEIF: ISOBMFF boxes. Find the `ispe` property, which holds the
--- canvas size. A linear scan is enough since `ispe` appears once up front.
function parsers.avif(d)
  if #d < 16 or d:sub(5, 8) ~= 'ftyp' then return nil end
  local at = d:find('ispe', 1, true)
  if not at then return nil end
  -- ispe: 4-byte type, 1 version + 3 flags, then width/height as 32-bit BE.
  local off = at + 8
  if off + 7 > #d then return nil end
  return be32(d, off), be32(d, off + 4)
end

--------------------------------------------------------------------------

--- Sniff the format from magic bytes rather than trusting the extension.
---@param d string
---@return string|nil
local function sniff(d)
  if #d < 12 then return nil end
  if d:sub(1, 8) == '\137PNG\r\n\26\n' then return 'png' end
  if byte(d, 1) == 0xFF and byte(d, 2) == 0xD8 then return 'jpeg' end
  if d:sub(1, 3) == 'GIF' then return 'gif' end
  if d:sub(1, 2) == 'BM' then return 'bmp' end
  if d:sub(1, 4) == 'RIFF' and d:sub(9, 12) == 'WEBP' then return 'webp' end
  if d:sub(1, 2) == 'II' or d:sub(1, 2) == 'MM' then return 'tiff' end
  if d:sub(5, 8) == 'ftyp' then return 'avif' end
  if le16(d, 1) == 0 and le16(d, 3) == 1 then return 'ico' end
  return nil
end

--- Last resort for formats we do not parse: `file -b` prints dimensions for
--- most things it recognises.
---@param path string
---@return integer|nil, integer|nil
local function probe_external(path)
  if vim.fn.executable 'file' ~= 1 then return nil end
  local res = vim.system({ 'file', '-bL', path }, { text = true }):wait(2000)
  if res.code ~= 0 or not res.stdout then return nil end
  local out = res.stdout
  local w, h = out:match 'width=(%d+),%s*height=(%d+)'
  if not w then
    w, h = out:match '(%d+)%s*x%s*(%d+)'
  end
  if w and h then return tonumber(w), tonumber(h) end
  return nil
end

--- Pixel dimensions of an image file.
---@param path string
---@return {width: integer, height: integer, format: string}|nil info, string|nil err
function M.probe(path)
  local head = read_head(path, 512 * 1024)
  if not head or #head == 0 then return nil, 'cannot read ' .. path end

  local format = sniff(head)
  if format and parsers[format] then
    local w, h = parsers[format](head)
    if w and h and w > 0 and h > 0 then return { width = w, height = h, format = format } end
  end

  local w, h = probe_external(path)
  if w and h and w > 0 and h > 0 then return { width = w, height = h, format = format or 'unknown' } end

  return nil, ('unsupported or corrupt image: %s'):format(vim.fn.fnamemodify(path, ':t'))
end

-- Exposed for the test suite.
M._parsers = parsers
M._sniff = sniff

return M
