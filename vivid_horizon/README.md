# Vivid Horizon

A shader pack for [Horizon](https://github.com/horizon-rust/horizon) (native format, shader API 0.1):
vivid, saturated colours, a soft blue sky with volumetric clouds, warm sunlight and cool blue
shadows, mirror-like turquoise water, rain that soaks the ground, and warm torch-lit nights.

It aims for the look of the classic "vibrant" Minecraft shader packs, but every line is original,
written from public techniques. No code from any other shader pack was read, copied or adapted.

## Install

From the launcher: Mods > **Horizon** > search "Vivid Horizon". Or by hand: put
`vivid_horizon-<version>.hshader` (or the `vivid_horizon` folder) into `shaderpacks/` beside
`options.txt`, then pick **Vivid Horizon** in Options > Video Settings > Shaders > Shader Packs.
Shader Options... tunes every effect, grouped into four pages (Colour, Light, Sky, Water and plants).

## What it does

**Sky.** Its own sky: soft blue by day, warm sunsets, deep blue-grey nights with the Milky Way,
volumetric clouds shaded by the sun, a sun disc and moon glow, and haze in the sky's colours.

**Light.** Shadows from the sun and moon (warm in the light, blue-violet in the shade), coloured
shadows under stained glass, ambient occlusion in corners and under leaves, volumetric god rays
through leaves, moonbeams. Block light in each source's colour: orange torches and fire, blue soul
fire, red redstone, cool white sea lanterns, yellow, green and pink froglights; held lights too.

**Water.** Clear turquoise water with refraction, depth colour, ripples, reflections of the world
(the engine's mirror, and screen-space reflections for water at other heights), a sun glint, glowing
shallows and soft shore foam by day, caustics on the bottom. Glassy waterfalls with sliding streaks,
clear even from inside. Underwater fog and light shafts.

**Rain.** Raindrop rings on water and on soaked ground, which darkens, takes a wet sheen and
reflects houses, trees and torches. Readable rainy nights.

**Camera.** Bloom, depth of field focused on what you look at, lens flare, exposure, contrast,
saturation, vibrance and vignette. Waving leaves, grass and crops, stronger in storms.

## Performance

About 4.5 ms of GPU per frame at 1440p on an RTX 5070 Ti. On a slower GPU, turn off (or lower)
Shadows, Volumetric clouds and Wet ground reflections first.

## Files

| Stage | File |
| --- | --- |
| shared | `common.wgsl`: sky colours, flat clouds, haze, noise, projection |
| sky | `sky.wgsl`: sky, sun disc, volumetric clouds, Milky Way |
| vertex | `vertex.wgsl`: waving plants |
| material | `material.wgsl`: shadows, sunlight, block light, water, waterfalls, wet ground |
| weather | `weather.wgsl`: rain and snow |
| post | `post/bloom_h.wgsl`, `post/bloom_v.wgsl`: bloom |
| post | `post/rays.wgsl`: god rays (r) and ambient occlusion (g) in one pass |
| post | `post/wet.wgsl`: reflections in wet ground |
| post | `post/final.wgsl`: depth of field, lens flare, colour grade |

## Develop

```sh
horizon-shader check vivid_horizon
horizon-shader pack vivid_horizon
```

The game reloads the pack when a file is saved.

## License

MIT, see [LICENSE](LICENSE).
