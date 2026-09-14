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

	it("maps rows through closed folds and virtual lines", function()
		local lines = {}
		for i = 1, 12 do
			lines[i] = ("line %d"):format(i)
		end
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		local ns = vim.api.nvim_create_namespace("layout_spec_marks")
		vim.wo[win].foldmethod = "manual"
		vim.cmd("4,5fold")
		vim.api.nvim_buf_set_extmark(buf, ns, 6, 0, { virt_lines = { { { "virtual", "Comment" } } } })
		vim.cmd("redraw")
		local l = layout.compute(win, buf)
		assert.are.equal(1, l.rows[0])
		assert.are.equal(3, l.rows[2])
		assert.are.equal(4, l.rows[3], "closed fold shows its first line")
		assert.is_true(l.fold[3])
		assert.is_nil(l.row_of[5], "the folded-away line has no row of its own")
		assert.are.equal(6, l.rows[4])
		assert.are.equal(7, l.rows[5])
		assert.is_nil(l.rows[6], "virtual line row belongs to no buffer line")
		assert.are.equal(8, l.rows[7])
		assert.are.equal(12, l.real_rows)
		assert.are.equal(l.height - 12, l.filler_rows)
		vim.cmd("normal! zE")
		vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	end)

	it("maps rows through lines hidden by conceal_lines", function()
		if vim.fn.has("nvim-0.11") == 0 then
			pending("conceal_lines needs Neovim 0.11")
			return
		end
		local lines = {}
		for i = 1, 12 do
			lines[i] = ("line %d"):format(i)
		end
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		local ns = vim.api.nvim_create_namespace("layout_spec_conceal")
		vim.api.nvim_buf_set_extmark(buf, ns, 2, 0, { end_row = 5, conceal_lines = "" })
		vim.wo[win].conceallevel = 2
		vim.cmd("redraw")
		local l = layout.compute(win, buf)
		assert.are.equal(1, l.rows[0])
		assert.are.equal(2, l.rows[1])
		assert.are.equal(7, l.rows[2], "lines 3 to 6 are concealed, line 7 takes row 2")
		assert.is_nil(l.row_of[4], "a concealed line has no row")
		assert.are.equal(8, l.real_rows)
		assert.are.equal(l.height - 8, l.filler_rows)
		vim.wo[win].conceallevel = 0
		vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	end)

	it("applies the size guard", function()
		assert.is_false(layout.big_enough({ height = 9, width = 80 }))
		assert.is_false(layout.big_enough({ height = 30, width = 19 }))
		assert.is_true(layout.big_enough({ height = 10, width = 20 }))
		assert.is_false(layout.big_enough(nil))
	end)
end)
