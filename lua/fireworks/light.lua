local api = vim.api
local floor, ceil, sqrt, min, max, atan2, pi = math.floor, math.ceil, math.sqrt, math.min, math.max, math.atan2, math.pi
local set_extmark, del_extmark = api.nvim_buf_set_extmark, api.nvim_buf_del_extmark

local M = {}

M.BUCKETS = 8
M.SEGMENT = 10
M.PRIORITY = 200

local ns = api.nvim_create_namespace("fireworks_light")
local hl_cache = {}
local normal
local effects = {}

local function parse(hex)
	return tonumber(hex:sub(2, 3), 16), tonumber(hex:sub(4, 5), 16), tonumber(hex:sub(6, 7), 16)
end

local function to_hex(n)
	return string.format("#%06x", n)
end

function M.blend(a, b, t)
	local ar, ag, ab = parse(a)
	local br, bg, bb = parse(b)
	local function mix(x, y)
		return floor(x + (y - x) * t + 0.5)
	end
	return string.format("#%02x%02x%02x", mix(ar, br), mix(ag, bg), mix(ab, bb))
end

function M.distance(row1, col1, row2, col2)
	local dr, dc = row2 - row1, (col2 - col1) * 0.5
	return sqrt(dr * dr + dc * dc)
end

function M.intensity(d, radius, brightness)
	local f = 1 - d / radius
	if f <= 0 then
		return 0
	end
	return brightness * f * f
end

---Decay factor for elapsed fraction `u` in [0, 1]: 1 at the burst, 0 at the end.
function M.ease_out(u)
	if u <= 0 then
		return 1
	end
	if u >= 1 then
		return 0
	end
	local v = 1 - u
	return v * v
end

---Brightness envelope: a linear attack over `attack` seconds, then the
---quadratic ease out over `duration`. Zero once both have elapsed.
function M.envelope(elapsed, attack, duration)
	if elapsed < 0 then
		return 0
	end
	if attack > 0 and elapsed < attack then
		return elapsed / attack
	end
	return M.ease_out((elapsed - attack) / duration)
end

function M.bucket(intensity)
	if intensity <= 0 then
		return 0
	end
	return min(M.BUCKETS, ceil(intensity * M.BUCKETS - 1e-9))
end

---Palette entry for a direction. Angles are measured with `atan2(drow, dcol)`,
---rotated so the sectors start straight up and sweep clockwise: a two-tone
---palette lights the right half with colour 1 and the left half with colour 2.
function M.color_at(palette, angle)
	local n = #palette
	if n == 1 then
		return palette[1]
	end
	local frac = ((angle + pi / 2) % (2 * pi)) / (2 * pi)
	return palette[min(n, floor(frac * n) + 1)]
end

function M.normal_colors()
	if normal then
		return normal
	end
	local ok, hl = pcall(api.nvim_get_hl, 0, { name = "Normal", link = false })
	normal = {
		fg = (ok and hl.fg) and to_hex(hl.fg) or "#c0c0c0",
		bg = (ok and hl.bg) and to_hex(hl.bg) or nil,
	}
	return normal
end

function M.reset_highlights()
	hl_cache = {}
	normal = nil
end

function M.color_hl(hex)
	local name = "FireworksC" .. hex:sub(2)
	if not hl_cache[name] then
		api.nvim_set_hl(0, name, { fg = hex, bold = true })
		hl_cache[name] = true
	end
	return name
end

function M.tint_hl(hex, bucket, bg_strength)
	local name = string.format("FireworksL%s_%d", hex:sub(2), bucket)
	if not hl_cache[name] then
		local n = M.normal_colors()
		local t = bucket / M.BUCKETS
		local spec = { fg = M.blend(n.fg, hex, t) }
		if n.bg and bg_strength > 0 then
			spec.bg = M.blend(n.bg, hex, t * bg_strength)
		end
		api.nvim_set_hl(0, name, spec)
		hl_cache[name] = true
	end
	return name
end

---@class FireworksEffectOpts
---@field kind "light"|"burn"
---@field row integer screen row of the burst
---@field col integer screen col of the burst
---@field palette string[]
---@field radius number
---@field brightness number
---@field duration number seconds
---@field bg number bg blend strength
---@field now number
---@field layouts table[]
---@field soot string|nil darker colour for rows adjacent to a burn impact

function M.new_effect(opts)
	local e = {
		kind = opts.kind,
		t0 = opts.now,
		attack = opts.attack or 0,
		duration = opts.duration,
		radius = opts.radius,
		brightness = opts.brightness,
		bg = opts.bg,
		rows = {},
		fillers = {},
	}
	local rows = e.rows
	for _, l in ipairs(opts.layouts) do
		local lines = {}
		if l.real_rows > 0 then
			local ok, got = pcall(api.nvim_buf_get_lines, l.buf, l.topline - 1, l.botline, false)
			if ok then
				lines = got
			end
		end
		local fill = {}
		local nseg = ceil(l.width / M.SEGMENT)
		for row = 0, l.total_rows - 1 do
			local srow = l.screen_row + row
			local line = row < l.real_rows and lines[row + 1] or nil
			local dw = line and vim.fn.strdisplaywidth(line) or 0
			local lnum = l.topline + row
			for seg = 0, nseg - 1 do
				local c0 = seg * M.SEGMENT
				local c1 = min(l.width, c0 + M.SEGMENT)
				local scol = l.screen_col + (c0 + c1) / 2
				local d = M.distance(opts.row, opts.col, srow, scol)
				local tail = line ~= nil and c1 >= dw
				if tail then
					for s2 = seg + 1, nseg - 1 do
						local t0 = s2 * M.SEGMENT
						local tcol = l.screen_col + (t0 + min(l.width, t0 + M.SEGMENT)) / 2
						local td = M.distance(opts.row, opts.col, srow, tcol)
						if td < d then
							d, scol = td, tcol
						end
					end
				end
				if d < e.radius then
					local color
					if opts.soot and math.abs(srow - opts.row) <= 1 then
						color = opts.soot
					else
						color = M.color_at(opts.palette, atan2(srow - opts.row, (scol - opts.col) * 0.5))
					end
					if line then
						if dw == 0 then
							rows[#rows + 1] = { buf = l.buf, row0 = lnum - 1, whole_line = true, d = d, color = color, bucket = 0 }
						else
							local sb = vim.fn.virtcol2col(l.win, lnum, c0 + 1) - 1
							local seg_row = { buf = l.buf, row0 = lnum - 1, sb = max(0, sb), d = d, color = color, bucket = 0 }
							if tail then
								seg_row.to_eol = true
							else
								seg_row.eb = vim.fn.virtcol2col(l.win, lnum, c1 + 1) - 1
							end
							rows[#rows + 1] = seg_row
						end
					else
						local fr = row - l.real_rows
						fill[fr] = fill[fr] or {}
						fill[fr][seg] = { d = d, color = color }
					end
				end
				if tail then
					break
				end
			end
		end
		e.fillers[l.win] = fill
	end
	effects[#effects + 1] = e
	return e
end

local function seg_bucket(e, d, decay)
	return M.bucket(M.intensity(d, e.radius, e.brightness) * decay)
end

local function decay_of(e, now)
	return M.envelope(now - e.t0, e.attack, e.duration)
end

local function drop_marks(e)
	for _, seg in ipairs(e.rows) do
		if seg.id and api.nvim_buf_is_valid(seg.buf) then
			pcall(del_extmark, seg.buf, ns, seg.id)
		end
		seg.id = nil
	end
end

local function render_effect(e, now)
	local decay = decay_of(e, now)
	for _, seg in ipairs(e.rows) do
		local b = seg_bucket(e, seg.d, decay)
		if b ~= seg.bucket then
			seg.bucket = b
			if b == 0 then
				if seg.id then
					pcall(del_extmark, seg.buf, ns, seg.id)
					seg.id = nil
				end
			elseif api.nvim_buf_is_valid(seg.buf) then
				local hl = M.tint_hl(seg.color, b, e.bg)
				local mark
				if seg.whole_line then
					mark = { id = seg.id, line_hl_group = hl, priority = M.PRIORITY }
				elseif seg.to_eol then
					mark = { id = seg.id, end_row = seg.row0 + 1, end_col = 0, hl_group = hl, hl_eol = true, priority = M.PRIORITY, strict = false }
				else
					mark = { id = seg.id, end_col = seg.eb, hl_group = hl, priority = M.PRIORITY, strict = false }
				end
				local ok, id = pcall(set_extmark, seg.buf, ns, seg.row0, seg.whole_line and 0 or seg.sb, mark)
				if ok then
					seg.id = id
				end
			end
		end
	end
end

---Advance every effect to `now`. Returns true while any effect is alive.
function M.render(now)
	local alive = {}
	for _, e in ipairs(effects) do
		if now - e.t0 >= e.attack + e.duration then
			drop_marks(e)
		else
			render_effect(e, now)
			alive[#alive + 1] = e
		end
	end
	effects = alive
	return #effects > 0
end

---Highlight for a below-EOF filler cell of `win`, or nil when unlit.
function M.filler_tint(win, filler_row, seg, now)
	local best, best_hl = 0, nil
	for _, e in ipairs(effects) do
		local fill = e.fillers[win]
		local entry = fill and fill[filler_row] and fill[filler_row][seg]
		if entry then
			local b = seg_bucket(e, entry.d, decay_of(e, now))
			if b > best then
				best = b
				best_hl = M.tint_hl(entry.color, b, e.bg)
			end
		end
	end
	return best_hl
end

function M.has_filler_tint(win)
	for _, e in ipairs(effects) do
		if e.fillers[win] and next(e.fillers[win]) then
			return true
		end
	end
	return false
end

function M.active()
	return #effects > 0
end

function M.clear()
	for _, e in ipairs(effects) do
		drop_marks(e)
	end
	effects = {}
end

return M
