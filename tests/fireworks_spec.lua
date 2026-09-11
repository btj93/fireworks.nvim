local fireworks = require("banger.fireworks")
local config = require("banger.config")

describe("banger.fireworks pickers", function()
	it("respects weights when the roll is pinned", function()
		local weights = { a = 1, b = 3 }
		assert.are.equal("a", fireworks.weighted(weights, 0))
		assert.are.equal("a", fireworks.weighted(weights, 0.24))
		assert.are.equal("b", fireworks.weighted(weights, 0.25))
		assert.are.equal("b", fireworks.weighted(weights, 0.99))
	end)

	it("never picks a zero-weight entry", function()
		local weights = { peony = 0, ring = 1, willow = 0 }
		for r = 0, 0.99, 0.01 do
			assert.are.equal("ring", fireworks.weighted(weights, r))
		end
	end)

	it("falls back to a name when every weight is zero", function()
		assert.is_not_nil(fireworks.weighted({ a = 0, b = 0 }))
	end)

	it("rolls failures strictly below the chance", function()
		assert.is_true(fireworks.roll_fail(0.05, 0.0))
		assert.is_true(fireworks.roll_fail(0.05, 0.049))
		assert.is_false(fireworks.roll_fail(0.05, 0.05))
		assert.is_false(fireworks.roll_fail(0, 0))
	end)

	it("maps a roll onto the three failure kinds", function()
		assert.are.equal("dud", fireworks.pick_failure(0))
		assert.are.equal("premature", fireworks.pick_failure(0.4))
		assert.are.equal("fizzle", fireworks.pick_failure(0.99))
	end)

	it("builds palettes of the right shape", function()
		local cfg = config.defaults
		assert.are.equal(1, #fireworks.palette("single", cfg))
		local two = fireworks.palette("two_tone", cfg)
		assert.are.equal(2, #two)
		assert.are_not.equal(two[1], two[2])
		assert.are.same(cfg.gold, fireworks.palette("gold", cfg))
		assert.are.equal(#cfg.colors, #fireworks.palette("rainbow", cfg))
	end)
end)

describe("banger.fireworks physics", function()
	local layout = { width = 80, total_rows = 40 }

	it("launches from the bottom row toward the top 60 percent", function()
		for _ = 1, 50 do
			local r = fireworks.new_rocket(layout, config.defaults, { type = "peony" })
			assert.are.equal(39, r.y)
			assert.is_true(r.target_y <= 24)
			assert.is_nil(r.fail)
		end
	end)

	it("climbs, keeps a three cell trail, and bursts at its target", function()
		local r = fireworks.new_rocket(layout, config.defaults, { type = "ring" })
		local ev
		for _ = 1, 200 do
			ev = fireworks.update_rocket(r, 1 / 30)
			assert.is_true(#r.trail <= fireworks.ROCKET_TRAIL)
			if ev == "burst" then
				break
			end
		end
		assert.are.equal("burst", ev)
		assert.are.equal(r.target_y, r.y)
	end)

	it("dud sputters and falls back to the launch row", function()
		local r = fireworks.new_rocket(layout, config.defaults, { fail = "dud" })
		local ev
		for _ = 1, 400 do
			ev = fireworks.update_rocket(r, 1 / 30)
			if ev == "impact" then
				break
			end
		end
		assert.are.equal("impact", ev)
		assert.are.equal(r.launch_y, r.y)
	end)

	it("premature bursts one row above the tube", function()
		local r = fireworks.new_rocket(layout, config.defaults, { fail = "premature" })
		assert.are.equal(38, r.target_y)
	end)

	it("ring particles share one speed and every particle dies", function()
		local r = fireworks.new_rocket(layout, config.defaults, { type = "ring" })
		r.size = "medium"
		local ps = fireworks.burst(r)
		assert.are.equal(fireworks.SIZES.medium.count, #ps)
		for _, p in ipairs(ps) do
			local hv = p.vx / 2
			assert.is_true(math.abs(math.sqrt(hv * hv + p.vy * p.vy) - 10) < 1e-6)
		end
		local alive = 0
		for _, p in ipairs(ps) do
			local ok = true
			for _ = 1, 200 do
				ok = fireworks.update_particle(p, 1 / 30)
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
		local r = fireworks.new_rocket(layout, config.defaults, { type = "crossette" })
		local p = fireworks.burst(r)[1]
		local children
		for _ = 1, 200 do
			local alive, kids = fireworks.update_particle(p, 1 / 30)
			if kids then
				children = kids
				assert.is_false(alive)
				break
			end
		end
		assert.is_not_nil(children)
		assert.are.equal(4, #children)
	end)

	it("glyph ramp runs fast to slow to old", function()
		local p = { vx = 0, vy = 10, age = 0, life = 1 }
		assert.are.equal("*", fireworks.glyph(p))
		p.vy = 5
		assert.are.equal("✦", fireworks.glyph(p))
		p.vy = 1
		assert.are.equal("·", fireworks.glyph(p))
		p.age = 0.7
		assert.are.equal("'", fireworks.glyph(p))
		p.age = 0.9
		assert.are.equal(".", fireworks.glyph(p))
		assert.are.equal("~", fireworks.glyph({ glyph = "~" }))
	end)
end)
