# EditableFont

A pure-Luau TrueType font parser and renderer for Roblox, powered by `EditableImage`. Parses `.ttf` binaries at runtime, bakes glyph atlases, and renders text via `ImageLabel` — no asset uploads required.

## Features

- **TTF Parsing** — Reads TrueType font files directly from a buffer. Supports simple and composite glyphs, kerning pairs, and Unicode BMP cmap lookup.
- **Atlas Baking** — Rasterizes glyphs into a single `EditableImage` texture atlas with 4× vertical anti-aliasing. Bake once at startup, render unlimited text at zero cost.
- **Font Weight** — Synthetic bold via a `fontWeight` parameter that thickens strokes horizontally and vertically during baking.
- **Rich Text** — Supports inline `<font>` tags for color, transparency, and size changes within a single text line.
- **Custom Charsets** — Bake only the codepoints you need to keep atlas size minimal.
- **Kerning** — Automatic kern pair lookup for tight, professional letter spacing.
- **Text Alignment** — Left, center, and right alignment out of the box.
- **In-Place Updates** — Update text content, color, or size without recreating instances.

## Installation

### Wally

Add to your `wally.toml`:

```toml
[dependencies]
EditableFont = "mewious/editable-font@0.1.6"
```

Then run:

```bash
wally install
```

### Rojo

Clone the repo and build:

```bash
rojo build -o "EditableFont.rbxlx"
```

Or sync directly into Studio:

```bash
rojo serve
```

## Quick Start

```lua
local EditableFont = require(path.to.EditableFont)

-- Create a font instance from a .ttf buffer
local font = EditableFont.new(fontBuffer, 48)

-- Render text into a Frame
local frame = font:renderText({
    text = "Hello, world!",
    color = Color3.fromRGB(255, 255, 255),
    fontSize = 48,
    parent = screenGui,
})

-- Update text in-place (no re-creation)
font:updateText(frame, {
    text = "Score: 9999",
    color = Color3.fromRGB(255, 215, 0),
})
```

## API

### `EditableFont.new(data: buffer, fontSize: number?, charset: {number}?)`

Creates a new EditableFont instance from raw `.ttf` bytes.

| Parameter  | Type        | Description                                          |
| ---------- | ----------- | ---------------------------------------------------- |
| `data`     | `buffer`    | Raw TTF file bytes                                   |
| `fontSize` | `number?`   | Default font size in pixels (default 100)            |
| `charset`  | `{number}?` | Default codepoints to bake (default ASCII 0x20–0x7E) |

### `font:renderText(config: RenderConfig): Frame`

Renders text and returns a `Frame` ready to parent into your UI.

### `font:updateText(frame: Frame, config: RenderConfig)`

Updates an existing rendered frame in-place with new config values.

### `font:getAtlas(fontSize: number?, charset: {number}?, fontWeight: number?): AtlasResult`

Returns (or bakes) an atlas for the given parameters. Cached automatically.

### `font:destroy()`

Cleans up all cached atlases.

### RenderConfig

```lua
{
    text: string | { RichTextSegment },
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
```

## Rich Text

Supports a subset of rich text tags within string values:

```lua
font:renderText({
    text = '<font color="#FF0000">Red</font> and <font color="#00FF00">Green</font>',
    fontSize = 32,
})
```

Or pass structured segments for full control:

```lua
font:renderText({
    text = {
        { text = "Normal ", color = Color3.new(1, 1, 1) },
        { text = "Bold",   color = Color3.new(1, 0.8, 0) },
    },
    fontSize = 32,
})
```

## Font Weight

Apply synthetic boldness during atlas baking:

```lua
local frame = font:renderText({
    text = "Bold Text",
    fontWeight = 2,  -- extra stroke width in pixels
})
```

A weight of `0` is normal. Higher values produce thicker strokes. Each unique weight creates a separately cached atlas.
