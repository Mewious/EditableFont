local TTFParser = require(script.Parent.TTFParser)

local AssetService = game:GetService("AssetService")

local ATLAS_WIDTH = 1024
local ATLAS_HEIGHT = 1024

local PAD = 1

local SUB_OFFSETS = { 0.125, 0.375, 0.625, 0.875 }
local SUB_WEIGHT = 0.25

export type GlyphEntry = {
	glyphId: number,
	rectOffset: Vector2,
	rectSize: Vector2,
	advance: number,
	bearingX: number,
	bearingY: number,
}

export type AtlasResult = {
	image: EditableImage,
	glyphs: { [number]: GlyphEntry },
	fontSize: number,
	cellH: number,
	bearingY: number,
	font: TTFParser.Font,
	weight: number,
}

local function fillGlyphAlphaMask(
	pixels: buffer,
	cellW: number,
	cellH: number,
	polys: { { TTFParser.Vec2 } },
	weight: number
)
	local yMin, yMax = math.huge, -math.huge
	for _, poly in ipairs(polys) do
		for _, p in ipairs(poly) do
			if p.y < yMin then
				yMin = p.y
			end
			if p.y > yMax then
				yMax = p.y
			end
		end
	end
	yMin = math.max(0, math.floor(yMin) - 1)
	yMax = math.min(cellH - 1, math.floor(yMax) + 1)

	local xs: { number } = {}
	local dirs: { number } = {}
	local coverage: { number } = table.create(cellW, 0)

	local function insertSorted(nxs: number, x: number, d: number): number
		local i = nxs
		while i >= 1 and xs[i] > x do
			xs[i + 1] = xs[i]
			dirs[i + 1] = dirs[i]
			i -= 1
		end
		xs[i + 1] = x
		dirs[i + 1] = d
		return nxs + 1
	end

	local function getCrossings(yf: number): number
		local nxs = 0
		for _, poly in ipairs(polys) do
			local n = #poly
			for i = 1, n do
				local p1 = poly[i]
				local p2 = poly[(i % n) + 1]
				local y1, y2 = p1.y, p2.y
				if (y1 < yf and y2 >= yf) or (y2 < yf and y1 >= yf) then
					local x = p1.x + (yf - y1) / (y2 - y1) * (p2.x - p1.x)
					local d = if y1 < y2 then 1 else -1
					nxs = insertSorted(nxs, x, d)
				end
			end
		end
		while #xs > nxs do
			xs[#xs] = nil
		end
		while #dirs > nxs do
			dirs[#dirs] = nil
		end
		return nxs
	end

	for y = yMin, yMax do
		for x = 0, cellW - 1 do
			coverage[x + 1] = 0
		end

		for _, subOff in ipairs(SUB_OFFSETS) do
			local nxs = getCrossings(y + subOff)

			local winding = 0
			local spanStartX: number? = nil
			local halfW = weight * 0.5

			for i = 1, nxs do
				local prevWinding = winding
				winding += dirs[i]
				if prevWinding == 0 and winding ~= 0 then
					spanStartX = xs[i] - halfW
				elseif prevWinding ~= 0 and winding == 0 then
					local x0f = spanStartX :: number
					local x1f = xs[i] + halfW
					local px0 = math.max(0, math.floor(x0f))
					local px1 = math.min(cellW - 1, math.floor(x1f))
					for px = px0, px1 do
						local left = if x0f > px then x0f else px
						local right = if x1f < px + 1 then x1f else px + 1
						if right > left then
							coverage[px + 1] += (right - left) * SUB_WEIGHT
						end
					end
					spanStartX = nil
				end
			end
		end

		for px = 0, cellW - 1 do
			local alpha = coverage[px + 1]
			if alpha > 0.004 then
				if alpha > 1 then
					alpha = 1
				end
				local idx = (y * cellW + px) * 4
				local a8 = if alpha >= 0.996 then 255 else math.round(alpha * 255)
				buffer.writeu8(pixels, idx, 255)
				buffer.writeu8(pixels, idx + 1, 255)
				buffer.writeu8(pixels, idx + 2, 255)
				buffer.writeu8(pixels, idx + 3, a8)
			end
		end
	end

	if weight > 0 then
		local halfW = weight * 0.5
		local radius = math.ceil(halfW)
		local colBuf: { number } = table.create(cellH, 0)

		for px = 0, cellW - 1 do
			for y = 0, cellH - 1 do
				local idx = (y * cellW + px) * 4 + 3
				colBuf[y + 1] = buffer.readu8(pixels, idx)
			end

			for y = 0, cellH - 1 do
				local maxA = colBuf[y + 1]
				for dy = 1, radius do
					local contrib = if dy <= math.floor(halfW) then 1.0 else (halfW - math.floor(halfW))
					if y - dy >= 0 then
						local v = colBuf[y - dy + 1]
						local scaled = math.round(v * contrib)
						if scaled > maxA then
							maxA = scaled
						end
					end
					if y + dy <= cellH - 1 then
						local v = colBuf[y + dy + 1]
						local scaled = math.round(v * contrib)
						if scaled > maxA then
							maxA = scaled
						end
					end
				end

				local idx = (y * cellW + px) * 4
				if maxA > 0 then
					buffer.writeu8(pixels, idx, 255)
					buffer.writeu8(pixels, idx + 1, 255)
					buffer.writeu8(pixels, idx + 2, 255)
					buffer.writeu8(pixels, idx + 3, maxA)
				end
			end
		end
	end
end

local function bake(font: TTFParser.Font, fontSize: number, charset: { number }?, weight: number?): AtlasResult
	local resolvedWeight = weight or 0
	local weightPadV = math.ceil(resolvedWeight * 0.5)
	local scale = font:scale(fontSize)
	local metrics = font.metrics
	local ascenderPx = math.ceil(metrics.ascender * scale)
	local descenderPx = math.ceil(-metrics.descender * scale)
	local cellH = ascenderPx + descenderPx + PAD * 2 + weightPadV * 2
	local bearingY = ascenderPx + PAD + weightPadV

	local codepoints: { number } = charset
		or (function()
			local cp: { number } = {}
			for c = 0x20, 0x7E do
				cp[#cp + 1] = c
			end
			return cp
		end)()

	local glyphIds: { number } = {}
	local seen: { [number]: boolean } = {}
	for _, cp in ipairs(codepoints) do
		local gid = font:glyphId(cp)
		if not seen[gid] then
			seen[gid] = true
			glyphIds[#glyphIds + 1] = gid
		end
	end

	type CellPlan = {
		gid: number,
		cellW: number,
		originPx: number,
		atlasX: number,
		atlasY: number,
	}

	local plan: { CellPlan } = {}
	local curX = 0
	local curY = 0

	for _, gid in ipairs(glyphIds) do
		local info = font:glyphInfo(gid)
		local originPx, cellW
		local weightPad = math.ceil(resolvedWeight * 0.5)
		if info then
			local advPx = math.ceil(info.advance * scale)
			local leftShift = math.max(0, math.ceil(-info.xMin * scale))
			local rightExt = math.max(math.ceil(info.xMax * scale), advPx)
			originPx = PAD + leftShift + weightPad
			cellW = math.max(1, originPx + rightExt + weightPad + PAD)
		else
			originPx = PAD + weightPad
			cellW = math.max(1, PAD * 2 + weightPad * 2)
		end

		if curX + cellW > ATLAS_WIDTH then
			curX = 0
			curY += cellH
		end

		plan[#plan + 1] = {
			gid = gid,
			cellW = cellW,
			originPx = originPx,
			atlasX = curX,
			atlasY = curY,
		}
		curX += cellW
	end

	local atlasH = math.min(curY + cellH, ATLAS_HEIGHT)

	local atlas: EditableImage = AssetService:CreateEditableImage({
		Size = Vector2.new(ATLAS_WIDTH, atlasH),
	})

	do
		local blank = buffer.create(ATLAS_WIDTH * atlasH * 4)
		atlas:WritePixelsBuffer(Vector2.zero, Vector2.new(ATLAS_WIDTH, atlasH), blank)
	end

	local glyphEntries: { [number]: GlyphEntry } = {}

	for _, cell in ipairs(plan) do
		local gid = cell.gid
		local info = font:glyphInfo(gid)

		glyphEntries[gid] = {
			glyphId = gid,
			rectOffset = Vector2.new(cell.atlasX, cell.atlasY),
			rectSize = Vector2.new(cell.cellW, cellH),
			advance = if info then info.advance * scale else 0,
			bearingX = -cell.originPx,
			bearingY = bearingY,
		}

		if not info or #info.contours == 0 then
			continue
		end

		local cellPixels = buffer.create(cell.cellW * cellH * 4)

		local screenPolys: { { TTFParser.Vec2 } } = {}

		for _, contour in ipairs(info.contours) do
			local polyline = TTFParser.evaluateContour(contour, 8)
			local screenPoly: { TTFParser.Vec2 } = table.create(#polyline) :: { TTFParser.Vec2 }
			for i, pt in ipairs(polyline) do
				screenPoly[i] = {
					x = cell.originPx + pt.x * scale,
					y = bearingY - pt.y * scale,
				}
			end
			screenPolys[#screenPolys + 1] = screenPoly
		end

		fillGlyphAlphaMask(cellPixels, cell.cellW, cellH, screenPolys, resolvedWeight)

		local cellImage: EditableImage = AssetService:CreateEditableImage({
			Size = Vector2.new(cell.cellW, cellH),
		})
		cellImage:WritePixelsBuffer(Vector2.zero, Vector2.new(cell.cellW, cellH), cellPixels)

		atlas:DrawImage(Vector2.new(cell.atlasX, cell.atlasY), cellImage, Enum.ImageCombineType.AlphaBlend)
	end

	return {
		image = atlas,
		glyphs = glyphEntries,
		fontSize = fontSize,
		cellH = cellH,
		bearingY = bearingY,
		font = font,
		weight = resolvedWeight,
		destroy = function()
			atlas:Destroy()
		end,
	}
end

local LABEL_TAG = "__FontAtlasGlyph__"
local LABEL_IMAGE_NAME = "Image"

local function getOrCreateGlyphSlot(frame: Frame, index: number, atlasContent: any): (Frame, ImageLabel)
	local name = LABEL_TAG .. tostring(index)
	local existing = frame:FindFirstChild(name)
	local slot: Frame

	if existing and existing:IsA("Frame") then
		slot = existing :: Frame
	else
		if existing then
			existing:Destroy()
		end

		slot = Instance.new("Frame")
		slot.Name = name
		slot.BackgroundTransparency = 1
		slot.BorderSizePixel = 0
		slot.ClipsDescendants = false
		slot.Parent = frame
	end

	local existingLabel = slot:FindFirstChild(LABEL_IMAGE_NAME)
	local label: ImageLabel
	if existingLabel and existingLabel:IsA("ImageLabel") then
		label = existingLabel :: ImageLabel
	else
		if existingLabel then
			existingLabel:Destroy()
		end

		label = Instance.new("ImageLabel")
		label.Name = LABEL_IMAGE_NAME
		label.BackgroundTransparency = 1
		label.BorderSizePixel = 0
		label.ImageContent = atlasContent
		label.ScaleType = Enum.ScaleType.Crop
		label.Parent = slot
	end

	label.ImageContent = atlasContent
	return slot, label
end

local function hideLabelsFrom(frame: Frame, fromIndex: number)
	local i = fromIndex
	while true do
		local child = frame:FindFirstChild(LABEL_TAG .. tostring(i))
		if not child then
			break
		end
		(child :: GuiObject).Visible = false
		i += 1
	end
end

local function getScaledGlyphPosition(entry: GlyphEntry, baselineY: number, textSizeMultiplier: number): Vector2
	local scaledWidth = math.max(1, math.round(entry.rectSize.X * textSizeMultiplier))
	local unscaledTop = baselineY - entry.bearingY
	local scaledHeight = math.max(1, math.round(entry.rectSize.Y * textSizeMultiplier))
	local centerPivotLeft = entry.bearingX + entry.rectSize.X * 0.5 - scaledWidth * 0.5
	local bottomPivotTop = unscaledTop + entry.rectSize.Y - scaledHeight

	return Vector2.new(math.round(centerPivotLeft), math.round(bottomPivotTop))
end

local function measureText(atlas: AtlasResult, text: string): number
	local font = atlas.font
	local scale = font:scale(atlas.fontSize)
	local width = 0
	local prevId: number? = nil

	for _, cp in utf8.codes(text) do
		local gid = font:glyphId(cp)
		local entry = atlas.glyphs[gid]
		if entry then
			if prevId then
				width += font:kernPair(prevId, gid) * scale
			end
			width += entry.advance
			prevId = gid
		end
	end
	return width
end

local function newTextLine(config: {
	atlas: AtlasResult,
	textData: {
		{
			text: string,
			color: Color3?,
			padding: number?,
			atlas: AtlasResult?,
			transparency: number?,
			textSizeMultiplier: number?,
		}
	},
	color: Color3?,
	baseline: number?,
	padding: number?,
	fillDirection: Enum.FillDirection?,
	scale: number?,
	textSizeMultiplier: number?,
}): Frame
	local tint = config.color or Color3.new(1, 1, 1)
	local baselineY = config.baseline or config.atlas.bearingY
	local textSizeMultiplier = config.textSizeMultiplier or 1

	local prevId: number? = nil
	local prevAtlas: AtlasResult? = nil
	local labelIndex = 1

	local masterFrame = Instance.new("Frame")
	masterFrame.BackgroundTransparency = 1
	masterFrame.ClipsDescendants = false
	masterFrame.AutomaticSize = Enum.AutomaticSize.XY
	masterFrame.Size = UDim2.fromOffset(0, 0)

	local uiListLayout = Instance.new("UIListLayout")
	uiListLayout.FillDirection = config.fillDirection or Enum.FillDirection.Horizontal
	uiListLayout.SortOrder = Enum.SortOrder.LayoutOrder
	uiListLayout.Padding = UDim.new(0, config.padding or 0)
	uiListLayout.Parent = masterFrame

	for _, segment in config.textData do
		local text = segment.text
		local color = segment.color or tint
		local padding = segment.padding or 0
		local segmentAtlas = segment.atlas or config.atlas
		local segmentTransparency = math.clamp(segment.transparency or 0, 0, 1)
		local segmentTextSizeMultiplier = segment.textSizeMultiplier or textSizeMultiplier
		local atlasContent = Content.fromObject(segmentAtlas.image)
		local font = segmentAtlas.font
		local scale = font:scale(segmentAtlas.fontSize)

		if prevAtlas ~= segmentAtlas then
			prevId = nil
			prevAtlas = segmentAtlas
		end

		local frame = Instance.new("Frame")
		frame.BackgroundTransparency = 1
		frame.ClipsDescendants = false
		frame.AutomaticSize = Enum.AutomaticSize.XY
		frame.Parent = masterFrame

		local listLayout = Instance.new("UIListLayout")
		listLayout.FillDirection = config.fillDirection or Enum.FillDirection.Horizontal
		listLayout.SortOrder = Enum.SortOrder.LayoutOrder
		listLayout.VerticalAlignment = Enum.VerticalAlignment.Center
		listLayout.Padding = UDim.new(0, padding)
		listLayout.Parent = frame

		for _, cp in utf8.codes(text) do
			local gid = font:glyphId(cp)
			local entry = segmentAtlas.glyphs[gid]
			if not entry then
				warn(string.format("Glyph not found in atlas for codepoint U+%04X", cp))
				continue
			end

			local kernBefore = if prevId then font:kernPair(prevId, gid) * scale else 0
			local slotWidth = math.max(0, math.round(kernBefore + entry.advance))
			if prevId then
				prevId = prevId
			end

			local info = font:glyphInfo(gid)
			local slot, label = getOrCreateGlyphSlot(frame, labelIndex, atlasContent)
			slot.Size = UDim2.fromOffset(slotWidth, segmentAtlas.cellH)
			slot.LayoutOrder = labelIndex
			if info and #info.contours > 0 then
				label.ImageTransparency = segmentTransparency
				label.ImageColor3 = color
				label.ImageRectOffset = entry.rectOffset
				label.ImageRectSize = entry.rectSize
				local glyphPosition = getScaledGlyphPosition(entry, baselineY, segmentTextSizeMultiplier)
				label.Size = UDim2.fromOffset(
					math.max(1, math.round(entry.rectSize.X * segmentTextSizeMultiplier)),
					math.max(1, math.round(entry.rectSize.Y * segmentTextSizeMultiplier))
				)
				label.Position = UDim2.fromOffset(glyphPosition.X, glyphPosition.Y)
				label.Visible = true
			else
				label.Visible = false
				label.ImageRectOffset = Vector2.zero
				label.ImageRectSize = Vector2.zero
				label.Size = UDim2.fromOffset(0, 0)
				label.Position = UDim2.fromOffset(0, 0)
			end
			slot.Visible = true
			labelIndex += 1

			prevId = gid
		end

		hideLabelsFrom(frame, labelIndex)
	end

	if config.scale then
		local uiScale = Instance.new("UIScale")
		uiScale.Scale = config.scale
		uiScale.Parent = masterFrame
	end

	hideLabelsFrom(masterFrame, labelIndex)

	return masterFrame
end

local function updateTextLine(
	frame: Frame,
	atlas: AtlasResult,
	text: string,
	color: Color3?,
	baseline: number?,
	padding: number?,
	textSizeMultiplier: number?
)
	local atlasContent = Content.fromObject(atlas.image)
	local baselineY = baseline or atlas.bearingY
	local sizeMultiplier = textSizeMultiplier or 1
	local font = atlas.font
	local scale = font:scale(atlas.fontSize)
	local prevId: number? = nil
	local labelIndex = 1

	for _, cp in utf8.codes(text) do
		local gid = font:glyphId(cp)
		local entry = atlas.glyphs[gid]
		if not entry then
			warn(string.format("Glyph not found in atlas for codepoint U+%04X", cp))
			continue
		end

		local kernBefore = if prevId then font:kernPair(prevId, gid) * scale else 0
		local slotWidth = math.max(0, math.round(kernBefore + entry.advance))
		if prevId then
			prevId = prevId
		end

		local info = font:glyphInfo(gid)
		local slot, label = getOrCreateGlyphSlot(frame, labelIndex, atlasContent)
		slot.Size = UDim2.fromOffset(slotWidth, atlas.cellH)
		slot.LayoutOrder = labelIndex
		if info and #info.contours > 0 then
			label.ImageTransparency = 0
			if color then
				label.ImageColor3 = color
			end
			label.ImageRectOffset = entry.rectOffset
			label.ImageRectSize = entry.rectSize
			local glyphPosition = getScaledGlyphPosition(entry, baselineY, sizeMultiplier)
			label.Size = UDim2.fromOffset(
				math.max(1, math.round(entry.rectSize.X * sizeMultiplier)),
				math.max(1, math.round(entry.rectSize.Y * sizeMultiplier))
			)
			label.Position = UDim2.fromOffset(glyphPosition.X, glyphPosition.Y)
			label.Visible = true
		else
			label.Visible = false
			label.ImageRectOffset = Vector2.zero
			label.ImageRectSize = Vector2.zero
			label.Size = UDim2.fromOffset(0, 0)
			label.Position = UDim2.fromOffset(0, 0)
		end
		slot.Visible = true
		labelIndex += 1

		prevId = gid
	end

	local listLayout = frame:FindFirstChildOfClass("UIListLayout")
	if not listLayout then
		listLayout = Instance.new("UIListLayout")
		listLayout.FillDirection = Enum.FillDirection.Horizontal
		listLayout.SortOrder = Enum.SortOrder.LayoutOrder
		listLayout.Padding = UDim.new(0, padding or 0)
		listLayout.Parent = frame
	end

	hideLabelsFrom(frame, labelIndex)

	local totalWidth = math.max(1, math.round(measureText(atlas, text)))
	frame.Size = UDim2.fromOffset(totalWidth, atlas.cellH)
end

return {
	bake = bake,
	measureText = measureText,
	newTextLine = newTextLine,
	updateTextLine = updateTextLine,
}
