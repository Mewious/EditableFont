local EncodingService = game:GetService("EncodingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FontAtlas = require(ReplicatedStorage.EditableFont.FontAtlas)
local TTFParser = require(ReplicatedStorage.EditableFont.TTFParser)
local Create = require(script.Parent.Create)
local Maid = require(ReplicatedStorage.Packages.Maid)

local COLORS = {
	white = Color3.new(1, 1, 1),
	black = Color3.new(),
	green = Color3.new(0, 1, 0),
	blue = Color3.fromHex("#00d5ff"),
	orange = Color3.new(1, 0.5, 0),
	yellow = Color3.new(1, 1, 0),
	red = Color3.new(1, 0, 0),
}

type RichTextSegment = {
	text: string,
	color: Color3?,
	padding: number?,
	font: string?,
	transparency: number?,
	textSizeMultiplier: number?,
}

type RichTextValue = string | { RichTextSegment }

type RenderSegment = {
	text: string,
	color: Color3?,
	padding: number?,
	atlas: any,
	transparency: number?,
	textSizeMultiplier: number?,
}

type RichTextStyle = {
	color: Color3,
	padding: number,
	font: string,
	transparency: number,
	textSizeMultiplier: number,
}

local fonts = {}
for _, v in script.Parent.Fonts:GetChildren() do
	fonts[v.Name] = require(v)
end

local bakedFonts = {}

local RICH_TEXT_ENTITY_MAP = {
	amp = "&",
	lt = "<",
	gt = ">",
	quot = '"',
	apos = "'",
}

local codepoints: { number } = (function()
	local cp: { number } = {}
	for c = 0x20, 0x999E do
		cp[#cp + 1] = c
	end
	return cp
end)()

local function bakeText(font: string)
	if bakedFonts[font] then
		return bakedFonts[font]
	end

	local data = EncodingService:Base64Decode(buffer.fromstring(fonts[font]))

	local f = TTFParser.parse(data)
	local atlas = FontAtlas.bake(f, 30, codepoints, 1.5)

	bakedFonts[font] = atlas

	return atlas
end

local function cloneStyle(style: RichTextStyle): RichTextStyle
	return {
		color = style.color,
		padding = style.padding,
		font = style.font,
		transparency = style.transparency,
		textSizeMultiplier = style.textSizeMultiplier,
	}
end

local function decodeRichTextEntities(text: string): string
	return text:gsub("&([%a]+);", function(entity)
		return RICH_TEXT_ENTITY_MAP[entity] or "&" .. entity .. ";"
	end)
end

local function parseRichTextColor(rawValue: string): Color3?
	local value = rawValue:gsub("^%s+", ""):gsub("%s+$", "")
	if value == "" then
		return nil
	end

	if value:sub(1, 1) == "#" then
		local success, color = pcall(Color3.fromHex, value)
		if success then
			return color
		end
	end

	local r, g, b = value:match("^rgb%(([%d%.]+),%s*([%d%.]+),%s*([%d%.]+)%)$")
	if r and g and b then
		return Color3.fromRGB(
			math.clamp(tonumber(r) or 0, 0, 255),
			math.clamp(tonumber(g) or 0, 0, 255),
			math.clamp(tonumber(b) or 0, 0, 255)
		)
	end

	return nil
end

local function parseRichTextAttributes(attributeSource: string): { [string]: string }
	local attributes = {}
	for key, quote, value in attributeSource:gmatch("([%w:_-]+)%s*=%s*(['\"])(.-)%2") do
		attributes[string.lower(key)] = decodeRichTextEntities(value)
	end
	return attributes
end

local function appendRenderSegment(segments: { RenderSegment }, text: string, style: RichTextStyle)
	if text == "" then
		return
	end

	local decodedText = decodeRichTextEntities(text)
	if decodedText == "" then
		return
	end

	local segment: RenderSegment = {
		text = decodedText,
		color = style.color,
		padding = style.padding,
		atlas = bakeText(style.font),
		transparency = style.transparency,
		textSizeMultiplier = style.textSizeMultiplier,
	}

	local previous = segments[#segments]
	if
		previous
		and previous.atlas == segment.atlas
		and previous.color == segment.color
		and previous.padding == segment.padding
		and previous.transparency == segment.transparency
		and previous.textSizeMultiplier == segment.textSizeMultiplier
	then
		previous.text ..= segment.text
		return
	end

	segments[#segments + 1] = segment
end

local function parseRobloxRichText(
	text: string,
	defaultColor: Color3,
	defaultPadding: number,
	defaultFont: string
): { RenderSegment }
	local defaultStyle: RichTextStyle = {
		color = defaultColor,
		padding = defaultPadding,
		font = defaultFont,
		transparency = 0,
		textSizeMultiplier = 1,
	}
	local styleStack: { { tagName: string, style: RichTextStyle } } = {
		{ tagName = "root", style = defaultStyle },
	}
	local segments: { RenderSegment } = {}
	local cursor = 1

	while true do
		local startIndex, endIndex = text:find("<[^>]+>", cursor)
		if not startIndex then
			appendRenderSegment(segments, text:sub(cursor), styleStack[#styleStack].style)
			break
		end

		appendRenderSegment(segments, text:sub(cursor, startIndex - 1), styleStack[#styleStack].style)

		local rawTag = text:sub(startIndex + 1, endIndex - 1)
		local isClosing = rawTag:sub(1, 1) == "/"
		local isSelfClosing = rawTag:sub(-1, -1) == "/"
		if isClosing then
			rawTag = rawTag:sub(2)
		end
		if isSelfClosing then
			rawTag = rawTag:sub(1, -2)
		end

		rawTag = rawTag:gsub("^%s+", ""):gsub("%s+$", "")
		local tagName, attributeSource = rawTag:match("^(%S+)%s*(.-)$")
		tagName = string.lower(tagName or "")
		attributeSource = attributeSource or ""

		if isClosing then
			for index = #styleStack, 2, -1 do
				if styleStack[index].tagName == tagName then
					table.remove(styleStack, index)
					break
				end
			end
		elseif tagName == "br" then
			appendRenderSegment(segments, "\n", styleStack[#styleStack].style)
		elseif tagName ~= "" then
			local nextStyle = cloneStyle(styleStack[#styleStack].style)
			if tagName == "font" then
				local attributes = parseRichTextAttributes(attributeSource)

				local color = attributes.color and parseRichTextColor(attributes.color)
				if color then
					nextStyle.color = color
				end

				local fontName = attributes.face or attributes.font or attributes.family
				if fontName and fonts[fontName] then
					nextStyle.font = fontName
				end

				local transparency = tonumber(attributes.transparency or "")
				if transparency then
					nextStyle.transparency = math.clamp(transparency, 0, 1)
				end

				local size = tonumber(attributes.size or "")
				if size and size > 0 then
					local atlas = bakeText(nextStyle.font)
					nextStyle.textSizeMultiplier = size / atlas.fontSize
				end
			end

			styleStack[#styleStack + 1] = {
				tagName = tagName,
				style = nextStyle,
			}
		end

		cursor = endIndex + 1
	end

	return segments
end

local function createTopBar()
	local frame = Instance.new("Frame")
	frame.Name = "Frame"
	frame.BackgroundTransparency = 1
	frame.Size = UDim2.new(1, 0, -0.04, 50)

	local createText = Instance.new("TextButton")
	createText.Name = "CreateText"
	createText.AutomaticSize = Enum.AutomaticSize.X
	createText.BackgroundColor3 = Color3.new(1, 1, 1)
	createText.BorderColor3 = Color3.new()
	createText.BorderSizePixel = 0
	createText.FontFace = Font.new("rbxasset://fonts/families/SourceSansPro.json")
	createText.Size = UDim2.fromScale(0, 1)
	createText.Text = "TEXT"
	createText.TextColor3 = Color3.new()
	createText.TextSize = 20

	local uIPadding = Instance.new("UIPadding")
	uIPadding.Name = "UIPadding"
	uIPadding.PaddingLeft = UDim.new(0, 10)
	uIPadding.PaddingRight = UDim.new(0, 10)
	uIPadding.Parent = createText

	createText.Parent = frame

	local uIListLayout = Instance.new("UIListLayout")
	uIListLayout.Name = "UIListLayout"
	uIListLayout.FillDirection = Enum.FillDirection.Horizontal
	uIListLayout.Padding = UDim.new(0, 5)
	uIListLayout.Parent = frame

	local export = Instance.new("TextButton")
	export.Name = "Export"
	export.AutomaticSize = Enum.AutomaticSize.X
	export.BackgroundColor3 = Color3.new(1, 1, 1)
	export.BorderColor3 = Color3.new()
	export.BorderSizePixel = 0
	export.FontFace = Font.new("rbxasset://fonts/families/SourceSansPro.json")
	export.Size = UDim2.fromScale(0, 1)
	export.Text = "EXPORT"
	export.TextColor3 = Color3.new()
	export.TextSize = 20

	local uIPadding1 = Instance.new("UIPadding")
	uIPadding1.Name = "UIPadding"
	uIPadding1.PaddingLeft = UDim.new(0, 10)
	uIPadding1.PaddingRight = UDim.new(0, 10)
	uIPadding1.Parent = export

	export.Parent = frame

	return frame
end

local function createMCDULines()
	local frame = Instance.new("Frame")
	frame.Name = "Frame"
	frame.AnchorPoint = Vector2.new(0.5, 0)
	frame.BackgroundTransparency = 1
	frame.Position = UDim2.fromScale(0.5, 0.2)
	frame.Size = UDim2.fromScale(0.68, 0.64)

	local uIListLayout = Instance.new("UIListLayout")
	uIListLayout.Name = "UIListLayout"
	uIListLayout.Padding = UDim.new(0, 32)
	uIListLayout.Parent = frame

	local padding = Instance.new("UIPadding")
	padding.Name = "UIPadding"
	padding.PaddingLeft = UDim.new(0, 16)
	-- padding.Parent = frame

	local lines = {}

	for i = 1, 7 do
		local frame1 = Instance.new("Frame")
		frame1.Name = "Frame"
		frame1.BackgroundColor3 = Color3.new(1, 1, 1)
		frame1.BackgroundTransparency = 1
		frame1.BorderColor3 = Color3.new()
		frame1.BorderSizePixel = 0
		frame1.Size = UDim2.new(1, 0, 0, if i == 1 then 45 else 30)
		frame1.Parent = frame
		frame1.LayoutOrder = i
		frame1.Name = "Line" .. i
		lines[i] = frame1
	end

	return frame, lines
end

local function normalizeRichText(
	text: RichTextValue,
	defaultColor: Color3,
	defaultPadding: number,
	defaultFont: string
): { RenderSegment }
	if type(text) == "string" then
		return parseRobloxRichText(text, defaultColor, defaultPadding, defaultFont)
	end

	local segments: { RenderSegment } = {}
	for _, segment in text do
		local atlas = bakeText(segment.font or defaultFont)
		segments[#segments + 1] = {
			text = segment.text,
			color = segment.color or defaultColor,
			padding = if segment.padding ~= nil then segment.padding else defaultPadding,
			atlas = atlas,
			transparency = math.clamp(segment.transparency or 0, 0, 1),
			textSizeMultiplier = segment.textSizeMultiplier or 1,
		}
	end

	return segments
end

local function getAlignmentLayout(xAlignment: Enum.TextXAlignment?): (UDim2, Vector2)
	if xAlignment == Enum.TextXAlignment.Center then
		return UDim2.fromScale(0.5, 0.5), Vector2.new(0.5, 0.5)
	elseif xAlignment == Enum.TextXAlignment.Right then
		return UDim2.fromScale(1, 0.5), Vector2.new(1, 0.5)
	end

	return UDim2.fromScale(0, 0.5), Vector2.new(0, 0.5)
end

local function renderFMGCText(data: {
	title: {
		text: RichTextValue,
		color: Color3,
		padding: number?,
		baseline: number?,
		parent: Instance,
		font: string?,
		xAlignment: Enum.TextXAlignment?,
		position: UDim2?,
		anchorPoint: Vector2?,
		xPadding: number?,
		yPadding: number?,
		scale: number?,
		textSizeMultiplier: number?,
	}?,
	mainText: {
		text: RichTextValue,
		color: Color3,
		padding: number?,
		baseline: number?,
		parent: Instance,
		position: UDim2?,
		anchorPoint: Vector2?,
		font: string?,
		xAlignment: Enum.TextXAlignment?,
		xPadding: number?,
		yPadding: number?,
		scale: number?,
		textSizeMultiplier: number?,
	}?,
})
	if not select(1, data) then
		return {}
	end

	local atlas = bakeText(data.mainText and data.mainText.font or "FMGC-SMALL")
	local atlas2

	local mainText = data.mainText
	local title = data.title

	local titleFrame
	local mainTextFrame

	if title then
		if title.font ~= mainText.font then
			atlas2 = bakeText(title.font)
		end

		local defaultPosition, defaultAnchorPoint = getAlignmentLayout(title.xAlignment)

		titleFrame = FontAtlas.newTextLine({
			atlas = atlas2 or atlas,
			textData = normalizeRichText(title.text, title.color, title.padding or -15, title.font),
			fillDirection = Enum.FillDirection.Horizontal,
			scale = title.scale or 0.5,
			textSizeMultiplier = title.textSizeMultiplier or 1,
		})
		titleFrame.Name = "Title"
		titleFrame.Parent = title.parent
		titleFrame.Position = title.position
			or UDim2.new(
				defaultPosition.X.Scale,
				defaultPosition.X.Offset + (title.xPadding or 0),
				defaultPosition.Y.Scale,
				defaultPosition.Y.Offset + (title.yPadding or 0)
			)
		titleFrame.AnchorPoint = title.anchorPoint or defaultAnchorPoint
	end

	if mainText then
		local defaultPosition, defaultAnchorPoint = getAlignmentLayout(mainText.xAlignment)

		mainTextFrame = FontAtlas.newTextLine({
			atlas = atlas,
			textData = normalizeRichText(mainText.text, mainText.color, mainText.padding or -15, mainText.font),
			fillDirection = Enum.FillDirection.Horizontal,
			scale = mainText.scale or 0.5,
			textSizeMultiplier = mainText.textSizeMultiplier or 1,
		})
		mainTextFrame.Name = "MainText"
		mainTextFrame.Parent = mainText.parent
		mainTextFrame.Position = mainText.position
			or UDim2.new(
				defaultPosition.X.Scale,
				defaultPosition.X.Offset + (mainText.xPadding or 0),
				defaultPosition.Y.Scale,
				defaultPosition.Y.Offset + (mainText.yPadding or 0)
			)
		mainTextFrame.AnchorPoint = mainText.anchorPoint or defaultAnchorPoint
	end

	return {
		titleFrame,
		mainTextFrame,
	}
end

local function moveableTextBox(target, delete: () -> ())
	local textbox = Instance.new("TextBox")
	textbox.Size = UDim2.fromOffset(0, 0)
	textbox.PlaceholderText = ""
	textbox.Text = "WOW"
	textbox.TextSize = 14
	textbox.TextColor3 = Color3.new(0, 0, 0)
	textbox.BackgroundColor3 = Color3.new(0, 0, 0)
	textbox.BackgroundTransparency = 0.5
	textbox.BorderSizePixel = 0
	textbox.AutomaticSize = Enum.AutomaticSize.XY
	textbox.Position = UDim2.fromScale(0.5, 0.5)
	textbox.AnchorPoint = Vector2.new(0.5, 0.5)
	textbox.ZIndex = 999
	textbox.ClearTextOnFocus = false
	textbox.TextTransparency = 1

	textbox.PlaceholderColor3 = Color3.new(1, 1, 1)

	local uidragger = Instance.new("UIDragDetector")
	uidragger.BoundingUI = target
	uidragger.Parent = textbox

	local frame
	local atlas

	local scale = 1
	local hidden = false

	local function renderText()
		if atlas then
			atlas.destroy()
			atlas = nil
		end
		if frame then
			frame:Destroy()
			frame = nil
		end

		atlas = bakeText("ProSimDisplay")
		frame = FontAtlas.newTextLine({
			atlas = atlas,
			textData = normalizeRichText(textbox.Text, Color3.new(1, 1, 1), 0, "ProSimDisplay"),
			fillDirection = Enum.FillDirection.Horizontal,
			scale = 0.5 * scale,
		})
		frame.Name = "TextFrame"
		frame.Parent = textbox
		frame.Position = UDim2.fromOffset(0, 0)
		frame.Visible = uidragger.Enabled
	end

	local function u()
		textbox.BackgroundColor3 = if uidragger.Enabled
			then Color3.new(0.129412, 1, 0.172549)
			else Color3.new(1, 0.141176, 0.286275)
		textbox.TextTransparency = if not uidragger.Enabled then 0.5 else 1
		if textbox:FindFirstChild("TextFrame") then
			textbox.TextFrame.Visible = uidragger.Enabled
		end
		textbox.BackgroundTransparency = hidden and 1 or 0.5
	end

	uidragger:GetPropertyChangedSignal("Enabled"):Connect(function()
		u()
		renderText()
	end)
	task.defer(renderText)

	textbox.FocusLost:Connect(function(ePressed)
		if ePressed then
			uidragger.Enabled = true
		end
	end)
	u()

	textbox.InputBegan:Connect(function(i: InputObject)
		if i.KeyCode == Enum.KeyCode.Delete then
			delete()
			return
		end
		if i.UserInputType == Enum.UserInputType.MouseButton2 then
			uidragger.Enabled = not uidragger.Enabled
			if not uidragger.Enabled then
				textbox:CaptureFocus()
			else
				textbox:ReleaseFocus()
			end
		elseif i.KeyCode == Enum.KeyCode.H then
			hidden = not hidden
			u()
		end
	end)

	return textbox
end

return function(target)
	local maid = Maid.new()

	local topbar = createTopBar()
	local mcduLineFrame, lineSelects = createMCDULines()

	local refImage = Instance.new("ImageLabel")
	refImage.Name = "ReferenceImage"
	refImage.BackgroundTransparency = 1
	refImage.Image = "rbxassetid://140413404440888"
	refImage.Size = UDim2.fromScale(1, 1)
	refImage.ScaleType = Enum.ScaleType.Fit
	refImage.ImageColor3 = Color3.new(0.6, 0.6, 0.6)

	local bg = Instance.new("Frame")
	bg.Name = "Frame"
	bg.AnchorPoint = Vector2.new(0.5, 0.5)
	bg.BackgroundColor3 = Color3.new()
	bg.BorderColor3 = Color3.new()
	bg.BorderSizePixel = 0
	bg.Position = UDim2.fromScale(0.5, 0.5)
	bg.Size = UDim2.new(0.51, 100, 0, 420)

	bg.Parent = refImage

	local main = Create("Frame", {
		Name = "Main",
		BackgroundTransparency = 0.9,
		BackgroundColor3 = Color3.new(0, 0, 0),
		Parent = target,
		Size = UDim2.new(0, 700, 0, 700),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),

		Children = {
			topbar,
			refImage,
			mcduLineFrame,
		},
	}, {

		aspectRatio = Create("UIAspectRatioConstraint", {
			AspectRatio = 1,
		}),
	})

	local function createTextBox()
		local t
		t = moveableTextBox(main, function()
			t:Destroy()
		end)
		t.Parent = main
		maid:Add(t)
	end

	main.Parent = target

	topbar.CreateText.MouseButton1Click:Connect(createTextBox)

	local scale = 1

	local lineData = {
		{
			mainText = {
				text = "      A320-200",
				color = COLORS.white,
				padding = 0,
				parent = refImage,
				font = "MCDU-UPPER-CASE",
				scale = scale,
				xAlignment = Enum.TextXAlignment.Left,
			},
		},

		{
			title = {
				text = " ENG",
				color = COLORS.white,
				padding = 0,
				font = "MCDU-LOWER-CASE",
				yPadding = -30,
				xPadding = 0,
				scale = scale,
				textSizeMultiplier = 1,
			},
			mainText = {
				text = "V2527-A5",
				color = COLORS.green,
				padding = 0,
				font = "MCDU-UPPER-CASE",
				scale = scale,
				xAlignment = Enum.TextXAlignment.Left,
			},
		},
		{
			title = {
				text = " ACTIVE NAV DATA BASE",
				color = COLORS.white,
				padding = 0,
				font = "MCDU-LOWER-CASE",
				yPadding = -30,
				xPadding = 0,
				scale = scale,
				textSizeMultiplier = 1,
			},
			mainText = {
				text = "19MAR-15APR",
				color = COLORS.blue,
				padding = 0,
				font = "MCDU-UPPER-CASE",
				scale = scale,
			},
		},
		{
			title = {
				text = " SECOND NAV DATA BASE",
				color = COLORS.white,
				padding = 0,
				font = "MCDU-LOWER-CASE",
				yPadding = -30,
				xPadding = 0,
				scale = scale,
				textSizeMultiplier = 1,
			},
			mainText = {
				text = "£19MAR-15APR",
				color = COLORS.blue,
				padding = 0,
				font = "MCDU-LOWER-CASE",
				scale = scale,
			},
		},
		{},
		{
			title = {
				text = "CHG CODE",
				color = COLORS.white,
				padding = 0,
				font = "MCDU-LOWER-CASE",
				yPadding = -30,
				xPadding = 0,
				scale = scale,
				textSizeMultiplier = 1,
			},
			mainText = {
				text = "[ ]",
				color = COLORS.blue,
				padding = 0,
				font = "MCDU-LOWER-CASE",
				scale = scale,
			},
		},
		{
			title = {
				text = "CRZ FL/TEMP",
				color = COLORS.white,
				padding = 0,
				font = "MCDU-LOWER-CASE",
				yPadding = -30,
				xPadding = 0,
				scale = scale,
				textSizeMultiplier = 1,
			},
			mainText = {
				text = `FL190 /<font color="#{COLORS.orange:ToHex()}" face="MCDU-LOWER-CASE">-18°</font>`,
				color = COLORS.blue,
				padding = 0,
				font = "MCDU-UPPER-CASE",
				scale = scale,
			},
		},
	}

	local index = 1

	for _, line in lineSelects do
		local lineInfo = lineData[index]
		if lineInfo == nil then
			continue
		end

		if lineInfo.mainText then
			lineInfo.mainText.parent = line
		end
		if lineInfo.title then
			lineInfo.title.parent = line
		end
		renderFMGCText(lineInfo)

		index += 1
	end

	return function()
		maid:Destroy()
	end
end
