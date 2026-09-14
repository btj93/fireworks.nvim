local api = vim.api
local floor, ceil, sqrt, min, max, atan2, pi = math.floor, math.ceil, math.sqrt, math.min, math.max, math.atan2, math.pi
local set_extmark, del_extmark = api.nvim_buf_set_extmark, api.nvim_buf_del_extmark
local rep, concat = string.rep, table.concat

local M = {}

M.BUCKETS = 8
M.PRIORITY = 200

local STRIDE = 4096

local ns = api.nvim_create_namespace("fireworks_light")
local hl_cache = {}
local base_fg_cache = {}
local normal
local settings = { brightness = 0.7, bg = 0.25, fg = 1 }

local grid_i, grid_r, grid_g, grid_b = {}, {}, {}, {}
local flashes = {}
local base_cache = {}
local active_rows = {}

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

---Decay factor for elapsed fraction `u` in [0, 1]: 1 at the burst, 0 at the
---end. Smoothstep shaped, so the flash holds near full brightness for a
---moment before it falls instead of dropping steepest at the start.
function M.ease_out(u)
	if u <= 0 then
		return 1
	end
	if u >= 1 then
		return 0
	end
	return 1 - u * u * (3 - 2 * u)
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

---Nearest of eight steps. Rounding rather than ceiling gives the faintest
---step a real threshold, so the lit edge contracts as the light decays
---instead of staying on until the effect ends.
function M.bucket(intensity)
	if intensity <= 0 then
		return 0
	end
	return min(M.BUCKETS, floor(intensity * M.BUCKETS + 0.5))
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
---`inlines` is an optional `{byte = width}` map of inline virtual text; the
---cells it occupies map to `false`, since no buffer text is under them.
function M.col_to_byte(line, tabstop, inlines)
	local b = {}
	local col, byte = 0, 0
	if not inlines and not line:find("[\128-\255\t]") then
		for c = 0, #line do
			b[c] = c
		end
		return b, #line
	end
	local function gap(at)
		local w = inlines and inlines[at]
		if w then
			for c = col, col + w - 1 do
				b[c] = false
			end
			col = col + w
		end
	end
	for ch in line:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
		gap(byte)
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
	gap(byte)
	b[col] = byte
	return b, col
end

local function chunks_width(chunks)
	local w = 0
	for _, chunk in ipairs(chunks or {}) do
		w = w + vim.fn.strdisplaywidth(chunk[1])
	end
	return w
end

---Inline and end-of-line virtual text from other plugins on the visible
---rows, as `{[row0] = {inline = {[byte] = width}, eol = width, marks = {...}}}`.
---`marks` lists each mark as `{pos, byte, chunks}` in extmark order and
---`eol_marks` counts the eol ones, so copies are only drawn when the drawing
---order is knowable.
function M.virtual_text(l)
	local out = {}
	local ok, marks = pcall(api.nvim_buf_get_extmarks, l.buf, -1, { l.topline - 1, 0 }, { l.botline - 1, -1 }, { details = true })
	if not ok then
		return out
	end
	for _, m in ipairs(marks) do
		local d = m[4]
		if d.virt_text and d.ns_id ~= ns then
			local pos = d.virt_text_pos or "eol"
			if pos == "inline" or pos == "eol" then
				local entry = out[m[2]]
				if not entry then
					entry = { inline = {}, eol = 0, eol_marks = 0, marks = {} }
					out[m[2]] = entry
				end
				local w = chunks_width(d.virt_text)
				entry.marks[#entry.marks + 1] = { pos = pos, byte = m[3], chunks = d.virt_text }
				if pos == "inline" then
					entry.inline[m[3]] = (entry.inline[m[3]] or 0) + w
				else
					entry.eol_marks = entry.eol_marks + 1
					entry.eol = entry.eol + w
				end
			end
		end
	end
	return out
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
	base_fg_cache = {}
	base_cache = {}
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

---Final foreground of a highlight group with links followed, or false when
---the group sets none.
function M.group_fg(name)
	local cached = base_fg_cache[name]
	if cached ~= nil then
		return cached
	end
	local ok, hl = pcall(api.nvim_get_hl, 0, { name = name, link = false })
	local fg = (ok and hl.fg) and to_hex(hl.fg) or false
	base_fg_cache[name] = fg
	return fg
end

---Tint group for `hex` at `bucket`, blending from the foreground of `base`
---(a highlight group name) when given, else from Normal.
function M.tint_hl(hex, bucket, bg_strength, base, fg_strength)
	fg_strength = fg_strength == nil and 1 or fg_strength
	local name =
		string.format("FireworksL%s_%d_%d_%d_%s", hex:sub(2), bucket, floor(fg_strength * 100), floor(bg_strength * 100), base and base:gsub("[^%w]", "_") or "")
	if not hl_cache[name] then
		local n = M.normal_colors()
		local t = bucket / M.BUCKETS
		local spec = {}
		if fg_strength > 0 then
			local from = (base and M.group_fg(base)) or n.fg
			spec.fg = M.blend(from, hex, t * fg_strength)
		end
		if n.bg and bg_strength > 0 then
			spec.bg = M.blend(n.bg, hex, t * bg_strength)
		end
		api.nvim_set_hl(0, name, spec)
		hl_cache[name] = true
	end
	return name
end

local function byte_to_col_map(bytes, dw)
	local map = {}
	for c = dw, 0, -1 do
		map[bytes[c]] = c
	end
	return map
end

---Highlight group in effect at every visible cell of a window, from the
---treesitter highlighter and from `hl_group` extmarks of any namespace (LSP
---semantic tokens, diagnostics, other plugins). Returns `base[row][col]`
---for window rows, sparse, holding only groups that set a foreground.
---`rows` is the per-window-row `{bytes, dw}` from `col_to_byte`, keyed like
---`l.rows`; buffer rows map to window rows through `l.row_of`.
function M.base_highlights(l, rows)
	local base, prio = {}, {}
	for i in pairs(rows) do
		base[i], prio[i] = {}, {}
	end
	local maps = {}
	local function map_for(i)
		local m = maps[i]
		if not m then
			m = byte_to_col_map(rows[i].bytes, rows[i].dw)
			maps[i] = m
		end
		return m
	end
	local scan_top, scan_bot = l.topline - 1, l.botline
	local function paint(sr, sc, er, ec, hl, p)
		if not M.group_fg(hl) then
			return
		end
		for r = max(sr, scan_top), min(er, scan_bot - 1) do
			local i = l.row_of[r + 1]
			local info = i and rows[i]
			if info and base[i] then
				local m = map_for(i)
				local c0 = (r == sr) and (m[sc] or info.dw) or 0
				local c1 = (r == er) and (m[ec] or info.dw) or info.dw
				local brow, prow = base[i], prio[i]
				for c = c0, c1 - 1 do
					if (prow[c] or -1) <= p then
						brow[c], prow[c] = hl, p
					end
				end
			end
		end
	end

	-- `highlighter.active` is private. The whole function runs under pcall in
	-- `base_for`, so if it ever disappears the tint just blends from Normal fg
	-- instead of from the colour a token already has.
	if vim.treesitter.highlighter.active[l.buf] then
		local ok, parser = pcall(vim.treesitter.get_parser, l.buf)
		if ok and parser then
			pcall(parser.parse, parser, { scan_top, scan_bot })
			parser:for_each_tree(function(tree, ltree)
				local query = vim.treesitter.query.get(ltree:lang(), "highlights")
				if not query then
					return
				end
				local lang = ltree:lang()
				for id, node, metadata in query:iter_captures(tree:root(), l.buf, scan_top, scan_bot) do
					local capture = query.captures[id]
					if capture ~= "spell" and capture ~= "nospell" and capture ~= "conceal" and capture:sub(1, 1) ~= "_" then
						local meta = metadata[id]
						local p = tonumber((meta and meta.priority) or metadata.priority) or 100
						local sr, sc, er, ec = node:range()
						paint(sr, sc, er, ec, "@" .. capture .. "." .. lang, p)
					end
				end
			end)
		end
	end

	local ok, marks = pcall(api.nvim_buf_get_extmarks, l.buf, -1, { scan_top, 0 }, { scan_bot - 1, -1 }, { details = true, overlap = true })
	if ok then
		for _, m in ipairs(marks) do
			local d = m[4]
			local hl = d.hl_group
			if hl and d.ns_id ~= ns then
				if type(hl) == "table" then
					hl = hl[#hl]
				end
				if type(hl) == "string" then
					paint(m[2], m[3], d.end_row or m[2], d.end_col or (m[3] + 1), hl, d.priority or 4096)
				end
			end
		end
	end
	return base
end

---Per-window geometry and base highlights, recomputed when the window
---scrolls, resizes, changes buffer, or the buffer changes.
local function base_for(l)
	local tick = api.nvim_buf_get_changedtick(l.buf)
	local c = base_cache[l.win]
	if c and c.buf == l.buf and c.topline == l.topline and c.botline == l.botline and c.width == l.width and c.tick == tick and c.real_rows == l.real_rows then
		return c
	end
	local lines = {}
	if l.botline >= l.topline then
		local ok, got = pcall(api.nvim_buf_get_lines, l.buf, l.topline - 1, l.botline, false)
		if ok then
			lines = got
		end
	end
	local tabstop = vim.bo[l.buf].tabstop
	local virt = M.virtual_text(l)
	local geometry = {}
	for i, lnum in pairs(l.rows) do
		if not l.fold[i] then
			local v = virt[lnum - 1]
			local bytes, dw = M.col_to_byte(lines[lnum - l.topline + 1] or "", tabstop, v and next(v.inline) and v.inline or nil)
			local g = { bytes = bytes, dw = dw, tail = dw, copies = {} }
			if v then
				if v.eol > 0 then
					g.tail = dw + 1 + v.eol
				end
				local gap_cols = {}
				local col = 0
				while col < dw do
					if bytes[col] == false then
						gap_cols[#gap_cols + 1] = col
						while col < dw and bytes[col] == false do
							col = col + 1
						end
					else
						col = col + 1
					end
				end
				local inline_bytes = vim.tbl_keys(v.inline)
				table.sort(inline_bytes)
				local col_of_byte = {}
				for k, byte in ipairs(inline_bytes) do
					col_of_byte[byte] = gap_cols[k]
				end
				local seen_at = {}
				for _, mark in ipairs(v.marks) do
					if mark.pos == "inline" then
						local at = col_of_byte[mark.byte]
						if at then
							at = at + (seen_at[mark.byte] or 0)
							seen_at[mark.byte] = (seen_at[mark.byte] or 0) + chunks_width(mark.chunks)
							g.copies[#g.copies + 1] = { col = at, chunks = mark.chunks }
						end
					elseif v.eol_marks == 1 then
						g.copies[#g.copies + 1] = { col = dw + 1, chunks = mark.chunks }
					end
				end
			end
			geometry[i] = g
		end
	end
	local base = {}
	if settings.fg > 0 and next(geometry) then
		local ok, got = pcall(M.base_highlights, l, geometry)
		if ok then
			base = got
		end
	end
	c = { buf = l.buf, topline = l.topline, botline = l.botline, width = l.width, real_rows = l.real_rows, tick = tick, geometry = geometry, base = base }
	base_cache[l.win] = c
	return c
end

---Forget this frame's light field. Call before emitting for a new frame.
function M.begin_frame()
	grid_i, grid_r, grid_g, grid_b = {}, {}, {}, {}
end

local rgb_cache = {}
local function rgb(hex)
	local c = rgb_cache[hex]
	if not c then
		c = { parse(hex) }
		rgb_cache[hex] = c
	end
	return c
end

M.COLOR_STEP = 32

local quant_cache = {}
---Intensity-weighted mean colour of a cell, snapped to a coarse grid so
---blends between two shells produce a handful of groups, not thousands.
local function cell_color(k)
	local i = grid_i[k]
	local step = M.COLOR_STEP
	local r = min(255, floor(grid_r[k] / i / step + 0.5) * step)
	local g = min(255, floor(grid_g[k] / i / step + 0.5) * step)
	local b = min(255, floor(grid_b[k] / i / step + 0.5) * step)
	local key = r * 65536 + g * 256 + b
	local hex = quant_cache[key]
	if not hex then
		hex = string.format("#%02x%02x%02x", r, g, b)
		quant_cache[key] = hex
	end
	return hex
end

---Deposit light around screen cell (`row`, `col`): quadratic falloff over
---`radius` rows (twice that in columns), peak `strength`. Colour comes from
---`palette` by direction, or `soot` on the rows adjacent to the source.
---Overlapping emitters add up, and a cell's colour is the mean of what
---reached it weighted by how much each contributed.
function M.emit(row, col, radius, strength, palette, soot)
	if strength <= 0 then
		return
	end
	local single = #palette == 1 and rgb(palette[1]) or nil
	local soot_rgb = soot and rgb(soot) or nil
	local rr, cr = ceil(radius), ceil(radius * 2)
	for dr = -rr, rr do
		local srow = row + dr
		if srow >= 0 then
			local row_color = (soot_rgb and math.abs(dr) <= 1) and soot_rgb or single
			local kbase = srow * STRIDE + col
			for dc = -cr, cr do
				if col + dc >= 0 then
					local d = sqrt(dr * dr + dc * dc * 0.25)
					if d < radius then
						local f = 1 - d / radius
						f = f * f * strength
						local k = kbase + dc
						local c = row_color or rgb(M.color_at(palette, atan2(dr, dc * 0.5)))
						grid_i[k] = (grid_i[k] or 0) + f
						grid_r[k] = (grid_r[k] or 0) + f * c[1]
						grid_g[k] = (grid_g[k] or 0) + f * c[2]
						grid_b[k] = (grid_b[k] or 0) + f * c[3]
					end
				end
			end
		end
	end
end

---@class FireworksFlash
---@field row integer screen row
---@field col integer screen col
---@field radius number
---@field strength number
---@field attack number seconds
---@field duration number seconds
---@field palette string[]
---@field soot string|nil
---@field now number

---A burst flash: emitted every frame with its envelope until it fades.
function M.flash(f)
	flashes[#flashes + 1] = f
end

M.FLASH_SPLIT = 0.3

---A multi-colour flash is one kernel per colour, each pushed toward its
---sector by `FLASH_SPLIT` of the radius, so the overlap in the middle sums
---both colours instead of cutting between them.
function M.emit_flash(f, strength)
	local n = #f.palette
	if n == 1 then
		M.emit(f.row, f.col, f.radius, strength, f.palette, f.soot)
		return
	end
	local each = strength * 1.6 / n
	for i, color in ipairs(f.palette) do
		local mid = ((i - 0.5) / n) * 2 * pi - pi / 2
		local drow = floor(math.sin(mid) * f.radius * M.FLASH_SPLIT + 0.5)
		local dcol = floor(math.cos(mid) * f.radius * M.FLASH_SPLIT * 2 + 0.5)
		M.emit(f.row + drow, f.col + dcol, f.radius, each, { color }, f.soot)
	end
end

local function emit_flashes(now)
	local alive = {}
	for _, f in ipairs(flashes) do
		local elapsed = now - f.now
		if elapsed < f.attack + f.duration then
			alive[#alive + 1] = f
			M.emit_flash(f, f.strength * M.envelope(elapsed, f.attack, f.duration))
		end
	end
	flashes = alive
	return #alive > 0
end

local function cell_bucket(k)
	local v = grid_i[k]
	if not v then
		return 0
	end
	return M.bucket(settings.brightness * min(1, v))
end

---Tint group for a window cell this frame, or nil when unlit. Valid after
---`render` for the frame; used for the filler block below EOF.
function M.cell_hl(l, row, col)
	local k = (l.screen_row + row) * STRIDE + l.screen_col + col
	local b = cell_bucket(k)
	if b == 0 then
		return nil
	end
	return M.tint_hl(cell_color(k), b, settings.bg, nil, settings.fg)
end

---Runs of consecutive cells sharing a bucket, colour, and base highlight:
---`{c0, c1, hl}` with `c1` exclusive. Unlit cells are left out.
local function row_runs(l, srow, base, geometry)
	local runs = {}
	local cur_b, cur_color, cur_base, start = 0, nil, nil, 0
	local kbase = srow * STRIDE + l.screen_col
	local bytes, dw, tail = geometry.bytes, geometry.dw, geometry.tail
	for c = 0, l.width do
		local b, col, bs = 0, nil, nil
		local covered = (c < dw and bytes[c] == false) or (c >= dw and c < tail)
		if c < l.width and not covered then
			local k = kbase + c
			b = cell_bucket(k)
			if b > 0 then
				col = cell_color(k)
				bs = base[c]
			end
		end
		if b ~= cur_b or (b > 0 and (col ~= cur_color or bs ~= cur_base)) then
			if cur_b > 0 then
				runs[#runs + 1] = { start, c, M.tint_hl(cur_color, cur_b, settings.bg, cur_base, settings.fg) }
			end
			cur_b, cur_color, cur_base, start = b, col, bs, c
		end
	end
	return runs
end

local function drop_row(entry)
	if api.nvim_buf_is_valid(entry.buf) then
		for _, id in ipairs(entry.ids) do
			pcall(del_extmark, entry.buf, ns, id)
		end
	end
	entry.ids = {}
end

M.VIRT_PRIORITY = 5000

---Per-cell tint for one virtual text copy this frame: a list of
---`{char, hl_list}` chunks and a signature, or nil when no cell is lit.
local function lit_copy(l, srow, copy)
	local chunks, sig, lit = {}, {}, false
	local col = copy.col
	local kbase = srow * STRIDE + l.screen_col
	for _, chunk in ipairs(copy.chunks) do
		local theirs = chunk[2]
		local base
		if type(theirs) == "table" then
			base = theirs[#theirs]
		elseif type(theirs) == "string" then
			base = theirs
		end
		for ch in chunk[1]:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
			local w = vim.fn.strdisplaywidth(ch)
			local k = kbase + col
			local b = cell_bucket(k)
			local hls = {}
			if type(theirs) == "table" then
				for _, h in ipairs(theirs) do
					hls[#hls + 1] = h
				end
			elseif theirs then
				hls[1] = theirs
			end
			if b > 0 then
				lit = true
				local hex = cell_color(k)
				hls[#hls + 1] = M.tint_hl(hex, b, settings.bg, base, settings.fg)
				sig[#sig + 1] = b .. hex
			else
				sig[#sig + 1] = "0"
			end
			chunks[#chunks + 1] = { ch, hls }
			col = col + w
		end
	end
	if not lit then
		return nil
	end
	return chunks, concat(sig, ",")
end

local function set_row(entry, runs, geometry, copies)
	local ids = entry.ids
	local bytes, dw, tail = geometry.bytes, geometry.dw, geometry.tail
	for _, copy in ipairs(copies) do
		local ok, id = pcall(set_extmark, entry.buf, ns, entry.row0, 0, {
			virt_text = copy.chunks,
			virt_text_pos = "overlay",
			virt_text_win_col = copy.col,
			priority = M.VIRT_PRIORITY,
			strict = false,
		})
		if ok then
			ids[#ids + 1] = id
		end
	end
	local function byte_at(c)
		for cc = c, dw do
			if bytes[cc] then
				return bytes[cc]
			end
		end
		return bytes[dw]
	end
	for _, run in ipairs(runs) do
		local c0, c1, hl = run[1], run[2], run[3]
		if c0 < dw then
			local ok, id = pcall(set_extmark, entry.buf, ns, entry.row0, byte_at(c0), {
				end_col = byte_at(min(c1, dw)),
				hl_group = hl,
				priority = M.PRIORITY,
				strict = false,
			})
			if ok then
				ids[#ids + 1] = id
			end
		end
		if c1 > tail then
			local from = max(c0, tail)
			local ok, id = pcall(set_extmark, entry.buf, ns, entry.row0, 0, {
				virt_text = { { rep(" ", c1 - from), hl } },
				virt_text_pos = "overlay",
				virt_text_win_col = from,
				priority = M.PRIORITY,
				strict = false,
			})
			if ok then
				ids[#ids + 1] = id
			end
		end
	end
end

---Paint this frame's light field onto every window. Returns true while
---anything is lit or a flash is still alive.
function M.render(layouts, now, light_cfg)
	if light_cfg then
		settings = light_cfg
	end
	local flashing = emit_flashes(now)
	local seen = {}
	local any = false
	for _, l in ipairs(layouts) do
		local cache = base_for(l)
		for i, geometry in pairs(cache.geometry) do
			local srow = l.screen_row + i
			local runs = row_runs(l, srow, cache.base[i] or {}, geometry)
			local copies, parts = {}, {}
			for _, copy in ipairs(geometry.copies) do
				local chunks, sig = lit_copy(l, srow, copy)
				if chunks then
					copies[#copies + 1] = { col = copy.col, chunks = chunks }
					parts[#parts + 1] = "v" .. copy.col .. ":" .. sig
				end
			end
			if #runs > 0 or #copies > 0 then
				any = true
				local row0 = l.rows[i] - 1
				local id = l.win .. ":" .. l.buf .. ":" .. row0
				seen[id] = true
				for _, run in ipairs(runs) do
					parts[#parts + 1] = run[1] .. ":" .. run[2] .. ":" .. run[3]
				end
				local key = concat(parts, "|")
				local entry = active_rows[id]
				if not entry then
					entry = { buf = l.buf, row0 = row0, ids = {}, key = "" }
					active_rows[id] = entry
				end
				if entry.key ~= key then
					entry.key = key
					drop_row(entry)
					if api.nvim_buf_is_valid(l.buf) then
						set_row(entry, runs, geometry, copies)
					end
				end
			end
		end
	end
	for id, entry in pairs(active_rows) do
		if not seen[id] then
			drop_row(entry)
			active_rows[id] = nil
		end
	end
	return any or flashing
end

function M.clear()
	for _, entry in pairs(active_rows) do
		drop_row(entry)
	end
	active_rows = {}
	flashes = {}
	base_cache = {}
	grid_i, grid_r, grid_g, grid_b = {}, {}, {}, {}
end

return M
