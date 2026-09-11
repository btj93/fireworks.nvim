local layout = require("fireworks.layout")

describe("fireworks.layout", function()
	local buf, win

	before_each(function()
		vim.cmd("silent! %bwipeout!")
		buf = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two", "three" })
		win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(win, buf)
	end)

	it("counts filler rows below EOF on a short buffer", function()
		local l = layout.compute(win, buf)
		assert.is_not_nil(l)
		assert.are.equal(3, l.real_rows)
		assert.are.equal(l.height - 3, l.filler_rows)
		assert.are.equal(l.height, l.total_rows)
		assert.are.equal(2, l.last_row)
		assert.are.equal(1, l.topline)
	end)

	it("maps window cells to screen cells through position and textoff", function()
		vim.wo[win].number = true
		local l = layout.compute(win, buf)
		local info = vim.fn.getwininfo(win)[1]
		assert.is_true(info.textoff > 0)
		local r, c = layout.to_screen(l, 2, 5)
		assert.are.equal(l.screen_row + 2, r)
		assert.are.equal(info.wincol - 1 + info.textoff + 5, c)
		vim.wo[win].number = false
	end)

	it("returns nil for an invalid window", function()
		assert.is_nil(layout.compute(99999, buf))
	end)

	it("rejects special and ignored buffers", function()
		assert.is_true(layout.is_plain_buffer(buf, { "help" }))
		vim.bo[buf].filetype = "help"
		assert.is_false(layout.is_plain_buffer(buf, { "help" }))
		vim.bo[buf].filetype = ""
		vim.bo[buf].buftype = "nofile"
		assert.is_false(layout.is_plain_buffer(buf, {}))
	end)

	it("applies the size guard", function()
		assert.is_false(layout.big_enough({ height = 9, width = 80 }))
		assert.is_false(layout.big_enough({ height = 30, width = 19 }))
		assert.is_true(layout.big_enough({ height = 10, width = 20 }))
		assert.is_false(layout.big_enough(nil))
	end)
end)
