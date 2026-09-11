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
		assert.are.equal(0, light.bucket(0.01))
		assert.are.equal(0, light.bucket(0.06))
		assert.are.equal(1, light.bucket(0.0625))
		assert.are.equal(1, light.bucket(0.125))
		assert.are.equal(1, light.bucket(0.18))
		assert.are.equal(2, light.bucket(0.19))
		assert.are.equal(8, light.bucket(1))
		assert.are.equal(8, light.bucket(5))
	end)

	it("lit radius contracts frame by frame as the light decays", function()
		local radius, brightness = 25, 0.7
		local function lit_extent(decay)
			local extent = 0
			for d = 0, radius, 0.25 do
				if light.bucket(light.intensity(d, radius, brightness) * decay) > 0 then
					extent = d
				end
			end
			return extent
		end
		local previous = lit_extent(1)
		assert.is_true(previous > 10)
		for u = 0.1, 0.6, 0.1 do
			local now = lit_extent(light.ease_out(u))
			assert.is_true(now < previous, ("extent %.2f did not shrink at u=%.1f"):format(now, u))
			previous = now
		end
		assert.are.equal(0, lit_extent(light.ease_out(0.9)))
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
		for _, row in ipairs(e.rows) do
			local any = false
			for c = 0, row.width - 1 do
				if row.d[c] then
					any = true
					assert.is_true(row.d[c] < 4)
				end
			end
			assert.is_true(any)
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
		assert.is_not_nil(light.filler_hl(win, 1, 5, 0))
		assert.is_nil(light.filler_hl(win, 1, 60, 0))
		assert.is_nil(light.filler_hl(win, 1, 5, 1))
		assert.are_not.equal(light.filler_hl(win, 1, 5, 0), light.filler_hl(win, 1, 9, 0))
	end)

	it("grades a long line cell by cell into several runs", function()
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { string.rep("x", 70), "", "short" })
		local layout = require("fireworks.layout").compute(win, buf)
		light.new_effect({
			kind = "light",
			row = layout.screen_row,
			col = layout.screen_col + 60,
			palette = { "#ff00ff" },
			radius = 20,
			brightness = 1,
			duration = 1,
			bg = 0.25,
			now = 0,
			layouts = { layout },
		})
		light.render(0)
		local ns = vim.api.nvim_create_namespace("fireworks_light")
		local marks = vim.api.nvim_buf_get_extmarks(buf, ns, { 0, 0 }, { 0, -1 }, { details = true })
		local groups, overlays = {}, 0
		for _, m in ipairs(marks) do
			local det = m[4]
			if det.hl_group then
				groups[det.hl_group] = true
				assert.is_true(det.end_col > m[3], "run has width")
			elseif det.virt_text then
				overlays = overlays + 1
				assert.is_true(det.virt_text_win_col >= 70)
			end
		end
		assert.is_true(vim.tbl_count(groups) >= 4, "buckets on the text: " .. vim.tbl_count(groups))
		assert.is_true(overlays >= 1, "past end of line is lit too")
		local blank = vim.api.nvim_buf_get_extmarks(buf, ns, { 1, 0 }, { 1, -1 }, { details = true })
		assert.is_true(#blank >= 2, "empty line is graded in overlay runs")
	end)

	it("blends from the highlight already on the cell", function()
		light.reset_highlights()
		vim.api.nvim_set_hl(0, "FireworksTestKeyword", { fg = "#0000ff" })
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "local value = 1", "", "" })
		local ns = vim.api.nvim_create_namespace("fireworks_test_marks")
		vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, { end_col = 5, hl_group = "FireworksTestKeyword", priority = 125 })
		local layout = require("fireworks.layout").compute(win, buf)
		local geometry = {}
		for i, line in ipairs({ "local value = 1", "", "" }) do
			local bytes, dw = light.col_to_byte(line, 8)
			geometry[i - 1] = { bytes = bytes, dw = dw }
		end
		local base = light.base_highlights(layout, geometry)
		assert.are.equal("FireworksTestKeyword", base[0][0])
		assert.are.equal("FireworksTestKeyword", base[0][4])
		assert.is_nil(base[0][5])
		local tinted = light.tint_hl("#ff0000", 8, 0, "FireworksTestKeyword", 0.5)
		local hl = vim.api.nvim_get_hl(0, { name = tinted, link = false })
		assert.are.equal(tonumber("800080", 16), hl.fg)
		local plain = light.tint_hl("#ff0000", 8, 0, nil, 0.5)
		assert.are_not.equal(tinted, plain)
		local off = light.tint_hl("#ff0000", 8, 0.25, "FireworksTestKeyword", 0)
		assert.is_nil(vim.api.nvim_get_hl(0, { name = off, link = false }).fg)
		vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	end)

	it("reads treesitter captures as base highlights", function()
		if not pcall(vim.treesitter.language.add, "lua") then
			pending("no lua parser")
			return
		end
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "local value = 1", "return value", "" })
		vim.bo[buf].filetype = "lua"
		vim.treesitter.start(buf, "lua")
		local layout = require("fireworks.layout").compute(win, buf)
		local geometry = {}
		for i, line in ipairs({ "local value = 1", "return value", "" }) do
			local bytes, dw = light.col_to_byte(line, 8)
			geometry[i - 1] = { bytes = bytes, dw = dw }
		end
		local base = light.base_highlights(layout, geometry)
		assert.is_not_nil(base[0][0], "keyword `local` has a capture")
		assert.is_true(base[0][0]:sub(1, 1) == "@")
		assert.is_not_nil(base[1][0], "keyword `return` has a capture")
		vim.treesitter.stop(buf)
	end)

	it("maps display columns to bytes through tabs and multibyte text", function()
		local b, dw = light.col_to_byte("\tab", 4)
		assert.are.equal(6, dw)
		assert.are.equal(0, b[0])
		assert.are.equal(0, b[3])
		assert.are.equal(1, b[4])
		assert.are.equal(2, b[5])
		assert.are.equal(3, b[6])
		local b2, dw2 = light.col_to_byte("héllo", 8)
		assert.are.equal(5, dw2)
		assert.are.equal(1, b2[1])
		assert.are.equal(3, b2[2])
		assert.are.equal(6, b2[5])
		local b3, dw3 = light.col_to_byte("plain", 8)
		assert.are.equal(5, dw3)
		assert.are.equal(4, b3[4])
		assert.are.equal(5, b3[5])
	end)
end)
