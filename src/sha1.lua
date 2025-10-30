-- Minimal pure-Lua SHA-1 implementation (returns hex string)
-- Module returns a single function: sha1(data :: string) -> string (40-char hex)

local bit = bit or require('bit')
local bnot = bit.bnot
local lshift, rshift = bit.lshift, bit.rshift

local function rol(x, n)
  return band(bor(lshift(x, n), rshift(x, 32 - n)), 0xffffffff)
end

local function to_hex(n)
  return string.format("%08x", n)
end

local function bytes_to_u32_be(b, i)
  local a1 = string.byte(b, i) or 0
  local a2 = string.byte(b, i+1) or 0
  local a3 = string.byte(b, i+2) or 0
  local a4 = string.byte(b, i+3) or 0
  return bor(lshift(a1, 24), lshift(a2, 16), lshift(a3, 8), a4)
end

local function u64_len_bits(len)
  -- return high, low 32-bit parts for big-endian 64-bit length
  local hi = math.floor(len / 0x20000000) -- len >> 29
  local lo = band(len * 8, 0xffffffff)
  return hi, lo
end

local function sha1(msg)
  assert(type(msg) == 'string', 'sha1 expects string')
  local h0, h1, h2, h3, h4 = 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0

  local ml = #msg
  -- pre-processing: padding
  local rem = (ml + 1) % 64
  local pad_len = (rem <= 56) and (56 - rem) or (56 + 64 - rem)
  local padding = string.char(0x80) .. string.rep("\0", pad_len)
  local hi, lo = u64_len_bits(ml)
  local len_be = string.char(
    band(rshift(hi,24),0xff), band(rshift(hi,16),0xff), band(rshift(hi,8),0xff), band(hi,0xff),
    band(rshift(lo,24),0xff), band(rshift(lo,16),0xff), band(rshift(lo,8),0xff), band(lo,0xff)
  )
  local chunked = msg .. padding .. len_be

  local w = {}
  for i = 1, #chunked, 64 do
    -- break chunk into sixteen 32-bit big-endian words w[0..15]
    for t = 0, 15 do
      w[t] = bytes_to_u32_be(chunked, i + t*4)
    end
    for t = 16, 79 do
      w[t] = rol(bxor(w[t-3], w[t-8], w[t-14], w[t-16]), 1)
    end

    local a, b, c, d, e = h0, h1, h2, h3, h4

    for t = 0, 79 do
      local f, k
      if t < 20 then
        f = bor(band(b, c), band(bnot(b), d))
        k = 0x5A827999
      elseif t < 40 then
        f = bxor(b, c, d)
        k = 0x6ED9EBA1
      elseif t < 60 then
        f = bor(band(b, c), band(b, d), band(c, d))
        k = 0x8F1BBCDC
      else
        f = bxor(b, c, d)
        k = 0xCA62C1D6
      end
      local temp = band((rol(a,5) + f + e + k + w[t]) % 0x100000000, 0xffffffff)
      e = d
      d = c
      c = rol(b, 30)
      b = a
      a = temp
    end

    h0 = band((h0 + a) % 0x100000000, 0xffffffff)
    h1 = band((h1 + b) % 0x100000000, 0xffffffff)
    h2 = band((h2 + c) % 0x100000000, 0xffffffff)
    h3 = band((h3 + d) % 0x100000000, 0xffffffff)
    h4 = band((h4 + e) % 0x100000000, 0xffffffff)
  end

  return to_hex(h0) .. to_hex(h1) .. to_hex(h2) .. to_hex(h3) .. to_hex(h4)
end

return sha1
