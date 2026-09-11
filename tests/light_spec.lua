local light = require("fireworks.light")

describe("fireworks.light math", function()
	it("weights columns at half a row", function()
		assert.are.equal(3, light.distance(0, 0, 3, 0))
		assert.are.equal(3, light.distance(0, 0, 0, 6))
		assert.are.equal(5, light.distance(0, 0, 3, 8))
	end)

	it("falls off quadratically to zero at the radius", function()
		assert.are.equal(0.7, light.intensity(0, 25, 0.7))
		assert.are.equal(0, light.intensity(25, 25, 0.7))
		assert.are.equal(0, light.intensity(40, 25, 0.7))
		assert.is_true(math.abs(light.intensity(12.5, 25, 1) - 0.25) < 1e-9)
	end)

	it("envelope ramps up over the attack then eases out", function()
		assert.are.equal(0, light.envelope(0, 0.1, 1))
		assert.are.equal(0.5, light.envelope(0.05, 0.1, 1))
		assert.are.equal(1, light.envelope(0.1, 0.1, 1))
		assert.are.equal(0.25, light.envelope(0.6, 0.1, 1))
		assert.are.equal(0, light.envelope(1.1, 0.1, 1))
		assert.are.equal(1, light.envelope(0, 0, 1))
	end)

	it("eases out from one to zero", function()
		assert.are.equal(1, light.ease_out(0))
		assert.are.equal(0, light.ease_out(1))
		assert.are.equal(0, light.ease_out(2))
		assert.are.equal(0.25, light.ease_out(0.5))
	end)

	it("buckets intensity into eight steps with zero meaning no mark", function()
		assert.are.equal(0, light.bucket(0))
		assert.are.equal(0, light.bucket(-1))
		assert.are.equal(1, light.bucket(0.01))
		assert.are.equal(1, light.bucket(0.125))
		assert.are.equal(2, light.bucket(0.13))
		assert.are.equal(8, light.bucket(1))
		assert.are.equal(8, light.bucket(5))
	end)

	it("blends channels linearly", function()
		assert.are.equal("#000000", light.blend("#000000", "#ffffff", 0))
		assert.are.equal("#ffffff", light.blend("#000000", "#ffffff", 1))
		assert.are.equal("#808080", light.blend("#000000", "#ffffff", 0.5))
		assert.are.equal("#804000", light.blend("#ff8000", "#000000", 0.5))
	end)

	it("splits a two-tone palette into right and left halves", function()
		local pal = { "right", "left" }
		assert.are.equal("right", light.color_at(pal, 0))
		assert.are.equal("right", light.color_at(pal, -math.pi / 4))
		assert.are.equal("left", light.color_at(pal, math.pi))
		assert.are.equal("left", light.color_at(pal, -3 * math.pi / 4))
		assert.are.equal("only", light.color_at({ "only" }, 2))
	end)

	it("creates tint groups that carry the firework colour", function()
		light.reset_highlights()
		local name = light.tint_hl("#ff0000", 8, 0.25)
		local hl = vim.api.nvim_get_hl(0, { name = name, link = false })
		local normal = light.normal_colors()
		local nfg = tonumber(normal.fg:sub(2), 16)
		assert.are.equal(0xff0000, hl.fg)
		local faint = light.tint_hl("#ff0000", 1, 0.25)
		local fhl = vim.api.nvim_get_hl(0, { name = faint, link = false })
		assert.are_not.equal(nfg, fhl.fg)
		assert.are_not.equal(0xff0000, fhl.fg)
	end)
end)

describe("fireworks.light effects", function()
	local buf, win

	before_each(function()
		light.clear()
		vim.cmd("silent! %bwipeout!")
		buf = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "alpha beta gamma delta epsilon zeta", "", "short" })
		win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(win, buf)
	end)

	it("marks only rows within the radius and drops them after the duration", function()
		local layout = require("fireworks.layout").compute(win, buf)
		local e = light.new_effect({
			kind = "light",
			row = layout.screen_row,
			col = layout.screen_col,
			palette = { "#00ff00" },
			radius = 4,
			brightness = 1,
			duration = 1,
			bg = 0.25,
			now = 0,
			layouts = { layout },
		})
		assert.is_true(#e.rows > 0)
		for _, seg in ipairs(e.rows) do
			assert.is_true(seg.d < 4)
		end
		assert.is_true(light.render(0))
		local marks = vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_create_namespace("fireworks_light"), 0, -1, {})
		assert.is_true(#marks > 0)
		assert.is_false(light.render(1.5))
		marks = vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_create_namespace("fireworks_light"), 0, -1, {})
		assert.are.equal(0, #marks, vim.inspect(vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_create_namespace("fireworks_light"), 0, -1, { details = true })))
	end)

	it("tints filler rows below EOF per segment", function()
		local layout = require("fireworks.layout").compute(win, buf)
		assert.is_true(layout.filler_rows > 2)
		light.new_effect({
			kind = "light",
			row = layout.screen_row + layout.real_rows + 1,
			col = layout.screen_col + 5,
			palette = { "#0000ff" },
			radius = 3,
			brightness = 1,
			duration = 1,
			bg = 0.25,
			now = 0,
			layouts = { layout },
		})
		assert.is_true(light.has_filler_tint(win))
		assert.is_not_nil(light.filler_tint(win, 1, 0, 0))
		assert.is_nil(light.filler_tint(win, 1, 6, 0))
		assert.is_nil(light.filler_tint(win, 1, 0, 1))
	end)
end)
