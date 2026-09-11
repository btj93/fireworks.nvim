# fireworks.nvim

Fireworks in your buffer every time you save. A joke UI plugin drawn on an
extmark canvas: overlay virtual text on real lines and a `virt_lines` block
that claims the blank rows below EOF, so a three line file still fills the window.

A rocket climbs from the bottom row, slows as it nears its apex, hangs dark for a
beat, and breaks somewhere in the top 60 percent. The light of the burst falls on
every visible window. Text near the burst is
tinted toward the firework's own colour, brighter on the side facing it, and
fades out over about a second. About one in twenty rockets fails: a dud that sputters and
falls back, a premature pop right above the tube, or a fizzle. Failures scorch
instead of lighting, leaving an ash coloured burn and a little smoke for two
seconds.

## Requirements

Neovim 0.10 or newer.

## Installation

### lazy.nvim

```lua
return {
  "btj93/fireworks.nvim",
  event = "VeryLazy",
  opts = {},
}
```

Local checkout:

```lua
return {
  dir = vim.fn.expand("~/nvim-dev/fireworks.nvim"),
  event = "VeryLazy",
  opts = {},
}
```

## Commands

| Command | Effect |
| --- | --- |
| `:Fireworks` | Launch a show over the current buffer now. |
| `:Fireworks <type>` | Force a firework type: `peony`, `chrysanthemum`, `willow`, `ring`, `crossette`, `crackle`, `pistil`, `palm`, `kamuro`, `salute`. |
| `:Fireworks fail` | Force a random failure. `:Fireworks dud`, `:Fireworks premature`, `:Fireworks fizzle` pick one. |
| `:Fireworks toggle` | Arm or disarm the save trigger. |
| `:Fireworks stop` | Clear a running show. |

## Configuration

Every key below is optional. The values shown are the defaults.

```lua
require("fireworks").setup({
  events = { "BufWritePost" },
  launch_chance = 1.0,
  rockets = { min = 1, max = 3 },
  stagger = { first = { 0.3, 0.8 }, between = { 0.4, 1.4 } },
  types = {
    peony = 4,
    chrysanthemum = 3,
    willow = 2,
    ring = 2,
    crossette = 2,
    crackle = 2,
    pistil = 2,
    palm = 2,
    kamuro = 1,
    salute = 1,
  },
  palettes = {
    single = 4,
    two_tone = 3,
    rainbow = 2,
    gold = 2,
  },
  sizes = {
    small = 3,
    medium = 4,
    large = 2,
  },
  colors = { "#ff5f5f", "#ff9f43", "#ffe66d", "#7bed9f", "#70a1ff", "#a29bfe", "#ff6bcb", "#eaeaea" },
  gold = { "#ffd700", "#ffb347", "#fff1a8" },
  fail_chance = 0.05,
  fps = 30,
  max_particles = 400,
  light = {
    radius = 25,
    brightness = 0.7,
    attack_ms = 80,
    duration_ms = 900,
    bg = 0.25,
    fg = 1.0,
    glow = 0.35,
    glow_radius = 6,
  },
  burn = {
    duration_ms = 2000,
    color = "#6b5d4f",
    smoke = true,
  },
  ignore_filetypes = {
    "TelescopePrompt", "TelescopeResults", "NvimTree", "neo-tree", "lazy", "mason",
    "help", "dashboard", "alpha", "starter", "notify", "noice", "trouble", "qf",
    "fugitive", "gitcommit",
  },
})
```

| Key | Meaning |
| --- | --- |
| `events` | Autocommand events that launch a show. Only normal listed file buffers qualify. |
| `launch_chance` | Probability in `[0, 1]` that a qualifying save launches at all. |
| `rockets` | Inclusive range of rockets per save. The first leaves after a `stagger.first` delay and later ones follow at `stagger.between` intervals. |
| `stagger` | Seconds, as `{min, max}` ranges, before the first rocket leaves and between rockets. |
| `types` | Weights for the burst types. `peony` plain radial, `chrysanthemum` trailing, `willow` drooping, `ring` one radius, `crossette` splitting, `crackle` twinkling, `pistil` inner break in a second colour, `palm` thick rising arms, `kamuro` gold willow with long trails, `salute` a bare flash with a large light. A weight of `0` removes a type. |
| `palettes` | Weights for colour schemes. `single` is one random colour, `two_tone` two, `rainbow` the whole `colors` list, `gold` the `gold` list. |
| `sizes` | Weights for burst radius: `small`, `medium`, `large`. |
| `colors` | Colours drawn from for `single`, `two_tone`, and `rainbow`. |
| `gold` | Colours used by the `gold` palette. |
| `fail_chance` | Probability that a rocket fails. The kind of failure is uniform over dud, premature, fizzle. |
| `fps` | Animation frames per second. |
| `max_particles` | Particle cap per show. A save while a running show is at the cap is dropped. |
| `light.radius` | Reach of the burst flash in rows. Columns count for half a row. Cells beyond it get no extmark. |
| `light.brightness` | Peak blend toward the firework colour at the burst. Intensity is `brightness * (1 - d / radius)^2`. |
| `light.attack_ms` | Ramp of the burst flash from dark to peak as the shell opens. |
| `light.duration_ms` | How long the burst flash takes to fade after its peak. It holds near full for the first part and falls away at the end. The stars keep glowing for as long as they live. |
| `light.bg` | Fraction of the intensity also applied to the background, so blank cells and the area past end of line glow too. `0` tints foreground only. |
| `light.fg` | Strength of the foreground blend. Text keeps its own syntax colour and is pushed toward the firework colour by this fraction of the intensity. `0` leaves foregrounds alone and lights the background only. |
| `light.glow` | Peak light each star sheds on the cells around it, fading with the star's age. Overlapping stars add up, so a fresh shell glows hardest at its heart. `0` leaves only the burst flash. |
| `light.glow_radius` | Reach of one star's glow in rows, twice that in columns. |
| `burn.duration_ms` | How long a failure's scorch lasts. |
| `burn.color` | Ash colour the scorch blends toward. Rows adjacent to the impact take a darker soot shade. |
| `burn.smoke` | Emit drifting `~` smoke from the impact point. |
| `ignore_filetypes` | Filetypes that never launch on save. Buffers with a non empty `buftype` are always skipped. |

## How the light works

The light is a byproduct of the particles. Every frame each star deposits a
small glow around its screen cell, scaled by its age, and the burst adds a short
bright flash at the break point. Contributions add up into one light field in
editor screen space, and where two colours overlap a cell takes their
intensity weighted mean, so a two tone shell blends through its seam. The glow expands with the shell, drifts and droops with
the stars, and dies with them. Every window then reads the field cell by cell:
neighbouring cells with the same intensity bucket and colour are merged into one
extmark, so a row is brighter on the side facing the light and the glow past end
of line fades cell by cell. Buckets map to cached highlight
groups whose foreground is the colour already on that cell, taken from the
treesitter highlighter and from highlight extmarks such as LSP semantic tokens,
blended toward the palette colour, with a lighter touch of the same colour on
the background. Syntax colours stay readable while the light is on; a keyword
just goes warmer. Two tone fireworks light
each half of the screen with the colour that flew that way. Extmarks are set at
priority 200 so the tint wins over treesitter while it lasts.

Windows shorter than 10 rows or narrower than 20 columns are skipped. Rendering
never raises inside the autocommand; every extmark write is wrapped in `pcall`.

## Development

```sh
make test          # plenary specs under tests/
make lint          # luacheck
make format        # stylua
make format-check
```

## License

Apache 2.0. See [LICENSE](LICENSE).
