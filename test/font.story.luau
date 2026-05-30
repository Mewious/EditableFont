local ReplicatedStorage = game:GetService("ReplicatedStorage")
local EditableFont = require(ReplicatedStorage.EditableFont)

return function()
	task.spawn(function()
		local data = game:GetService("HttpService"):GetAsync(
			"https://cdn.discordapp.com/attachments/912565426880413716/1509679283369672947/AIRBUSFCU_2.TTF?ex=6a1a0de5&is=6a18bc65&hm=ad2bc9785aad4a8da84583f6e2bb8987053a6ec65a332dd2a4e234f8d76fe081&"
		)
		EditableFont.new(data)
	end)

	return function() end
end
