if vim.g.loaded_fireworks then
	return
end
vim.g.loaded_fireworks = 1

vim.api.nvim_create_user_command("Fireworks", function(a)
	require("fireworks").command(a.args)
end, {
	nargs = "?",
	complete = function()
		return require("fireworks").command_args()
	end,
	desc = "Launch fireworks (optionally force a type, a failure, or toggle the save trigger)",
})
