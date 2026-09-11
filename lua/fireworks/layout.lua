local api = vim.api
local max, min = math.max, math.min

local M = {}

M.MIN_ROWS = 10
M.MIN_COLS = 20

---Full geometry snapshot for a window. Rows are counted from the window's
---top text row; `filler_rows` are the blank rows below EOF that the canvas
---claims with a virt_lines block.
---@return table|nil
function M.compute(win, buf)
	if not api.nvim_win_is_valid(win) or not api.nvim_buf_is_valid(buf) then
		return nil
	end
	local ok, info = pcall(vim.fn.getwininfo, win)
	if not ok or not info or not info[1] then
		return nil
	end
	local wi = info[1]
	local width = wi.width - wi.textoff
	if width <= 0 then
		return nil
	end

	local line_count = api.nvim_buf_line_count(buf)
	local topline = wi.topline
	local botline = min(wi.botline, line_count)
	local pos = api.nvim_win_get_position(win)
	local screen_row = pos[1] + (wi.winbar or 0)

	local rows, row_of, fold = M.row_map(win, topline, botline, screen_row, wi.height)

	local real_rows = 0
	if botline >= topline then
		local measured, th = pcall(api.nvim_win_text_height, win, { start_row = topline - 1, end_row = botline - 1 })
		real_rows = measured and min(wi.height, th.all) or (botline - topline + 1)
	end
	local filler_rows = 0
	if wi.botline >= line_count then
		filler_rows = max(0, wi.height - real_rows)
	end

	return {
		win = win,
		buf = buf,
		width = width,
		height = wi.height,
		topline = topline,
		botline = botline,
		rows = rows,
		row_of = row_of,
		fold = fold,
		real_rows = real_rows,
		filler_rows = filler_rows,
		total_rows = real_rows + filler_rows,
		line_count = line_count,
		last_row = line_count - 1,
		screen_row = screen_row,
		screen_col = pos[2] + wi.textoff,
	}
end

---Which buffer line starts on each window row. Concealed lines (`conceal_lines`)
---report the row of the line that replaces them, closed folds put every line
---on the fold's row, and wrapped lines or `virt_lines` leave rows that belong
---to no line start. Returns `rows[row] = lnum`, `row_of[lnum] = row`, and
---`fold[row] = true` for rows showing a closed fold.
function M.row_map(win, topline, botline, screen_row, height)
	local groups = {}
	for lnum = topline, botline do
		local ok, sp = pcall(vim.fn.screenpos, win, lnum, 1)
		if ok and sp.row and sp.row > 0 then
			local r = sp.row - 1 - screen_row
			if r >= 0 and r < height then
				local g = groups[r]
				if not g then
					g = {}
					groups[r] = g
				end
				g[#g + 1] = lnum
			end
		end
	end
	local rows, row_of, fold = {}, {}, {}
	for r, group in pairs(groups) do
		local lnum
		if #group == 1 then
			lnum = group[1]
		else
			local shown = 0
			for _, candidate in ipairs(group) do
				local ok, th = pcall(api.nvim_win_text_height, win, { start_row = candidate - 1, end_row = candidate - 1 })
				if ok and th.all > 0 then
					shown = shown + 1
					lnum = lnum or candidate
				end
			end
			if shown > 1 then
				fold[r] = true
			end
		end
		if lnum then
			rows[r] = lnum
			row_of[lnum] = r
		end
	end
	return rows, row_of, fold
end

function M.big_enough(layout)
	return layout ~= nil and layout.height >= M.MIN_ROWS and layout.width >= M.MIN_COLS
end

---Global screen cell of a window-local cell.
function M.to_screen(layout, row, col)
	return layout.screen_row + row, layout.screen_col + col
end

function M.is_normal_window(win)
	return api.nvim_win_is_valid(win) and api.nvim_win_get_config(win).relative == ""
end

function M.is_plain_buffer(buf, ignore_filetypes)
	if not api.nvim_buf_is_valid(buf) then
		return false
	end
	if api.nvim_get_option_value("buftype", { buf = buf }) ~= "" then
		return false
	end
	if not api.nvim_get_option_value("buflisted", { buf = buf }) then
		return false
	end
	local ft = api.nvim_get_option_value("filetype", { buf = buf })
	for _, ignored in ipairs(ignore_filetypes or {}) do
		if ft == ignored then
			return false
		end
	end
	return true
end

---Every visible non-floating window with a usable layout.
function M.visible_layouts()
	local out = {}
	for _, win in ipairs(api.nvim_list_wins()) do
		if M.is_normal_window(win) then
			local layout = M.compute(win, api.nvim_win_get_buf(win))
			if M.big_enough(layout) then
				out[#out + 1] = layout
			end
		end
	end
	return out
end

---The window that hosts a show for `buf`: the current window if it shows the
---buffer, else the first normal window that does.
function M.home_window(buf)
	local cur = api.nvim_get_current_win()
	if M.is_normal_window(cur) and api.nvim_win_get_buf(cur) == buf then
		return cur
	end
	for _, win in ipairs(api.nvim_list_wins()) do
		if M.is_normal_window(win) and api.nvim_win_get_buf(win) == buf then
			return win
		end
	end
	return nil
end

return M
