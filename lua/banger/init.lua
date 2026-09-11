local config = require("banger.config")
local engine = require("banger.engine")
local fireworks = require("banger.fireworks")
local layout = require("banger.layout")
local light = require("banger.light")

local M = {}

M.config = vim.deepcopy(config.defaults)
M.enabled = true

---@param opts BangerConfig|nil
function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", vim.deepcopy(config.defaults), opts or {})
	light.reset_highlights()

	local group = vim.api.nvim_create_augroup("Banger", { clear = true })
	vim.api.nvim_create_autocmd("ColorScheme", {
		group = group,
		callback = function()
			light.reset_highlights()
		end,
	})
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		callback = function()
			engine.stop()
		end,
	})
	if #M.config.events > 0 then
		vim.api.nvim_create_autocmd(M.config.events, {
			group = group,
			callback = function(a)
				pcall(M.on_write, a.buf)
			end,
		})
	end
end

function M.on_write(buf)
	if not M.enabled then
		return
	end
	local cfg = M.config
	if not layout.is_plain_buffer(buf, cfg.ignore_filetypes) then
		return
	end
	if math.random() >= cfg.launch_chance then
		return
	end
	engine.launch(cfg, buf, {})
end

function M.launch(opts)
	return engine.launch(M.config, vim.api.nvim_get_current_buf(), opts or {})
end

function M.toggle()
	M.enabled = not M.enabled
	if not M.enabled then
		engine.stop()
	end
	vim.notify("banger.nvim " .. (M.enabled and "armed" or "disarmed"), vim.log.levels.INFO)
	return M.enabled
end

function M.stop()
	engine.stop()
end

function M.command_args()
	local names = vim.tbl_keys(fireworks.TYPES)
	table.sort(names)
	vim.list_extend(names, { "fail" })
	vim.list_extend(names, fireworks.FAILURES)
	vim.list_extend(names, { "toggle", "stop" })
	return names
end

function M.command(arg)
	arg = vim.trim(arg or "")
	if arg == "" then
		return M.launch({})
	elseif arg == "toggle" then
		return M.toggle()
	elseif arg == "stop" then
		return engine.stop()
	elseif arg == "fail" then
		return M.launch({ fail = fireworks.pick_failure() })
	elseif vim.tbl_contains(fireworks.FAILURES, arg) then
		return M.launch({ fail = arg })
	elseif fireworks.TYPES[arg] then
		return M.launch({ type = arg })
	end
	vim.notify("banger.nvim: unknown argument " .. arg, vim.log.levels.ERROR)
end

return M
