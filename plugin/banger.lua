if vim.g.loaded_banger then
	return
end
vim.g.loaded_banger = 1

vim.api.nvim_create_user_command("Banger", function(a)
	require("banger").command(a.args)
end, {
	nargs = "?",
	complete = function()
		return require("banger").command_args()
	end,
	desc = "Launch fireworks (optionally force a type, a failure, or toggle the save trigger)",
})
