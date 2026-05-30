local FontAtlas = require(script.FontAtlas)
local TTFParser = require(script.TTFParser)

type RenderSegment = {
	text: string,
	color: Color3?,
	padding: number?,
	atlas: FontAtlas.AtlasResult,
	transparency: number?,
	textSizeMultiplier: number?,
}

type RichTextSegment = {
	text: string,
	color: Color3?,
	padding: number?,
	transparency: number?,
	textSizeMultiplier: number?,
}

type RichTextValue = string | { RichTextSegment }

type RichTextStyle = {
	color: Color3,
	padding: number,
	transparency: number,
	textSizeMultiplier: number,
}

type RenderConfig = {
	text: RichTextValue,
	fontSize: number?,
	charset: { number }?,
	color: Color3?,
	padding: number?,
	baseline: number?,
	fillDirection: Enum.FillDirection?,
	scale: number?,
	textSizeMultiplier: number?,
	xAlignment: Enum.TextXAlignment?,
	position: UDim2?,
	anchorPoint: Vector2?,
	xPadding: number?,
	yPadding: number?,
	parent: Instance?,
	fontWeight: number?,
}

type EditableFontInstance = typeof(setmetatable(
	{} :: {
		font: TTFParser.Font,
		defaultCharset: { number }?,
		defaultFontSize: number,
		atlasCache: { [string]: FontAtlas.AtlasResult },
		lineConfigs: { [Frame]: RenderConfig },
	},
	{} :: any
))

local EditableFont = {}
EditableFont.__index = EditableFont

local DEFAULT_FONT_SIZE = 100

local RICH_TEXT_ENTITY_MAP = {
	amp = "&",
	lt = "<",
	gt = ">",
	quot = '"',
	apos = "'",
}

local function cloneStyle(style: RichTextStyle): RichTextStyle
	return {
		color = style.color,
		padding = style.padding,
		transparency = style.transparency,
		textSizeMultiplier = style.textSizeMultiplier,
	}
end

local function copyCharset(charset: { number }?): { number }?
	if not charset then
		return nil
	end

	local result = table.create(#charset)
	for index, codepoint in charset do
		result[index] = codepoint
	end
	return result
end

local function charsetCacheKey(charset: { number }?): string
	if not charset then
		return "default"
	end

	local parts = table.create(#charset)
	for index, codepoint in charset do
		parts[index] = tostring(codepoint)
	end
	return table.concat(parts, ",")
end

local function cloneRenderConfig(config: RenderConfig): RenderConfig
	return {
		text = if type(config.text) == "string" then config.text else table.clone(config.text),
		fontSize = config.fontSize,
		charset = copyCharset(config.charset),
		color = config.color,
		padding = config.padding,
		baseline = config.baseline,
		fillDirection = config.fillDirection,
		scale = config.scale,
		textSizeMultiplier = config.textSizeMultiplier,
		xAlignment = config.xAlignment,
		position = config.position,
		anchorPoint = config.anchorPoint,
		xPadding = config.xPadding,
		yPadding = config.yPadding,
		parent = config.parent,
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

	if value:match("^[%x][%x][%x][%x][%x][%x]$") then
		value = "#" .. value
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
	for key, _, value in attributeSource:gmatch("([%w:_-]+)%s*=%s*(['\"])(.-)%2") do
		attributes[string.lower(key)] = decodeRichTextEntities(value)
	end
	return attributes
end

local function getAlignmentLayout(xAlignment: Enum.TextXAlignment?): (UDim2, Vector2)
	if xAlignment == Enum.TextXAlignment.Center then
		return UDim2.fromScale(0.5, 0.5), Vector2.new(0.5, 0.5)
	elseif xAlignment == Enum.TextXAlignment.Right then
		return UDim2.fromScale(1, 0.5), Vector2.new(1, 0.5)
	end

	return UDim2.fromScale(0, 0.5), Vector2.new(0, 0.5)
end

local function clearManagedChildren(frame: Frame)
	for _, child in frame:GetChildren() do
		child:Destroy()
	end
end

local function appendRenderSegment(
	self: EditableFontInstance,
	segments: { RenderSegment },
	text: string,
	style: RichTextStyle,
	atlas: FontAtlas.AtlasResult
)
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
		atlas = atlas,
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

function EditableFont:_getAtlas(fontSize: number?, charset: { number }?, fontWeight: number?): FontAtlas.AtlasResult
	local resolvedFontSize = fontSize or self.defaultFontSize
	local resolvedCharset = charset or self.defaultCharset
	local resolvedWeight = fontWeight or 0
	local key = string.format("%d:%g:%s", resolvedFontSize, resolvedWeight, charsetCacheKey(resolvedCharset))
	local atlas = self.atlasCache[key]
	if atlas then
		return atlas
	end

	atlas = FontAtlas.bake(self.font, resolvedFontSize, resolvedCharset, resolvedWeight)
	self.atlasCache[key] = atlas
	return atlas
end

function EditableFont:_normalizeRichText(text: RichTextValue, config: RenderConfig): { RenderSegment }
	local defaultColor = config.color or Color3.new(1, 1, 1)
	local defaultPadding = config.padding or 0
	local atlas = self:_getAtlas(config.fontSize, config.charset, config.fontWeight)
	local defaultTextSizeMultiplier = config.textSizeMultiplier or 1

	if type(text) ~= "string" then
		local segments: { RenderSegment } = {}
		for _, segment in text do
			segments[#segments + 1] = {
				text = segment.text,
				color = segment.color or defaultColor,
				padding = if segment.padding ~= nil then segment.padding else defaultPadding,
				atlas = atlas,
				transparency = math.clamp(segment.transparency or 0, 0, 1),
				textSizeMultiplier = segment.textSizeMultiplier or defaultTextSizeMultiplier,
			}
		end
		return segments
	end

	local defaultStyle: RichTextStyle = {
		color = defaultColor,
		padding = defaultPadding,
		transparency = 0,
		textSizeMultiplier = defaultTextSizeMultiplier,
	}
	local styleStack: { { tagName: string, style: RichTextStyle } } = {
		{ tagName = "root", style = defaultStyle },
	}
	local segments: { RenderSegment } = {}
	local cursor = 1

	while true do
		local startIndex, endIndex = text:find("<[^>]+>", cursor)
		if not startIndex then
			appendRenderSegment(self, segments, text:sub(cursor), styleStack[#styleStack].style, atlas)
			break
		end

		appendRenderSegment(self, segments, text:sub(cursor, startIndex - 1), styleStack[#styleStack].style, atlas)

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
			appendRenderSegment(self, segments, "\n", styleStack[#styleStack].style, atlas)
		elseif tagName ~= "" then
			local nextStyle = cloneStyle(styleStack[#styleStack].style)
			if tagName == "font" then
				local attributes = parseRichTextAttributes(attributeSource)
				local color = attributes.color and parseRichTextColor(attributes.color)
				if color then
					nextStyle.color = color
				end

				local transparency = tonumber(attributes.transparency or "")
				if transparency then
					nextStyle.transparency = math.clamp(transparency, 0, 1)
				end

				local size = tonumber(attributes.size or "")
				if size and size > 0 then
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

function EditableFont:_applyAlignment(frame: Frame, config: RenderConfig)
	local defaultPosition, defaultAnchorPoint = getAlignmentLayout(config.xAlignment)
	frame.Position = config.position
		or UDim2.new(
			defaultPosition.X.Scale,
			defaultPosition.X.Offset + (config.xPadding or 0),
			defaultPosition.Y.Scale,
			defaultPosition.Y.Offset + (config.yPadding or 0)
		)
	frame.AnchorPoint = config.anchorPoint or defaultAnchorPoint
end

function EditableFont:_renderInto(frame: Frame, config: RenderConfig)
	clearManagedChildren(frame)
	frame.BackgroundTransparency = 1
	frame.ClipsDescendants = false
	frame.AutomaticSize = Enum.AutomaticSize.XY
	frame.Size = UDim2.fromOffset(0, 0)

	local atlas = self:_getAtlas(config.fontSize, config.charset, config.fontWeight)
	local line = FontAtlas.newTextLine({
		atlas = atlas,
		textData = self:_normalizeRichText(config.text, config),
		color = config.color,
		baseline = config.baseline,
		padding = config.padding,
		fillDirection = config.fillDirection,
		scale = config.scale,
		textSizeMultiplier = config.textSizeMultiplier,
	})

	for _, child in line:GetChildren() do
		child.Parent = frame
	end
	line:Destroy()
	self:_applyAlignment(frame, config)
	self.lineConfigs[frame] = cloneRenderConfig(config)
end

function EditableFont.new(data: buffer, fontSize: number?, charset: { number }?)
	local self = setmetatable({}, EditableFont)
	self.font = TTFParser.parse(data)
	self.defaultCharset = copyCharset(charset)
	self.defaultFontSize = fontSize or DEFAULT_FONT_SIZE
	self.atlasCache = {}
	self.lineConfigs = {}
	return self
end

function EditableFont:renderText(config: RenderConfig): Frame
	local frame = Instance.new("Frame")
	self:_renderInto(frame, config)
	if config.parent then
		frame.Parent = config.parent
	end
	return frame
end

function EditableFont:updateText(frame: Frame, config: RenderConfig)
	local previousConfig = self.lineConfigs[frame]
	local nextConfig = if previousConfig then cloneRenderConfig(previousConfig) else {}
	for key, value in config do
		nextConfig[key] = value
	end
	self:_renderInto(frame, nextConfig :: RenderConfig)
	if nextConfig.parent and frame.Parent ~= nextConfig.parent then
		frame.Parent = nextConfig.parent
	end
	return frame
end

function EditableFont:getAtlas(fontSize: number?, charset: { number }?, fontWeight: number?)
	return self:_getAtlas(fontSize, charset, fontWeight)
end

function EditableFont:destroy()
	for _, atlas in self.atlasCache do
		if atlas.destroy then
			atlas.destroy()
		end
	end
	table.clear(self.atlasCache)
	table.clear(self.lineConfigs)
end

return EditableFont
