export type Vec2 = { x: number, y: number }

export type GlyphPoint = {
	x: number,
	y: number,
	onCurve: boolean,
}

export type Contour = { GlyphPoint }

export type GlyphInfo = {
	id: number,
	advance: number,
	lsb: number,
	xMin: number,
	yMin: number,
	xMax: number,
	yMax: number,
	contours: { Contour },
	isComposite: boolean,
}

export type FontMetrics = {
	unitsPerEm: number,
	ascender: number,
	descender: number,
	lineGap: number,
}

export type Font = {
	metrics: FontMetrics,
	glyphId: (self: Font, codepoint: number) -> number,
	glyphInfo: (self: Font, glyphId: number) -> GlyphInfo?,
	kernPair: (self: Font, leftId: number, rightId: number) -> number,
	scale: (self: Font, fontSize: number) -> number,
}

local function readU8(buf: buffer, offset: number): number
	return buffer.readu8(buf, offset)
end

local function readU16(buf: buffer, offset: number): number
	return buffer.readu8(buf, offset) * 256 + buffer.readu8(buf, offset + 1)
end

local function readI16(buf: buffer, offset: number): number
	local v = readU16(buf, offset)
	if v >= 0x8000 then
		v -= 0x10000
	end
	return v
end

local function readU32(buf: buffer, offset: number): number
	return readU16(buf, offset) * 0x10000 + readU16(buf, offset + 2)
end

local function readI8(buf: buffer, offset: number): number
	local v = readU8(buf, offset)
	if v >= 0x80 then
		v -= 0x100
	end
	return v
end

local function readF2Dot14(buf: buffer, offset: number): number
	return readI16(buf, offset) / 16384.0
end

type TableRecord = { offset: number, length: number }

local function parseTableDirectory(buf: buffer): { [string]: TableRecord }
	local numTables = readU16(buf, 4)
	local tables: { [string]: TableRecord } = {}
	for i = 0, numTables - 1 do
		local base = 12 + i * 16
		local tag = string.char(readU8(buf, base), readU8(buf, base + 1), readU8(buf, base + 2), readU8(buf, base + 3))
		local offset = readU32(buf, base + 8)
		local length = readU32(buf, base + 12)
		tables[tag] = { offset = offset, length = length }
	end
	return tables
end

type HeadTable = {
	unitsPerEm: number,
	indexToLocFormat: number,
}

local function parseHead(buf: buffer, offset: number): HeadTable
	return {
		unitsPerEm = readU16(buf, offset + 18),
		indexToLocFormat = readI16(buf, offset + 50),
	}
end

type HheaTable = {
	ascender: number,
	descender: number,
	lineGap: number,
	numberOfHMetrics: number,
}

local function parseHhea(buf: buffer, offset: number): HheaTable
	return {
		ascender = readI16(buf, offset + 4),
		descender = readI16(buf, offset + 6),
		lineGap = readI16(buf, offset + 8),
		numberOfHMetrics = readU16(buf, offset + 34),
	}
end

local function parseNumGlyphs(buf: buffer, offset: number): number
	return readU16(buf, offset + 4)
end

type HmtxEntry = { advance: number, lsb: number }

local function parseHmtx(buf: buffer, offset: number, numGlyphs: number, numberOfHMetrics: number): { HmtxEntry }
	local entries: { HmtxEntry } = table.create(numGlyphs)
	local lastAdvance = 0
	for i = 0, numGlyphs - 1 do
		local advance: number
		local lsb: number
		if i < numberOfHMetrics then
			advance = readU16(buf, offset + i * 4)
			lsb = readI16(buf, offset + i * 4 + 2)
			lastAdvance = advance
		else
			advance = lastAdvance
			local tailOffset = offset + numberOfHMetrics * 4 + (i - numberOfHMetrics) * 2
			lsb = readI16(buf, tailOffset)
		end
		entries[i + 1] = { advance = advance, lsb = lsb }
	end
	return entries
end

type CmapLookup = (codepoint: number) -> number

local function parseCmap(buf: buffer, offset: number): CmapLookup
	local numSubtables = readU16(buf, offset + 2)

	local best: number? = nil
	local bestPriority = -1

	for i = 0, numSubtables - 1 do
		local base = offset + 4 + i * 8
		local platform = readU16(buf, base)
		local encoding = readU16(buf, base + 2)
		local relOff = readU32(buf, base + 4)
		local fmt = readU16(buf, offset + relOff)

		if fmt == 4 then
			local priority = -1
			if platform == 3 and encoding == 1 then
				priority = 2
			elseif platform == 0 and encoding == 3 then
				priority = 1
			elseif platform == 0 then
				priority = 0
			end
			if priority > bestPriority then
				bestPriority = priority
				best = offset + relOff
			end
		end
	end

	if best == nil then
		return function(_cp: number): number
			return 0
		end
	end

	local p = best :: number

	local segCount2 = readU16(buf, p + 6)
	local segCount = segCount2 // 2
	p += 14

	local endCodes = table.create(segCount)
	local startCodes = table.create(segCount)
	local idDeltas = table.create(segCount)
	local idRangeOffs = table.create(segCount)

	for i = 1, segCount do
		endCodes[i] = readU16(buf, p)
		p += 2
	end
	p += 2
	for i = 1, segCount do
		startCodes[i] = readU16(buf, p)
		p += 2
	end
	for i = 1, segCount do
		idDeltas[i] = readI16(buf, p)
		p += 2
	end
	local idRangeOffBase = p
	for i = 1, segCount do
		idRangeOffs[i] = readU16(buf, p)
		p += 2
	end

	return function(codepoint: number): number
		local lo, hi = 1, segCount
		while lo <= hi do
			local mid = (lo + hi) // 2
			if codepoint < startCodes[mid] then
				hi = mid - 1
			elseif codepoint > endCodes[mid] then
				lo = mid + 1
			else
				local iro = idRangeOffs[mid]
				if iro == 0 then
					return (codepoint + idDeltas[mid]) % 0x10000
				else
					local glyphIdArrayIdx = idRangeOffBase + (mid - 1) * 2 + iro + (codepoint - startCodes[mid]) * 2
					local gid = readU16(buf, glyphIdArrayIdx)
					if gid == 0 then
						return 0
					end
					return (gid + idDeltas[mid]) % 0x10000
				end
			end
		end
		return 0
	end
end

local function parseKern(buf: buffer, offset: number, length: number): { [number]: number }
	local result: { [number]: number } = {}
	if length < 4 then
		return result
	end

	local version = readU16(buf, offset)
	local nTables = readU16(buf, offset + 2)
	if version ~= 0 then
		return result
	end

	local p = offset + 4
	for _ = 1, nTables do
		local stLength = readU16(buf, p + 2)
		local coverage = readU16(buf, p + 4)
		local fmt = bit32.rshift(coverage, 8)
		local isHoriz = bit32.band(coverage, 0x01) == 1
		local isCrossStr = bit32.band(coverage, 0x02) ~= 0

		if fmt == 0 and isHoriz and not isCrossStr then
			local nPairs = readU16(buf, p + 6)
			local pairBase = p + 14
			for i = 0, nPairs - 1 do
				local left = readU16(buf, pairBase + i * 6)
				local right = readU16(buf, pairBase + i * 6 + 2)
				local value = readI16(buf, pairBase + i * 6 + 4)
				result[left * 65536 + right] = value
			end
		end
		p += stLength
	end
	return result
end

local function makeLocaReader(buf: buffer, offset: number, fmt: number): (glyphId: number) -> number
	if fmt == 0 then
		return function(id: number): number
			return readU16(buf, offset + id * 2) * 2
		end
	else
		return function(id: number): number
			return readU32(buf, offset + id * 4)
		end
	end
end

local FLAG_ON_CURVE = 0x01
local FLAG_SHORT_X = 0x02
local FLAG_SHORT_Y = 0x04
local FLAG_REPEAT = 0x08
local FLAG_SAME_X = 0x10
local FLAG_SAME_Y = 0x20

local function parseSimpleGlyph(buf: buffer, glyfOff: number, nContours: number): { Contour }
	local p = glyfOff + 10

	local endPts = table.create(nContours)
	for i = 1, nContours do
		endPts[i] = readU16(buf, p)
		p += 2
	end
	local numPoints = endPts[nContours] + 1

	local instrLen = readU16(buf, p)
	p += 2 + instrLen

	local flags = table.create(numPoints)
	local i = 1
	while i <= numPoints do
		local f = readU8(buf, p)
		p += 1
		flags[i] = f
		if bit32.band(f, FLAG_REPEAT) ~= 0 then
			local rep = readU8(buf, p)
			p += 1
			for _ = 1, rep do
				i += 1
				flags[i] = f
			end
		end
		i += 1
	end

	local xs = table.create(numPoints)
	local cur = 0
	for idx = 1, numPoints do
		local f = flags[idx]
		if bit32.band(f, FLAG_SHORT_X) ~= 0 then
			local delta = readU8(buf, p)
			p += 1
			if bit32.band(f, FLAG_SAME_X) == 0 then
				delta = -delta
			end
			cur += delta
		elseif bit32.band(f, FLAG_SAME_X) ~= 0 then
		else
			cur += readI16(buf, p)
			p += 2
		end
		xs[idx] = cur
	end

	local ys = table.create(numPoints)
	cur = 0
	for idx = 1, numPoints do
		local f = flags[idx]
		if bit32.band(f, FLAG_SHORT_Y) ~= 0 then
			local delta = readU8(buf, p)
			p += 1
			if bit32.band(f, FLAG_SAME_Y) == 0 then
				delta = -delta
			end
			cur += delta
		elseif bit32.band(f, FLAG_SAME_Y) ~= 0 then
		else
			cur += readI16(buf, p)
			p += 2
		end
		ys[idx] = cur
	end

	local contours: { Contour } = table.create(nContours)
	local ptIdx = 1
	for c = 1, nContours do
		local contour: Contour = {}
		local endPt = endPts[c] + 1
		while ptIdx <= endPt do
			contour[#contour + 1] = {
				x = xs[ptIdx],
				y = ys[ptIdx],
				onCurve = bit32.band(flags[ptIdx], FLAG_ON_CURVE) ~= 0,
			}
			ptIdx += 1
		end
		contours[c] = contour
	end

	return contours
end

local COMP_ARG_1_AND_2_WORDS = 0x0001
local COMP_ARGS_ARE_XY = 0x0002
local COMP_WE_HAVE_SCALE = 0x0008
local COMP_MORE_COMPONENTS = 0x0020
local COMP_HAVE_X_AND_Y_SCALE = 0x0040
local COMP_HAVE_2x2 = 0x0080

local getGlyphContours: (buf: buffer, glyfBase: number, locaRead: (number) -> number, id: number) -> { Contour }

local function parseCompositeGlyph(
	buf: buffer,
	glyfBase: number,
	locaRead: (number) -> number,
	glyfOff: number
): { Contour }
	local allContours: { Contour } = {}
	local p = glyfOff + 10

	repeat
		local cFlags = readU16(buf, p)
		p += 2
		local compGlyph = readU16(buf, p)
		p += 2

		local dx, dy: number
		if bit32.band(cFlags, COMP_ARG_1_AND_2_WORDS) ~= 0 then
			dx = readI16(buf, p)
			p += 2
			dy = readI16(buf, p)
			p += 2
		else
			if bit32.band(cFlags, COMP_ARGS_ARE_XY) ~= 0 then
				dx = readI8(buf, p)
				p += 1
				dy = readI8(buf, p)
				p += 1
			else
				dx = 0
				dy = 0
				p += 2
			end
		end

		local xx, xy, yx, yy = 1.0, 0.0, 0.0, 1.0
		if bit32.band(cFlags, COMP_WE_HAVE_SCALE) ~= 0 then
			xx = readF2Dot14(buf, p)
			p += 2
			yy = xx
		elseif bit32.band(cFlags, COMP_HAVE_X_AND_Y_SCALE) ~= 0 then
			xx = readF2Dot14(buf, p)
			p += 2
			yy = readF2Dot14(buf, p)
			p += 2
		elseif bit32.band(cFlags, COMP_HAVE_2x2) ~= 0 then
			xx = readF2Dot14(buf, p)
			p += 2
			xy = readF2Dot14(buf, p)
			p += 2
			yx = readF2Dot14(buf, p)
			p += 2
			yy = readF2Dot14(buf, p)
			p += 2
		end

		local useXY = bit32.band(cFlags, COMP_ARGS_ARE_XY) ~= 0
		local subContours = getGlyphContours(buf, glyfBase, locaRead, compGlyph)

		for _, contour in ipairs(subContours) do
			local transformed: Contour = table.create(#contour)
			for pi, pt in ipairs(contour) do
				local ox = pt.x * xx + pt.y * yx + (useXY and dx or 0)
				local oy = pt.x * xy + pt.y * yy + (useXY and dy or 0)
				transformed[pi] = { x = ox, y = oy, onCurve = pt.onCurve }
			end
			allContours[#allContours + 1] = transformed
		end

	until bit32.band(cFlags, COMP_MORE_COMPONENTS) == 0

	return allContours
end

getGlyphContours = function(buf: buffer, glyfBase: number, locaRead: (number) -> number, id: number): { Contour }
	local off0 = locaRead(id)
	local off1 = locaRead(id + 1)
	if off0 == off1 then
		return {}
	end

	local glyfOff = glyfBase + off0
	local nContours = readI16(buf, glyfOff)

	if nContours > 0 then
		return parseSimpleGlyph(buf, glyfOff, nContours)
	elseif nContours == -1 then
		return parseCompositeGlyph(buf, glyfBase, locaRead, glyfOff)
	else
		return {}
	end
end

local TTFParser = {}

function TTFParser.evaluateContour(contour: Contour, stepsPerCurve: number?): { Vec2 }
	local steps = stepsPerCurve or 8
	local result: { Vec2 } = {}
	local n = #contour
	if n == 0 then
		return result
	end

	local function emitQuad(x0: number, y0: number, cx: number, cy: number, x1: number, y1: number)
		for s = 1, steps do
			local t = s / steps
			local mt = 1 - t
			result[#result + 1] = {
				x = mt * mt * x0 + 2 * mt * t * cx + t * t * x1,
				y = mt * mt * y0 + 2 * mt * t * cy + t * t * y1,
			}
		end
	end

	local function popIfDuplicateOfStart()
		local last = result[#result]
		local first = result[1]
		if math.abs(last.x - first.x) < 1e-6 and math.abs(last.y - first.y) < 1e-6 then
			result[#result] = nil
		end
	end

	local startIdx = -1
	for i = 1, n do
		if contour[i].onCurve then
			startIdx = i
			break
		end
	end

	if startIdx == -1 then
		local last = contour[n]
		local first = contour[1]
		local curX = (last.x + first.x) * 0.5
		local curY = (last.y + first.y) * 0.5
		result[#result + 1] = { x = curX, y = curY }

		local pcx: number? = nil
		local pcy: number? = nil
		for step = 1, n do
			local pt = contour[step]
			if pcx then
				local midX = (pcx :: number + pt.x) * 0.5
				local midY = (pcy :: number + pt.y) * 0.5
				emitQuad(curX, curY, pcx :: number, pcy :: number, midX, midY)
				curX, curY = midX, midY
			end
			pcx, pcy = pt.x, pt.y
		end
		emitQuad(curX, curY, pcx :: number, pcy :: number, result[1].x, result[1].y)
		popIfDuplicateOfStart()
		return result
	end

	local startPt = contour[startIdx]
	local curX, curY = startPt.x, startPt.y
	result[#result + 1] = { x = curX, y = curY }

	local pendingCtrlX: number? = nil
	local pendingCtrlY: number? = nil

	for step = 1, n - 1 do
		local idx = (startIdx - 1 + step) % n + 1
		local pt = contour[idx]

		if pt.onCurve then
			if pendingCtrlX then
				emitQuad(curX, curY, pendingCtrlX :: number, pendingCtrlY :: number, pt.x, pt.y)
				pendingCtrlX = nil
				pendingCtrlY = nil
			else
				result[#result + 1] = { x = pt.x, y = pt.y }
			end
			curX, curY = pt.x, pt.y
		else
			if pendingCtrlX then
				local midX = (pendingCtrlX :: number + pt.x) * 0.5
				local midY = (pendingCtrlY :: number + pt.y) * 0.5
				emitQuad(curX, curY, pendingCtrlX :: number, pendingCtrlY :: number, midX, midY)
				curX, curY = midX, midY
			end
			pendingCtrlX = pt.x
			pendingCtrlY = pt.y
		end
	end

	if pendingCtrlX then
		emitQuad(curX, curY, pendingCtrlX :: number, pendingCtrlY :: number, result[1].x, result[1].y)
		popIfDuplicateOfStart()
	end

	return result
end

function TTFParser.parse(buf: buffer): Font
	local tables = parseTableDirectory(buf)

	local sfVersion = readU32(buf, 0)
	local OTTO = 0x4F54544F
	local TYP1 = 0x74797031

	if sfVersion == OTTO then
		error(
			"TTFParser: this font uses OpenType/CFF outlines ('OTTO' format).\n"
				.. "CFF fonts store cubic BÃ©zier charstrings in a 'CFF ' table instead of\n"
				.. "the 'loca'+'glyf' tables that TTFParser reads.\n"
				.. "To use this font, convert it to TrueType outlines first:\n"
				.. "  fonttools: fonttools convert MyFont.otf MyFont.ttf\n"
				.. "  or use a .ttf variant of the font if the foundry provides one.",
			2
		)
	end

	if sfVersion == TYP1 then
		error("TTFParser: PostScript Type 1 fonts ('typ1') are not supported. Use a .ttf file.", 2)
	end

	if tables["CBDT"] or tables["CBLC"] or tables["sbix"] then
		warn(
			"TTFParser: this font contains color bitmap glyphs (CBDT/CBLC/sbix). "
				.. "Outline rendering is not available for these glyphs; they will appear "
				.. "invisible. Only glyphs with TrueType outlines in the 'glyf' table will render."
		)
	end

	if not tables["glyf"] then
		local hint = if tables["CFF "] or tables["CFF2"]
			then " (this font uses CFF outlines â€” see the OTTO error above)"
			else " (no 'glyf' table found; the file may be corrupt or an unsupported format)"
		error("TTFParser: cannot parse font â€” missing 'glyf' table." .. hint, 2)
	end

	if not tables["loca"] then
		error(
			"TTFParser: cannot parse font â€” 'glyf' table is present but 'loca' index is missing.\n"
				.. "This is unusual and typically indicates a malformed font file.",
			2
		)
	end

	local function requireTable(tag: string): TableRecord
		local t = tables[tag]
		assert(t, `TTFParser: required table '{tag}' not found in font`)
		return t
	end

	local headRec = requireTable("head")
	local hheaRec = requireTable("hhea")
	local maxpRec = requireTable("maxp")
	local hmtxRec = requireTable("hmtx")
	local cmapRec = requireTable("cmap")
	local locaRec = requireTable("loca")
	local glyfRec = requireTable("glyf")

	local headT = parseHead(buf, headRec.offset)
	local hheaT = parseHhea(buf, hheaRec.offset)
	local numGlyphs = parseNumGlyphs(buf, maxpRec.offset)
	local hmtx = parseHmtx(buf, hmtxRec.offset, numGlyphs, hheaT.numberOfHMetrics)
	local cmapLookup = parseCmap(buf, cmapRec.offset)
	local locaRead = makeLocaReader(buf, locaRec.offset, headT.indexToLocFormat)
	local glyfBase = glyfRec.offset

	local kernMap: { [number]: number } = {}
	if tables["kern"] then
		local k = tables["kern"]
		kernMap = parseKern(buf, k.offset, k.length)
	end

	local glyphCache: { [number]: GlyphInfo } = {}

	local font: Font = {} :: any

	function font:glyphId(codepoint: number): number
		return cmapLookup(codepoint)
	end

	function font:glyphInfo(id: number): GlyphInfo?
		if id < 0 or id >= numGlyphs then
			return nil
		end

		if glyphCache[id] then
			return glyphCache[id]
		end

		local off0 = locaRead(id)
		local off1 = locaRead(id + 1)
		local isEmpty = (off0 == off1)

		local nContours = 0
		local xMin, yMin, xMax, yMax = 0, 0, 0, 0

		if not isEmpty then
			local glyfOff = glyfBase + off0
			nContours = readI16(buf, glyfOff)
			xMin = readI16(buf, glyfOff + 2)
			yMin = readI16(buf, glyfOff + 4)
			xMax = readI16(buf, glyfOff + 6)
			yMax = readI16(buf, glyfOff + 8)
		end

		local hmtxEntry = hmtx[id + 1]
		local contours = getGlyphContours(buf, glyfBase, locaRead, id)

		local info: GlyphInfo = {
			id = id,
			advance = hmtxEntry and hmtxEntry.advance or 0,
			lsb = hmtxEntry and hmtxEntry.lsb or 0,
			xMin = xMin,
			yMin = yMin,
			xMax = xMax,
			yMax = yMax,
			contours = contours,
			isComposite = nContours == -1,
		}

		glyphCache[id] = info
		return info
	end

	function font:kernPair(leftId: number, rightId: number): number
		return kernMap[leftId * 65536 + rightId] or 0
	end

	function font:scale(fontSize: number): number
		return fontSize / font.metrics.unitsPerEm
	end

	font.metrics = {
		unitsPerEm = headT.unitsPerEm,
		ascender = hheaT.ascender,
		descender = hheaT.descender,
		lineGap = hheaT.lineGap,
	}

	return font
end

function TTFParser.measureText(font: Font, text: string, fontSize: number): number
	local scale = font:scale(fontSize)
	local width = 0
	local prevId: number? = nil

	local utf8 = utf8

	for _, codepoint in utf8.codes(text) do
		local gid = font:glyphId(codepoint)
		local info = font:glyphInfo(gid)
		if info then
			if prevId then
				width += font:kernPair(prevId, gid) * scale
			end
			width += info.advance * scale
			prevId = gid
		end
	end
	return width
end

return TTFParser
