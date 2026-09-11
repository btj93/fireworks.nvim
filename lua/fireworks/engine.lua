local layout_mod = require("fireworks.layout")
local rockets = require("fireworks.rockets")
local light = require("fireworks.light")

local api = vim.api
local uv = vim.uv or vim.loop
local floor, ceil, min, max, random = math.floor, math.ceil, math.min, math.max, math.random
local set_extmark, del_extmark = api.nvim_buf_set_extmark, api.nvim_buf_del_extmark
local rep = string.rep

local ns_canvas = api.nvim_create_namespace("fireworks")
local ns_filler = api.nvim_create_namespace("fireworks_filler")

local BLANK = { { "", "Normal" } }
local SIZE_GLOW = { small = 0.75, medium = 1, large = 1.15 }

local M = {}

local state = {
	cfg = nil,
	timer = nil,
	last = 0,
	shows = {},
	fillers = {},
}

local function draw_cell(l, queue, y, x, glyph, hl)
	local row, col = floor(y + 0.5), floor(x + 0.5)
	if row < 0 or row >= l.total_rows or col < 0 or col >= l.width then
		return
	end
	if row < l.real_rows then
		pcall(set_extmark, l.buf, ns_canvas, l.topline - 1 + row, 0, {
			virt_text = { { glyph, hl } },
			virt_text_pos = "overlay",
			virt_text_win_col = col,
			hl_mode = "combine",
			priority = 300,
		})
	else
		queue[#queue + 1] = { filler_row = row - l.real_rows, col = col, char = glyph, hl = hl }
	end
end

local function draw_rocket(r, l, queue)
	local hl = light.color_hl(rockets.ROCKET_COLOR)
	for i, t in ipairs(r.trail) do
		draw_cell(l, queue, t.y, t.x, rockets.ROCKET_TRAIL_GLYPHS[i] or ".", hl)
	end
	draw_cell(l, queue, r.y, r.x, r.falling and "," or rockets.ROCKET_HEAD, hl)
end

local function draw_particle(p, l, queue)
	if not rockets.visible(p) then
		return
	end
	if p.trail then
		local dim = light.tint_hl(p.color, 4, 0)
		for _, t in ipairs(p.trail) do
			draw_cell(l, queue, t.y, t.x, "·", dim)
		end
	end
	draw_cell(l, queue, p.y, p.x, rockets.glyph(p), light.color_hl(p.color))
end

local function burst_screen(r, l)
	return layout_mod.to_screen(l, floor(r.y + 0.5), floor(r.x + 0.5))
end

local function shine(r, l, layouts, now)
	local cfg = state.cfg
	local row, col = burst_screen(r, l)
	light.new_effect({
		kind = "light",
		row = row,
		col = col,
		palette = r.palette,
		radius = cfg.light.radius,
		brightness = cfg.light.brightness * (SIZE_GLOW[r.size] or 1),
		duration = cfg.light.duration_ms / 1000,
		bg = cfg.light.bg,
		now = now,
		layouts = layouts,
	})
end

local function burn(r, l, layouts, now, strength, soot)
	local cfg = state.cfg
	local row, col = burst_screen(r, l)
	light.new_effect({
		kind = "burn",
		row = row,
		col = col,
		palette = { cfg.burn.color },
		soot = soot and light.blend(cfg.burn.color, "#000000", 0.45) or nil,
		radius = cfg.light.radius * 0.6,
		brightness = cfg.light.brightness * strength,
		duration = cfg.burn.duration_ms / 1000,
		bg = cfg.light.bg,
		now = now,
		layouts = layouts,
	})
end

local function append(list, items)
	for _, it in ipairs(items) do
		list[#list + 1] = it
	end
end

local function step_show(show, l, dt, now, layouts)
	local cfg = state.cfg
	local queue = {}
	show.queue = queue
	local spawned = {}

	local flying = {}
	for _, r in ipairs(show.rockets) do
		local ev = rockets.update_rocket(r, dt)
		if ev == "burst" then
			if r.fail == "premature" then
				append(spawned, rockets.sparks(r.x, r.y, 5, 3, 0.5, r.palette[1]))
				burn(r, l, layouts, now, 1, true)
			elseif r.fail == "fizzle" then
				append(spawned, rockets.sparks(r.x, r.y, 6, 2.5, 0.6, r.palette[1]))
				burn(r, l, layouts, now, 0.3, false)
			else
				append(spawned, rockets.burst(r))
				shine(r, l, layouts, now)
			end
			if r.fail and cfg.burn.smoke then
				append(spawned, rockets.smoke(r.x, r.y, 3))
			end
		elseif ev == "impact" then
			append(spawned, rockets.sparks(r.x, r.y, 3, 1.5, 0.35, "#c0c0c0"))
			burn(r, l, layouts, now, 1, true)
			if cfg.burn.smoke then
				append(spawned, rockets.smoke(r.x, r.y, 4))
			end
		else
			flying[#flying + 1] = r
			if ev == "climbing" then
				draw_rocket(r, l, queue)
			end
		end
	end
	show.rockets = flying

	local alive = {}
	for _, p in ipairs(show.particles) do
		local ok, kids = rockets.update_particle(p, dt)
		if ok then
			alive[#alive + 1] = p
			draw_particle(p, l, queue)
		end
		if kids then
			append(alive, kids)
		end
	end
	append(alive, spawned)
	for i = cfg.max_particles + 1, #alive do
		alive[i] = nil
	end
	show.particles = alive
end

local function drop_filler(win)
	local f = state.fillers[win]
	if f then
		if api.nvim_buf_is_valid(f.buf) then
			pcall(del_extmark, f.buf, ns_filler, f.id)
		end
		state.fillers[win] = nil
	end
end

local function build_filler_lines(l, queue, now)
	local grouped = {}
	for _, it in ipairs(queue or {}) do
		if it.filler_row >= 0 and it.filler_row < l.filler_rows then
			grouped[it.filler_row] = grouped[it.filler_row] or {}
			table.insert(grouped[it.filler_row], it)
		end
	end
	local nseg = ceil(l.width / light.SEGMENT)
	local lines = {}
	for fr = 0, l.filler_rows - 1 do
		local items = grouped[fr]
		if items then
			table.sort(items, function(a, b)
				return a.col < b.col
			end)
		end
		local chunks = {}
		local ii, pos = 1, 0
		local lit = false
		for seg = 0, nseg - 1 do
			local c0 = seg * light.SEGMENT
			local c1 = min(l.width, c0 + light.SEGMENT)
			local hl = light.filler_tint(l.win, fr, seg, now)
			lit = lit or hl ~= nil
			hl = hl or "Normal"
			while items and items[ii] and items[ii].col < c1 do
				local it = items[ii]
				if it.col > pos then
					chunks[#chunks + 1] = { rep(" ", it.col - pos), hl }
					pos = it.col
				end
				if it.col == pos then
					chunks[#chunks + 1] = { it.char, it.hl }
					pos = pos + 1
				end
				ii = ii + 1
			end
			if c1 > pos then
				chunks[#chunks + 1] = { rep(" ", c1 - pos), hl }
				pos = c1
			end
		end
		lines[fr + 1] = (lit or items) and chunks or BLANK
	end
	return lines
end

local function render_fillers(layouts, glyphs, now)
	local seen = {}
	for _, l in ipairs(layouts) do
		local queue = glyphs[l.win]
		local wants = l.filler_rows > 0 and ((queue and #queue > 0) or light.has_filler_tint(l.win))
		if wants then
			seen[l.win] = true
			local f = state.fillers[l.win]
			if f and f.buf ~= l.buf then
				drop_filler(l.win)
				f = nil
			end
			local ok, id = pcall(set_extmark, l.buf, ns_filler, l.last_row, 0, {
				id = f and f.id or nil,
				virt_lines = build_filler_lines(l, queue, now),
				priority = 90,
			})
			if ok then
				state.fillers[l.win] = { buf = l.buf, id = id }
			end
		end
	end
	for win in pairs(state.fillers) do
		if not seen[win] then
			drop_filler(win)
		end
	end
end

local function tick()
	local now = uv.now() / 1000
	local dt = min(0.1, now - state.last)
	state.last = now

	local layouts = layout_mod.visible_layouts()
	local by_win = {}
	for _, l in ipairs(layouts) do
		by_win[l.win] = l
	end

	local glyphs = {}
	for buf, show in pairs(state.shows) do
		local l = by_win[show.win]
		if not l or l.buf ~= buf then
			local win = layout_mod.home_window(buf)
			l = win and by_win[win] or nil
			if l then
				show.win = win
			end
		end
		if api.nvim_buf_is_valid(buf) then
			pcall(api.nvim_buf_clear_namespace, buf, ns_canvas, 0, -1)
		end
		if not l then
			state.shows[buf] = nil
		else
			step_show(show, l, dt, now, layouts)
			glyphs[show.win] = show.queue
			if #show.rockets == 0 and #show.particles == 0 then
				state.shows[buf] = nil
			end
		end
	end

	local lit = light.render(now)
	render_fillers(layouts, glyphs, now)

	if next(state.shows) == nil and not lit then
		M.stop()
	end
end

local function start_timer()
	if state.timer then
		return
	end
	local interval = max(16, floor(1000 / state.cfg.fps))
	state.last = uv.now() / 1000
	state.timer = uv.new_timer()
	state.timer:start(
		interval,
		interval,
		vim.schedule_wrap(function()
			if not state.timer then
				return
			end
			local ok, err = pcall(tick)
			if not ok then
				M.stop()
				vim.notify("rockets.nvim: stopped after error: " .. tostring(err), vim.log.levels.WARN)
			end
		end)
	)
end

function M.particle_count()
	local n = 0
	for _, show in pairs(state.shows) do
		n = n + #show.particles
	end
	return n
end

---Queue rockets over `buf`. `opts.type` forces a firework type, `opts.fail`
---forces a failure kind, `opts.count` overrides the rocket count.
function M.launch(cfg, buf, opts)
	opts = opts or {}
	state.cfg = cfg
	local win = layout_mod.home_window(buf)
	if not win then
		return false
	end
	local l = layout_mod.compute(win, buf)
	if not layout_mod.big_enough(l) then
		return false
	end
	for _, show in pairs(state.shows) do
		if #show.particles >= cfg.max_particles then
			return false
		end
	end
	local show = state.shows[buf] or { buf = buf, win = win, rockets = {}, particles = {}, queue = {} }
	show.win = win
	state.shows[buf] = show
	local n = opts.count or random(cfg.rockets.min, cfg.rockets.max)
	for i = 1, n do
		show.rockets[#show.rockets + 1] = rockets.new_rocket(l, cfg, {
			type = opts.type,
			fail = opts.fail,
			delay = (i - 1) * random() * 0.4,
		})
	end
	start_timer()
	return true
end

function M.stop()
	if state.timer then
		local t = state.timer
		state.timer = nil
		pcall(function()
			t:stop()
			t:close()
		end)
	end
	for buf in pairs(state.shows) do
		if api.nvim_buf_is_valid(buf) then
			pcall(api.nvim_buf_clear_namespace, buf, ns_canvas, 0, -1)
		end
	end
	state.shows = {}
	for win in pairs(state.fillers) do
		drop_filler(win)
	end
	light.clear()
end

function M.is_running()
	return state.timer ~= nil
end

return M
