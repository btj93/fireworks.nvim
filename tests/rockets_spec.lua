local rockets = require("fireworks.rockets")
local config = require("fireworks.config")

describe("rockets.rockets pickers", function()
	it("respects weights when the roll is pinned", function()
		local weights = { a = 1, b = 3 }
		assert.are.equal("a", rockets.weighted(weights, 0))
		assert.are.equal("a", rockets.weighted(weights, 0.24))
		assert.are.equal("b", rockets.weighted(weights, 0.25))
		assert.are.equal("b", rockets.weighted(weights, 0.99))
	end)

	it("never picks a zero-weight entry", function()
		local weights = { peony = 0, ring = 1, willow = 0 }
		for r = 0, 0.99, 0.01 do
			assert.are.equal("ring", rockets.weighted(weights, r))
		end
	end)

	it("falls back to a name when every weight is zero", function()
		assert.is_not_nil(rockets.weighted({ a = 0, b = 0 }))
	end)

	it("rolls failures strictly below the chance", function()
		assert.is_true(rockets.roll_fail(0.05, 0.0))
		assert.is_true(rockets.roll_fail(0.05, 0.049))
		assert.is_false(rockets.roll_fail(0.05, 0.05))
		assert.is_false(rockets.roll_fail(0, 0))
	end)

	it("maps a roll onto the three failure kinds", function()
		assert.are.equal("dud", rockets.pick_failure(0))
		assert.are.equal("premature", rockets.pick_failure(0.4))
		assert.are.equal("fizzle", rockets.pick_failure(0.99))
	end)

	it("builds palettes of the right shape", function()
		local cfg = config.defaults
		assert.are.equal(1, #rockets.palette("single", cfg))
		local two = rockets.palette("two_tone", cfg)
		assert.are.equal(2, #two)
		assert.are_not.equal(two[1], two[2])
		assert.are.same(cfg.gold, rockets.palette("gold", cfg))
		assert.are.equal(#cfg.colors, #rockets.palette("rainbow", cfg))
	end)
end)

describe("rockets.rockets physics", function()
	local layout = { width = 80, total_rows = 40 }

	it("cools the comet tail from gold into the shell colour", function()
		local tail = rockets.tail_colors("#0000ff", 0.6)
		assert.are.equal(#rockets.ROCKET_TRAIL_GLYPHS, #tail)
		local function blue(hex)
			return tonumber(hex:sub(6, 7), 16)
		end
		for i = 2, #tail do
			assert.is_true(blue(tail[i]) > blue(tail[i - 1]), "cell " .. i .. " is further toward the shell colour")
		end
		assert.are_not.equal(rockets.ROCKET_COLOR, tail[1])
		assert.are_not.equal("#0000ff", tail[#tail], "never reaches the shell colour at tint 0.6")
	end)

	it("runs the shell colour along the trail at full tint", function()
		local tail = rockets.tail_colors("#0000ff", 1)
		assert.are.equal("#0000ff", tail[#tail], "the tail end is the shell colour exactly")
		local function dist(a, b)
			local d = 0
			for i = 2, 6, 2 do
				d = d + math.abs(tonumber(a:sub(i, i + 1), 16) - tonumber(b:sub(i, i + 1), 16))
			end
			return d
		end
		assert.is_true(
			dist(tail[1], "#0000ff") < dist(tail[1], rockets.ROCKET_COLOR),
			"even the cell behind the head is already closer to the shell than to gold: " .. tail[1]
		)
	end)

	it("keeps the classic gold tail at tint 0", function()
		for _, hex in ipairs(rockets.tail_colors("#0000ff", 0)) do
			assert.are.equal(rockets.ROCKET_COLOR, hex)
		end
		assert.are.equal(rockets.ROCKET_COLOR, rockets.tail_colors("#0000ff")[1])
	end)

	it("gives every rocket a tail drawn from its own palette", function()
		local r = rockets.new_rocket(layout, config.defaults, { type = "peony" })
		assert.are.equal(#rockets.ROCKET_TRAIL_GLYPHS, #r.tail)
		assert.are.equal(1, #r.glow_palette)
		local plain = rockets.new_rocket(layout, vim.tbl_extend("force", config.defaults, { tail_tint = 0 }), { type = "peony" })
		assert.are.equal(rockets.ROCKET_COLOR, plain.tail[#plain.tail])
		assert.are.equal(rockets.ROCKET_COLOR, plain.glow_palette[1])
	end)

	it("launches from the bottom row toward the top 60 percent", function()
		for _ = 1, 50 do
			local r = rockets.new_rocket(layout, config.defaults, { type = "peony" })
			assert.are.equal(39, r.y)
			assert.is_true(r.target_y <= 24)
			assert.is_nil(r.fail)
		end
	end)

	it("decelerates to the stall speed, hangs, then bursts at its target", function()
		local r = rockets.new_rocket(layout, config.defaults, { type = "ring" })
		local ev, hung, stall_vy = nil, 0, nil
		for _ = 1, 300 do
			ev = rockets.update_rocket(r, 1 / 30)
			assert.is_true(#r.trail <= rockets.ROCKET_TRAIL)
			if ev == "hanging" then
				hung = hung + 1
				stall_vy = stall_vy or r.vy
			end
			if ev == "burst" then
				break
			end
		end
		assert.are.equal("burst", ev)
		assert.are.equal(r.target_y, r.y)
		assert.is_true(hung >= 4, "hang lasted " .. hung .. " frames")
		assert.is_true(math.abs(stall_vy) <= rockets.ROCKET_STALL_SPEED + 1, "arrived at " .. tostring(stall_vy))
	end)

	it("takes over a second to climb a tall window", function()
		local r = rockets.new_rocket(layout, config.defaults, { type = "peony" })
		r.target_y = 10
		r.decel = rockets.climb_decel(r.launch_y - r.target_y)
		local frames = 0
		while rockets.update_rocket(r, 1 / 30) == "climbing" do
			frames = frames + 1
		end
		assert.is_true(frames > 45, "climbed in " .. frames .. " frames")
	end)

	it("dud sputters and falls back to the launch row", function()
		local r = rockets.new_rocket(layout, config.defaults, { fail = "dud" })
		local ev
		for _ = 1, 400 do
			ev = rockets.update_rocket(r, 1 / 30)
			if ev == "impact" then
				break
			end
		end
		assert.are.equal("impact", ev)
		assert.are.equal(r.launch_y, r.y)
	end)

	it("premature bursts one row above the tube", function()
		local r = rockets.new_rocket(layout, config.defaults, { fail = "premature" })
		assert.are.equal(38, r.target_y)
	end)

	it("ring particles share one speed and every particle dies", function()
		local r = rockets.new_rocket(layout, config.defaults, { type = "ring" })
		r.size = "medium"
		local ps = rockets.burst(r)
		assert.are.equal(rockets.SIZES.medium.count, #ps)
		for _, p in ipairs(ps) do
			local hv = p.vx / 2
			assert.is_true(math.abs(math.sqrt(hv * hv + p.vy * p.vy) - rockets.SIZES.medium.speed) < 1e-6)
		end
		local alive = 0
		for _, p in ipairs(ps) do
			local ok = true
			for _ = 1, 300 do
				ok = rockets.update_particle(p, 1 / 30)
				if not ok then
					break
				end
			end
			if ok then
				alive = alive + 1
			end
		end
		assert.are.equal(0, alive)
	end)

	it("crossette splits into four children at half life", function()
		local r = rockets.new_rocket(layout, config.defaults, { type = "crossette" })
		local p = rockets.burst(r)[1]
		local children
		for _ = 1, 200 do
			local alive, kids = rockets.update_particle(p, 1 / 30)
			if kids then
				children = kids
				assert.is_false(alive)
				break
			end
		end
		assert.is_not_nil(children)
		assert.are.equal(4, #children)
	end)

	it("pistil adds a slower white inner break when the palette has one colour", function()
		local r = rockets.new_rocket(layout, config.defaults, { type = "pistil" })
		r.size = "medium"
		r.palette = { "#ff0000" }
		local ps = rockets.burst(r)
		assert.are.equal(60, #ps)
		local inner, outer_speed, inner_speed = 0, 0, 0
		for _, p in ipairs(ps) do
			local hv = p.vx / 2
			local speed = math.sqrt(hv * hv + p.vy * p.vy)
			if p.color == "#ffffff" then
				inner = inner + 1
				inner_speed = inner_speed + speed
			else
				outer_speed = outer_speed + speed
			end
		end
		assert.are.equal(20, inner)
		assert.is_true(inner_speed / 20 < outer_speed / 40)
	end)

	it("palm bursts as arms of six, salute has no particles, kamuro is gold", function()
		local palm = rockets.new_rocket(layout, config.defaults, { type = "palm" })
		assert.are.equal(rockets.TYPES.palm.arms * 6, #rockets.burst(palm))
		local salute = rockets.new_rocket(layout, config.defaults, { type = "salute" })
		assert.are.equal(0, #rockets.burst(salute))
		assert.is_true(rockets.glow(salute) > 1)
		assert.is_true(#rockets.flash(salute, rockets.glow(salute)) > #rockets.flash(palm))
		local kamuro = rockets.new_rocket(layout, config.defaults, { type = "kamuro" })
		assert.are.same(config.defaults.gold, kamuro.palette)
	end)

	it("glyph ramp runs fast to slow to old", function()
		local p = { vx = 0, vy = 10, age = 0, life = 1 }
		assert.are.equal("*", rockets.glyph(p))
		p.vy = 3
		assert.are.equal("✦", rockets.glyph(p))
		p.vy = 1
		assert.are.equal("·", rockets.glyph(p))
		p.age = 0.7
		assert.are.equal("'", rockets.glyph(p))
		p.age = 0.9
		assert.are.equal(".", rockets.glyph(p))
		assert.are.equal("~", rockets.glyph({ glyph = "~" }))
	end)
end)
