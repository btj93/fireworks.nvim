local api = vim.api
local floor, ceil, sqrt, min, max, atan2, pi = math.floor, math.ceil, math.sqrt, math.min, math.max, math.atan2, math.pi
local set_extmark, del_extmark = api.nvim_buf_set_extmark, api.nvim_buf_del_extmark
local rep, concat = string.rep, table.concat

local M = {}

M.BUCKETS = 8
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

---Byte offset of the character covering each display column of `line`, as a
---0-indexed array `b` with `b[dw] == #line`. Returns the array and the display
---width. Tabs follow `tabstop`; other multibyte characters ask Neovim.
function M.col_to_byte(line, tabstop)
	local b = {}
	local col, byte = 0, 0
	if not line:find("[\128-\255\t]") then
		for c = 0, #line do
			b[c] = c
		end
		return b, #line
	end
	for ch in line:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
		local w
		if ch == "\t" then
			w = tabstop - (col % tabstop)
		elseif #ch == 1 then
			w = 1
		else
			w = vim.fn.strdisplaywidth(ch)
		end
		for c = col, col + w - 1 do
			b[c] = byte
		end
		col = col + w
		byte = byte + #ch
	end
	b[col] = byte
	return b, col
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
---@field attack number seconds
---@field duration number seconds
---@field bg number bg blend strength
---@field now number
---@field layouts table[]
---@field soot string|nil darker colour for rows adjacent to a burn impact

---Per-cell distance and colour for one screen row of `width` cells starting
---at `screen_col`. Returns nil when no cell is inside the radius.
local function row_cells(opts, radius, srow, screen_col, width)
	local d, color, any = {}, {}, false
	local soot = opts.soot and math.abs(srow - opts.row) <= 1
	for c = 0, width - 1 do
		local scol = screen_col + c
		local dist = M.distance(opts.row, opts.col, srow, scol)
		if dist < radius then
			any = true
			d[c] = dist
			color[c] = soot and opts.soot or M.color_at(opts.palette, atan2(srow - opts.row, (scol - opts.col) * 0.5))
		end
	end
	if any then
		return d, color
	end
	return nil
end

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
		local tabstop = vim.bo[l.buf].tabstop
		local fill = {}
		for row = 0, l.total_rows - 1 do
			local d, color = row_cells(opts, e.radius, l.screen_row + row, l.screen_col, l.width)
			if d then
				if row < l.real_rows then
					local line = lines[row + 1] or ""
					local bytes, dw = M.col_to_byte(line, tabstop)
					rows[#rows + 1] = {
						buf = l.buf,
						row0 = l.topline - 1 + row,
						width = l.width,
						dw = dw,
						bytes = bytes,
						d = d,
						color = color,
						marks = {},
						key = "",
					}
				else
					fill[row - l.real_rows] = { d = d, color = color }
				end
			end
		end
		e.fillers[l.win] = fill
	end
	effects[#effects + 1] = e
	return e
end

local function cell_bucket(e, d, decay)
	return M.bucket(M.intensity(d, e.radius, e.brightness) * decay)
end

local function decay_of(e, now)
	return M.envelope(now - e.t0, e.attack, e.duration)
end

---Runs of consecutive cells sharing a bucket and colour: `{c0, c1, hl}` with
---`c1` exclusive. Unlit cells are left out.
local function row_runs(e, row, decay)
	local runs = {}
	local cur_b, cur_color, start = 0, nil, 0
	local d, color = row.d, row.color
	for c = 0, row.width do
		local b, col
		if c < row.width then
			local dist = d[c]
			b = dist and cell_bucket(e, dist, decay) or 0
			col = color[c]
		else
			b = 0
		end
		if b ~= cur_b or (b > 0 and col ~= cur_color) then
			if cur_b > 0 then
				runs[#runs + 1] = { start, c, M.tint_hl(cur_color, cur_b, e.bg) }
			end
			cur_b, cur_color, start = b, col, c
		end
	end
	return runs
end

local function drop_row_marks(row)
	if api.nvim_buf_is_valid(row.buf) then
		for _, id in ipairs(row.marks) do
			pcall(del_extmark, row.buf, ns, id)
		end
	end
	row.marks = {}
end

local function set_row_marks(row, runs)
	local marks = row.marks
	local bytes, dw = row.bytes, row.dw
	for _, run in ipairs(runs) do
		local c0, c1, hl = run[1], run[2], run[3]
		if c0 < dw then
			local ok, id = pcall(set_extmark, row.buf, ns, row.row0, bytes[c0], {
				end_col = bytes[min(c1, dw)],
				hl_group = hl,
				priority = M.PRIORITY,
				strict = false,
			})
			if ok then
				marks[#marks + 1] = id
			end
		end
		if c1 > dw then
			local from = max(c0, dw)
			local ok, id = pcall(set_extmark, row.buf, ns, row.row0, 0, {
				virt_text = { { rep(" ", c1 - from), hl } },
				virt_text_pos = "overlay",
				virt_text_win_col = from,
				priority = M.PRIORITY,
				strict = false,
			})
			if ok then
				marks[#marks + 1] = id
			end
		end
	end
end

local function render_effect(e, now)
	local decay = decay_of(e, now)
	for _, row in ipairs(e.rows) do
		local runs = row_runs(e, row, decay)
		local parts = {}
		for i, run in ipairs(runs) do
			parts[i] = run[1] .. ":" .. run[2] .. ":" .. run[3]
		end
		local key = concat(parts, "|")
		if key ~= row.key then
			row.key = key
			drop_row_marks(row)
			if #runs > 0 and api.nvim_buf_is_valid(row.buf) then
				set_row_marks(row, runs)
			end
		end
	end
end

local function drop_marks(e)
	for _, row in ipairs(e.rows) do
		drop_row_marks(row)
		row.key = ""
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

---Highlight for one below-EOF filler cell of `win`, or nil when unlit.
function M.filler_hl(win, filler_row, col, now)
	local best, best_hl = 0, nil
	for _, e in ipairs(effects) do
		local fill = e.fillers[win]
		local entry = fill and fill[filler_row]
		local d = entry and entry.d[col]
		if d then
			local b = cell_bucket(e, d, decay_of(e, now))
			if b > best then
				best = b
				best_hl = M.tint_hl(entry.color[col], b, e.bg)
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
