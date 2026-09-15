local engine = require("fireworks.engine")
local layout_mod = require("fireworks.layout")
local light = require("fireworks.light")

describe("fireworks.engine filler block", function()
	local buf, win, layout
	local CFG = { brightness = 1, bg = 0.25, fg = 1, glow = 0.35, glow_radius = 6 }

	before_each(function()
		light.clear()
		vim.cmd("silent! %bwipeout!")
		buf = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "local x = 1", "return x" })
		win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(win, buf)
		layout = layout_mod.compute(win, buf)
	end)

	---Light the whole filler area, then build the block with one star in it.
	local function build(star_col)
		light.begin_frame()
		light.emit(layout.screen_row + layout.real_rows + 2, layout.screen_col + 10, 12, 1, { "#ff0000" })
		light.render({ layout }, 0, CFG)
		local queue = { { filler_row = 2, col = star_col, char = "*", hl = light.color_hl("#00ff00") } }
		return engine.filler_lines(layout, queue)
	end

	local function chunk_at(line, col)
		local x = 0
		for _, chunk in ipairs(line) do
			local w = vim.fn.strdisplaywidth(chunk[1])
			if col < x + w then
				return chunk
			end
			x = x + w
		end
	end

	it("paints the glow behind a star instead of leaving a hole", function()
		local lines = build(10)
		local star = chunk_at(lines[3], 10)
		assert.are.equal("*", star[1])
		assert.are.equal("table", type(star[2]), "a lit star stacks the tint under its own colour")
		assert.are.equal(2, #star[2])
		assert.is_true(star[2][1]:find("^FireworksL") ~= nil, "tint first so its background survives")
		assert.are.equal(light.color_hl("#00ff00"), star[2][2], "star colour last so its foreground wins")

		assert.are.equal(light.cell_hl(layout, layout.real_rows + 2, 10), star[2][1], "the star carries the tint of its own cell")
	end)

	it("leaves an unlit star with its plain colour", function()
		local lines = build(layout.width - 1)
		local star = chunk_at(lines[3], layout.width - 1)
		assert.are.equal("*", star[1])
		assert.are.equal(light.color_hl("#00ff00"), star[2], "no tint to stack, so no list")
	end)

	it("reports the block as unused when nothing is lit or drawn", function()
		light.begin_frame()
		light.render({ layout }, 0, CFG)
		local lines, used = engine.filler_lines(layout, {})
		assert.is_false(used)
		assert.are.equal(layout.filler_rows, #lines)
	end)
end)
