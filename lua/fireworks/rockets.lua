local light = require("fireworks.light")

local random, floor, sin, cos, sqrt, pi, min, max = math.random, math.floor, math.sin, math.cos, math.sqrt, math.pi, math.min, math.max

local M = {}

M.GRAVITY = 5
M.ROCKET_SPEED = 24
M.ROCKET_STALL_SPEED = 4
M.ROCKET_FALL_GRAVITY = 10
M.ROCKET_TRAIL = 5
M.ROCKET_HEAD = "|"
M.ROCKET_TRAIL_GLYPHS = { "'", ":", ".", "·", "·" }
M.ROCKET_COLOR = "#ffe9a8"
M.SMOKE_COLOR = "#8a8a8a"
M.HANG_MIN = 0.15
M.HANG_MAX = 0.25
M.FLASH_LIFE = 0.07

M.TYPES = {
	peony = { spread = 0.35, drag = 1.8, gravity = 1.0, life = 2.4 },
	chrysanthemum = { spread = 0.35, drag = 1.8, gravity = 1.0, life = 2.6, trail = 3 },
	willow = { spread = 0.3, drag = 2.2, gravity = 0.9, life = 4.0 },
	ring = { spread = 0.0, drag = 1.8, gravity = 0.9, life = 2.4 },
	crossette = { spread = 0.2, drag = 1.8, gravity = 1.0, life = 2.4, split_at = 0.5 },
	crackle = { spread = 0.4, drag = 1.8, gravity = 1.0, life = 2.6, twinkle = true },
	pistil = { spread = 0.3, drag = 1.8, gravity = 1.0, life = 2.4, pistil = true },
	palm = { spread = 0.15, drag = 1.2, gravity = 1.3, life = 3.0, trail = 3, arms = 7 },
	kamuro = { spread = 0.2, drag = 2.0, gravity = 0.9, life = 4.5, trail = 5, palette = "gold" },
	salute = { salute = true, glow = 1.6 },
}

M.SIZES = {
	small = { speed = 5, count = 24 },
	medium = { speed = 8, count = 40 },
	large = { speed = 11, count = 64 },
}

M.FAILURES = { "dud", "premature", "fizzle" }

---Weighted pick over a `{name = weight}` table. `r` in [0, 1) overrides the
---random source so tests can pin the outcome.
function M.weighted(weights, r)
	local names = vim.tbl_keys(weights)
	table.sort(names)
	local total = 0
	for _, name in ipairs(names) do
		total = total + max(0, weights[name])
	end
	if total <= 0 then
		return names[1]
	end
	local pick = (r or random()) * total
	for _, name in ipairs(names) do
		local w = max(0, weights[name])
		if pick < w then
			return name
		end
		pick = pick - w
	end
	return names[#names]
end

function M.roll_fail(chance, r)
	return (r or random()) < chance
end

function M.pick_failure(r)
	return M.FAILURES[min(#M.FAILURES, floor((r or random()) * #M.FAILURES) + 1)]
end

function M.palette(kind, cfg)
	local colors = cfg.colors
	if kind == "gold" then
		return vim.deepcopy(cfg.gold)
	elseif kind == "rainbow" then
		return vim.deepcopy(colors)
	elseif kind == "two_tone" then
		local a = random(1, #colors)
		local b = random(1, #colors - 1)
		if b >= a then
			b = b + 1
		end
		return { colors[a], colors[b] }
	end
	return { colors[random(1, #colors)] }
end

---Deceleration that brings a rocket from launch speed to the stall speed
---exactly at the target row.
function M.climb_decel(distance)
	local v0, v1 = M.ROCKET_SPEED, M.ROCKET_STALL_SPEED
	return (v0 * v0 - v1 * v1) / (2 * max(1, distance))
end

---@class FireworksRocket
---@field x number
---@field y number
---@field vy number
---@field decel number
---@field launch_y number
---@field target_y number
---@field delay number seconds before the rocket leaves the tube
---@field hang number seconds of dark pause at apex before the break
---@field trail table[]
---@field type string
---@field palette string[]
---@field size string
---@field fail string|nil
---@field sputter_y number|nil
---@field falling boolean
---@field hanging boolean

function M.new_rocket(layout, cfg, opts)
	opts = opts or {}
	local launch_y = layout.total_rows - 1
	local fail = opts.fail
	if fail == nil and not opts.type and M.roll_fail(cfg.fail_chance) then
		fail = M.pick_failure()
	end
	local target_y = random(0, max(0, floor(layout.total_rows * 0.6)))
	if fail == "premature" then
		target_y = launch_y - 1
	end
	local kind = opts.type or M.weighted(cfg.types)
	local spec = M.TYPES[kind] or M.TYPES.peony
	local r = {
		x = random(2, max(2, layout.width - 3)),
		y = launch_y,
		vy = -M.ROCKET_SPEED,
		decel = M.climb_decel(launch_y - target_y),
		launch_y = launch_y,
		target_y = target_y,
		delay = opts.delay or 0,
		hang = fail == "premature" and 0 or (M.HANG_MIN + random() * (M.HANG_MAX - M.HANG_MIN)),
		t = 0,
		trail = {},
		type = kind,
		palette = M.palette(spec.palette or M.weighted(cfg.palettes), cfg),
		size = M.weighted(cfg.sizes),
		fail = fail,
		falling = false,
		hanging = false,
	}
	if fail == "dud" then
		r.sputter_y = launch_y - (launch_y - target_y) * (0.4 + random() * 0.3)
	end
	return r
end

---@return "waiting"|"climbing"|"hanging"|"burst"|"impact"
function M.update_rocket(r, dt)
	if r.delay > 0 then
		r.delay = r.delay - dt
		return "waiting"
	end
	if r.hanging then
		r.hang = r.hang - dt
		if r.hang <= 0 then
			return "burst"
		end
		return "hanging"
	end
	r.t = r.t + dt
	local trail = r.trail
	table.insert(trail, 1, { x = r.x, y = r.y })
	trail[M.ROCKET_TRAIL + 1] = nil

	if r.falling then
		r.vy = r.vy + M.ROCKET_FALL_GRAVITY * dt
		r.y = r.y + r.vy * dt
		if r.y >= r.launch_y then
			r.y = r.launch_y
			return "impact"
		end
		return "climbing"
	end

	r.vy = min(-M.ROCKET_STALL_SPEED, r.vy + r.decel * dt)
	r.y = r.y + r.vy * dt
	r.x = r.x + sin(r.t * 14) * 0.3
	if r.sputter_y and r.y <= r.sputter_y then
		r.falling = true
		r.vy = -2
		return "climbing"
	end
	if r.y <= r.target_y then
		r.y = r.target_y
		if r.hang <= 0 then
			return "burst"
		end
		r.hanging = true
		return "hanging"
	end
	return "climbing"
end

local function new_particle(x, y, angle, speed, color, spec)
	return {
		x = x,
		y = y,
		vx = cos(angle) * speed * 2,
		vy = sin(angle) * speed,
		gravity = M.GRAVITY * (spec.gravity or 1),
		drag = spec.drag or 1.8,
		age = 0,
		life = (spec.life or 2.4) * (0.8 + random() * 0.4),
		color = color,
		trail = spec.trail and {} or nil,
		trail_len = spec.trail,
		split_at = spec.split_at,
		twinkle = spec.twinkle,
		glyph = spec.glyph,
	}
end

---The bright core drawn for a couple of frames as the shell opens.
function M.flash(r, scale)
	scale = scale or 1
	local out = {}
	local color = r.palette[1]
	local cells = { { 0, 0 }, { 2, 0 }, { -2, 0 }, { 0, 1 }, { 0, -1 } }
	if scale > 1 then
		vim.list_extend(cells, { { 4, 0 }, { -4, 0 }, { 2, 1 }, { -2, 1 }, { 2, -1 }, { -2, -1 }, { 0, 2 }, { 0, -2 } })
	end
	for i, c in ipairs(cells) do
		out[i] = new_particle(r.x + c[1], r.y + c[2], 0, 0, color, { life = M.FLASH_LIFE * scale, gravity = 0, drag = 0, glyph = "*" })
	end
	return out
end

local function radial(r, spec, size, count, speed_scale, color_fn)
	local out = {}
	for i = 1, count do
		local angle = (i / count) * 2 * pi + (random() - 0.5) * (2 * pi / count)
		local speed = size.speed * speed_scale * (1 + (random() * 2 - 1) * spec.spread)
		out[#out + 1] = new_particle(r.x, r.y, angle, speed, color_fn(angle), spec)
	end
	return out
end

local function palm(r, spec, size)
	local out = {}
	local arms = spec.arms
	local base = (random() - 0.5) * 0.3
	for i = 0, arms - 1 do
		local angle = -pi / 2 + base + ((arms == 1 and 0) or (i / (arms - 1) - 0.5)) * pi * 1.3
		local color = light.color_at(r.palette, angle)
		for j = 1, 6 do
			out[#out + 1] = new_particle(r.x, r.y, angle, size.speed * (0.45 + 0.55 * j / 6), color, spec)
		end
	end
	return out
end

function M.burst(r)
	local spec = M.TYPES[r.type] or M.TYPES.peony
	local size = M.SIZES[r.size] or M.SIZES.medium
	if spec.salute then
		return {}
	end
	if spec.arms then
		return palm(r, spec, size)
	end
	local out = radial(r, spec, size, size.count, 1, function(angle)
		return light.color_at(r.palette, angle)
	end)
	if spec.pistil then
		local core = r.palette[2] or "#ffffff"
		vim.list_extend(
			out,
			radial(r, spec, size, floor(size.count / 2), 0.4, function()
				return core
			end)
		)
	end
	return out
end

---A handful of short-lived sparks, used for every failure mode.
function M.sparks(x, y, n, speed, life, color)
	local out = {}
	for i = 1, n do
		local angle = random() * 2 * pi
		out[i] = new_particle(x, y, angle, speed * (0.5 + random() * 0.5), color, { life = life, gravity = 1, drag = 1.5 })
	end
	return out
end

function M.smoke(x, y, n)
	local out = {}
	for i = 1, n do
		local p = new_particle(x, y, -pi / 2, 1.5 + random(), M.SMOKE_COLOR, { life = 1.6, gravity = 0, drag = 0.3, glyph = "~" })
		p.vx = (random() - 0.5) * 2
		p.wobble = random() * 2 * pi
		out[i] = p
	end
	return out
end

local function split(p)
	local out = {}
	for i = 0, 3 do
		local angle = pi / 4 + i * pi / 2
		out[i + 1] = new_particle(p.x, p.y, angle, 3, p.color, { life = 0.9, gravity = 1, drag = 1.2 })
	end
	return out
end

---@return boolean alive, table[]|nil children
function M.update_particle(p, dt)
	p.age = p.age + dt
	if p.age >= p.life then
		return false
	end
	p.vy = p.vy + p.gravity * dt
	local k = max(0, 1 - p.drag * dt)
	p.vx = p.vx * k
	p.vy = p.vy * k
	if p.wobble then
		p.wobble = p.wobble + dt * 4
		p.vx = p.vx + sin(p.wobble) * dt * 3
	end
	if p.trail then
		table.insert(p.trail, 1, { x = p.x, y = p.y })
		p.trail[p.trail_len + 1] = nil
	end
	p.x = p.x + p.vx * dt
	p.y = p.y + p.vy * dt
	if p.split_at and p.age >= p.split_at * p.life then
		return false, split(p)
	end
	return true
end

function M.glyph(p)
	if p.glyph then
		return p.glyph
	end
	local frac = p.age / p.life
	if frac > 0.8 then
		return "."
	end
	if frac > 0.6 then
		return "'"
	end
	local hv = p.vx / 2
	local speed = sqrt(hv * hv + p.vy * p.vy)
	if speed > 4.5 then
		return "*"
	elseif speed > 2.2 then
		return "✦"
	end
	return "·"
end

function M.visible(p)
	return not p.twinkle or random() < 0.6
end

function M.glow(r)
	local spec = M.TYPES[r.type]
	return spec and spec.glow or 1
end

return M
