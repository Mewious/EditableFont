local EncodingService = game:GetService("EncodingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local EditableFont = require(ReplicatedStorage.EditableFont)

local function getFontData(name)
	local data = script.Parent.Fonts:FindFirstChild(name)
	if not data then
		error("Font data not found for font: " .. name)
	end
	return EncodingService:Base64Decode(buffer.fromstring(require(data)))
end

return function(target)
	task.spawn(function()
		local data = getFontData("MCDU-UPPER-CASE")
		local font = EditableFont.new(data)

		font:renderText({
			text = "A320-200",
			fontSize = 30,
			fontWeight = 1,
			parent = target,
			position = UDim2.new(0.5, 0, 0.5, 0),
			anchorPoint = Vector2.new(0.5, 0.5),
		})
	end)

	return function()
		-- font:destroy()
	end
end
