// Terrain lighting: vanilla's light, then sunlight and shadow from the shadow map (warm where
// the sun reaches, cool blue in the shade), clear blue water, and fog toward the pack's sky.
override shadows: bool = true;
override shadow_strength: f32 = 0.85;
override reflections: bool = true;
override water_shine: f32 = 0.8;
override caustics: bool = true;
override torch_light: f32 = 1.0;


// How much of the light at camera-relative `p` the shadow map lets through, 0..1.
fn sun_visibility(p: vec3<f32>, n: vec3<f32>) -> f32 {
    if frame.has_shadow == 0u {
        return 1.0;
    }
    // Push the point off its face, more far away where the map's texels are larger.
    let bias = frame.shadow_center_texel * (1.5 + length(p) * 0.04);
    let sp = shadow_position(p + n * bias);
    if any(sp.xy <= vec2<f32>(0.0)) || any(sp.xy >= vec2<f32>(1.0)) || sp.z >= 1.0 {
        return 1.0;
    }
    let texel = 1.0 / frame.shadow_resolution;
    var sum = 0.0;
    sum += textureSampleCompareLevel(shadow_map, shadow_sampler, sp.xy + vec2<f32>(-0.5, -1.5) * texel, sp.z);
    sum += textureSampleCompareLevel(shadow_map, shadow_sampler, sp.xy + vec2<f32>(1.5, -0.5) * texel, sp.z);
    sum += textureSampleCompareLevel(shadow_map, shadow_sampler, sp.xy + vec2<f32>(0.5, 1.5) * texel, sp.z);
    sum += textureSampleCompareLevel(shadow_map, shadow_sampler, sp.xy + vec2<f32>(-1.5, 0.5) * texel, sp.z);
    // Fade out toward the map's edge so its border doesn't show.
    let edge = smoothstep(0.85, 1.0, length(p.xz) / frame.shadow_distance);
    return mix(sum * 0.25, 1.0, edge);
}

// What translucent terrain lies between `p` and the light, from one look at the shadow maps:
// rgb the colour sunlight takes through stained glass or ice (white where there is none),
// a 1 where it is water (left to the caustics, so rgb stays white).
fn translucent_above(p: vec3<f32>, n: vec3<f32>) -> vec4<f32> {
    let none = vec4<f32>(1.0, 1.0, 1.0, 0.0);
    if frame.has_shadow == 0u {
        return none;
    }
    let sp = shadow_position(p + n * frame.shadow_center_texel * (1.5 + length(p) * 0.04));
    if any(sp.xy <= vec2<f32>(0.0)) || any(sp.xy >= vec2<f32>(1.0)) {
        return none;
    }
    if textureSampleCompareLevel(shadow_map_translucent, shadow_sampler, sp.xy, sp.z) > 0.5 {
        return none;
    }
    let glass = textureLoad(shadow_color, vec2<i32>(sp.xy * vec2<f32>(textureDimensions(shadow_color))), 0);
    if glass.a > 0.999 {
        return vec4<f32>(1.0, 1.0, 1.0, 1.0);
    }
    // Deepen the colour a little: thin glass still throws a clear tint.
    return vec4<f32>(mix(vec3<f32>(1.0), saturate_color(glass.rgb, 1.4) * 1.2, clamp(glass.a * 1.6, 0.0, 1.0)), 0.0);
}

// The water's surface height: three layers of noise drifting in different directions.
// `detail` fades the small ripples out with distance, where they would only sparkle as grain.
fn water_height(p: vec2<f32>, detail: f32) -> f32 {
    let t = frame.time;
    // Each layer is turned to its own angle: value noise is flat along its grid lines, which
    // would otherwise show as a lattice of straight horizontal and vertical lines.
    let ra = mat2x2<f32>(0.93, 0.37, -0.37, 0.93);
    let rb = mat2x2<f32>(0.8, 0.6, -0.6, 0.8);
    let rc = mat2x2<f32>(0.28, 0.96, -0.96, 0.28);
    return value_noise(ra * p * 0.9 + vec2<f32>(t * 0.35, t * 0.2)) * 0.55
        + value_noise(rb * p * 2.3 + vec2<f32>(-t * 0.5, t * 0.4)) * 0.3 * mix(0.4, 1.0, detail)
        + value_noise(rc * p * 5.1 + vec2<f32>(t * 0.7, -t * 0.6)) * 0.15 * detail;
}

// Ripples: the slope of water_height, so they don't line up in bands. `facing` is how steeply
// the eye looks at the surface (|view.y|): at a low angle one screen row spans many ripples,
// which would alias into horizontal stripes, so the small ripples fade out sooner there.
fn water_normal(world: vec2<f32>, dist: f32, facing: f32) -> vec3<f32> {
    let e = 0.08;
    let foot = dist / max(facing, 0.08);
    let detail = 1.0 - smoothstep(8.0, 40.0, foot);
    let h = water_height(world, detail);
    let dx = water_height(world + vec2<f32>(e, 0.0), detail) - h;
    let dz = water_height(world + vec2<f32>(0.0, e), detail) - h;
    // Calm far away, where ripples would only shimmer.
    let strength = 0.15 * (1.0 - smoothstep(12.0, 48.0, dist)) * (1.0 - 0.7 * smoothstep(30.0, 120.0, foot));
    return normalize(vec3<f32>(-dx / e * strength, 1.0, -dz / e * strength));
}

// The camera-relative distance to what lies behind water at `screen`.
fn behind_distance(screen: vec2<f32>) -> f32 {
    let texel = vec2<i32>(clamp(screen, vec2<f32>(0.0), vec2<f32>(0.9999)) * frame.resolution);
    let depth = textureLoad(opaque_depth, texel, 0);
    if depth <= 0.0 {
        return 1e4;
    }
    let ndc = vec4<f32>(screen.x * 2.0 - 1.0, 1.0 - screen.y * 2.0, depth, 1.0);
    let v = frame.projection_inverse * ndc;
    return length(v.xyz / v.w);
}

// Raindrop rings: in each cell of a grid a drop lands at a random spot, and a ring spreads
// from it and fades; each new drop lands elsewhere. Returns the tilt to add to the normal.
// Drops come fast and at random, more of them the harder it rains (and in a storm).
fn rain_rings(p: vec2<f32>) -> vec2<f32> {
    let cell = floor(p);
    let seed = hash2(cell);
    let phase = frame.time * (2.2 + frame.thunder * 0.8) + seed * 7.0;
    let drop = floor(phase);
    let age = fract(phase);
    // Not every cycle brings a drop to this cell, so the rings don't pulse in step.
    let falls = step(hash2(cell + vec2<f32>(drop * 3.0, 17.0)), 0.3 + 0.5 * frame.rain + 0.2 * frame.thunder);
    let spot = vec2<f32>(hash2(cell + vec2<f32>(drop * 13.0, 7.0)), hash2(cell + vec2<f32>(5.0, drop * 11.0)));
    let d = fract(p) - (0.3 + 0.4 * spot);
    let r = length(d);
    let front = r - age * 0.3;
    let wave = sin(front * 70.0) * (1.0 - smoothstep(0.0, 0.05, abs(front))) * (1.0 - age);
    return d / max(r, 1e-3) * wave * falls;
}

// Screen-space reflection, for water the mirror doesn't cover (it only holds one water level):
// step along the reflected ray and, where it passes just behind the solid world on screen,
// take that pixel's colour. rgb the colour, a how sure the hit is (0: none, use the sky).
fn screen_reflection(p: vec3<f32>, r: vec3<f32>) -> vec4<f32> {
    var t = 0.4;
    for (var i = 0; i < 24; i++) {
        let q = p + r * t;
        let s = project(vec4<f32>(q, 1.0));
        if s.z <= 0.0 {
            break;
        }
        let uv = s.xy;
        if any(uv < vec2<f32>(0.0)) || any(uv > vec2<f32>(1.0)) {
            break;
        }
        let scene = behind_distance(uv);
        let dq = length(q);
        if dq > scene && dq < scene + 0.6 + t * 0.15 {
            let edge = smoothstep(0.0, 0.08, min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y)));
            return vec4<f32>(textureLoad(opaque_color, vec2<i32>(uv * frame.resolution), 0).rgb, edge);
        }
        t = t * 1.18 + 0.15;
    }
    return vec4<f32>(0.0);
}

fn water(input: MaterialInput, sun: f32) -> vec4<f32> {
    let dist = length(input.position);
    let view = -input.position / dist;
    let world = (input.position.xz + frame.camera_position.xz) % vec2<f32>(4096.0);
    var n = select(input.normal, water_normal(world, dist, abs(view.y)), input.face == 1u);
    var ring = 0.0;
    let rains = select(0.0, 1.0, frame.downfall > 0.0 && frame.temperature >= 0.15);
    let drops = frame.rain * rains * smoothstep(0.9, 0.97, input.light.y) * (1.0 - smoothstep(32.0, 80.0, dist));
    if input.face == 1u && drops > 0.0 {
        let tilt = rain_rings(world * 2.2) + rain_rings(world * 2.2 + vec2<f32>(0.5, 0.37));
        n = normalize(n + vec3<f32>(tilt.x, 0.0, tilt.y) * 0.35 * drops);
        ring = min(length(tilt), 1.0) * drops;
    }
    let light = luminance(input.lightmap);

    // Under the surface: the bottom seen through the water, bent by the waves, fading with
    // depth into a turquoise-blue that the light scatters in the water.
    var refract_uv = clamp(input.screen + n.xz * 0.015, vec2<f32>(0.0), vec2<f32>(0.9999));
    var deep = behind_distance(refract_uv) - dist;
    if deep < 0.0 {
        // The bent ray hit something in front of the water: don't bend here.
        refract_uv = input.screen;
        deep = max(behind_distance(refract_uv) - dist, 0.0);
    }
    // A falling sheet is thin: what lies behind it shows through.
    deep = min(deep, select(1.2, 64.0, input.face == 1u));
    let bottom = textureLoad(opaque_color, vec2<i32>(refract_uv * frame.resolution), 0).rgb;
    let absorb = exp(-vec3<f32>(0.6, 0.24, 0.17) * deep);
    let scatter = vec3<f32>(0.05, 0.21, 0.25) * light * mix(0.6, 1.0, sun);
    // Even shallow water keeps some colour of its own, so the bottom never shows bare.
    let murk = mix(0.3, 1.0, 1.0 - exp(-deep * 0.6));
    let under = bottom * absorb * (1.0 - murk * 0.5) + scatter * murk;

    // Above: the pack's sky, with the world's mirror where it shows terrain.
    let r = reflect(-view, n);
    var above = sky_with_clouds(vec3<f32>(r.x, abs(r.y), r.z), frame.fog_color) * mix(0.25, 1.0, input.light.y);
    let on_plane = abs(input.position.y + frame.camera_position.y - frame.water_plane) < 0.6;
    if reflections && frame.has_reflection == 1u && input.face == 1u && on_plane {
        // Less bend at a low angle: there a row of the mirror is stretched far, and jittering it
        // shows as stripes.
        let bend = 0.04 * mix(0.3, 1.0, smoothstep(0.1, 0.5, abs(view.y)));
        let uv = clamp(input.screen + n.xz * bend, vec2<f32>(0.001), vec2<f32>(0.999));
        let mirror = textureSampleLevel(reflection, reflection_sampler, uv, 0.0).rgb;
        // The mirror draws vanilla's sky; where it matches that, keep the pack's sky instead.
        let vanilla_sky = mix(frame.fog_color, frame.sky_color, smoothstep(0.0, 0.4, abs(r.y)));
        let terrain = smoothstep(0.04, 0.15, length(mirror - vanilla_sky));
        above = mix(above, mirror, terrain);
    } else if reflections && input.face == 1u && dist < 64.0 {
        let hit = screen_reflection(input.position, r);
        above = mix(above, hit.rgb, hit.a * (1.0 - smoothstep(40.0, 64.0, dist)));
    }

    // Stronger than physical Fresnel: calm water reads as a mirror, as in the reference look.
    let fresnel = 0.1 + 0.9 * pow(1.0 - max(dot(n, view), 0.0), 3.0);
    var c = mix(under, above, clamp(fresnel * (0.4 + water_shine), 0.0, 1.0));
    // The sun's glint on the waves.
    let h = normalize(view + frame.sun_direction);
    let glint = pow(max(dot(n, h), 0.0), 300.0) * daylight() * sun * input.light.y * water_shine * (1.0 - frame.rain);
    c += vec3<f32>(1.0, 0.9, 0.7) * glint * 4.0;
    if input.face == 1u {
        // Shallows glow turquoise, and a soft drifting lace of foam laps at the shore.
        let shallow = 1.0 - smoothstep(0.0, 3.0, deep);
        // Lit by the real light only: at night the shallows must not glow.
        let lit = light * mix(0.15, 1.0, daylight());
        c = mix(c, vec3<f32>(0.2, 0.7, 0.66) * lit, 0.3 * shallow);
        let lace = smoothstep(0.55, 0.8, value_noise(world * 2.6 + vec2<f32>(frame.time * 0.25, 0.0)));
        c = mix(c, vec3<f32>(0.9, 0.97, 1.0) * lit, 0.5 * lace * (1.0 - smoothstep(0.0, 0.9, deep)));
        // The rings catch the grey sky light, so they show even where the water looks down.
        c += frame.fog_color * (0.3 + 0.7 * lit) * ring * 0.35;
    } else {
        // Falling water: the vanilla flow texture in the biome's water colour, with long
        // streaks sliding down so the sheet reads as moving, glassy water rather than foam.
        let w = input.position + frame.camera_position;
        let across = (w.x + w.z) % 4096.0;
        let fall = vec2<f32>(across * 2.5, w.y * 0.35 + frame.time * 1.6);
        let streak = value_noise(fall) * 0.6 + value_noise(fall * vec2<f32>(2.7, 2.0) + 3.1) * 0.4;
        let tex = luminance(input.albedo.rgb);
        let hue = mix(input.tint.rgb, vec3<f32>(0.35, 0.75, 0.85), 0.45);
        let body = hue * (0.5 + 0.8 * tex) * (0.15 + 0.85 * light);
        c = mix(c, body, 0.35 + 0.2 * streak);
        c += vec3<f32>(0.8, 0.95, 1.0) * (0.15 + 0.85 * light) * smoothstep(0.6, 0.85, streak) * 0.25;
    }
    return vec4<f32>(apply_fog(c, input.position), 1.0);
}

// The water's surface seen from below: the world above through a bright window straight
// up (refraction), and beyond it the surface mirrors the dark water (total internal
// reflection), with the waves bending both.
fn water_from_below(input: MaterialInput) -> vec4<f32> {
    let dist = length(input.position);
    let view = -input.position / dist;
    let world = (input.position.xz + frame.camera_position.xz) % vec2<f32>(4096.0);
    let n = water_normal(world, dist, abs(view.y));
    // How straight up the eye looks through the surface, bent by the ripples.
    let cos_i = clamp(dot(n, -view), 0.0, 1.0);
    let window = smoothstep(0.5, 0.72, cos_i);
    let uv = clamp(input.screen + n.xz * 0.03, vec2<f32>(0.0), vec2<f32>(0.9999));
    let above = textureLoad(opaque_color, vec2<i32>(uv * frame.resolution), 0).rgb;
    let light = mix(0.15, 1.0, input.light.y) * mix(0.25, 1.0, daylight());
    let depths = vec3<f32>(0.04, 0.22, 0.32) * light;
    // Beyond the window the surface still lets some of the outside through (real water is not
    // a perfect mirror there, and a fully dark ceiling hides the shore and the trees).
    let see = max(window, 0.4);
    var c = mix(depths, above * vec3<f32>(0.8, 1.0, 1.05) + depths * 0.3, see);
    // A thin bright line where the window meets the mirror.
    c += vec3<f32>(0.5, 0.8, 0.9) * light * (window * (1.0 - window)) * 0.8;
    return vec4<f32>(c, 1.0);
}

// How wet a surface open to the rain is, 0..1: frame.wetness (which dries slowly after the
// rain stops) where the biome rains and the sky's light falls straight on it.
fn rain_wetness(input: MaterialInput) -> f32 {
    let rains = select(0.0, 1.0, frame.downfall > 0.0 && frame.temperature >= 0.15 && frame.dimension == 0);
    // Horizon leaves frame.wetness at 0 for now, so the rain's own strength stands in for it.
    return max(frame.wetness, frame.rain) * rains * smoothstep(0.9, 0.97, input.light.y);
}

// Wet ground: darker, deeper colours, and on flat ground open to the rain a thin film of water
// all over that catches the sky, with raindrop rings once it is soaked.
fn wet(input: MaterialInput, c_in: vec3<f32>, wetness: f32) -> vec3<f32> {
    var c = saturate_color(c_in * (1.0 - wetness * 0.3), 1.0 + wetness * 0.15);
    let flat_up = smoothstep(0.9, 0.99, input.normal.y);
    if flat_up <= 0.0 || input.material != 0u {
        return c;
    }
    let world = (input.position.xz + frame.camera_position.xz) % vec2<f32>(4096.0);
    // The film builds up evenly the longer it rains.
    let soak = smoothstep(0.25, 1.0, wetness) * flat_up;
    if soak <= 0.0 {
        return c;
    }
    let dist = length(input.position);
    let view = -input.position / dist;
    // Raindrop rings while it rains, on ground soaked through.
    let tilt = (rain_rings(world * 2.2) + rain_rings(world * 2.2 + vec2<f32>(0.5, 0.37))) * frame.rain
        * smoothstep(0.5, 1.0, wetness) * (1.0 - smoothstep(16.0, 40.0, dist));
    let n = normalize(vec3<f32>(tilt.x * 0.5, 1.0, tilt.y * 0.5));
    let r = reflect(-view, n);
    let sky = vivid_sky(vec3<f32>(r.x, abs(r.y), r.z), frame.fog_color) * input.light.y;
    let fresnel = 0.04 + 0.96 * pow(1.0 - max(dot(n, view), 0.0), 5.0);
    // A film, not a mirror: soaked ground turns darker and deeper, and a soft sheen of the
    // grey sky lies over it, strong at low angles (blurred: the film is rough, so no sharp clouds).
    let sheen = mix(frame.fog_color, sky, 0.35) * mix(0.5, 1.0, input.light.y);
    c = mix(c * (1.0 - soak * 0.4), sheen, soak * mix(0.12, 0.8, fresnel));
    c += frame.fog_color * input.light.y * min(length(tilt), 1.0) * soak * 0.45;
    // Tell the post stage this ground is a wet mirror, so post/wet.wgsl reflects the world in it.
    set_surface(n, soak, 0.0);
    return c;
}

fn material(input: MaterialInput) -> Surface {
    let base = input.albedo * input.tint * vec4<f32>(input.lightmap, 1.0);
    if input.fluid == 2u || frame.dimension != 0 {
        return Surface(vec4<f32>(apply_fog(base.rgb, input.position), base.a));
    }

    // Plants have no useful face direction; light them as if they faced the sun.
    let plant = input.material == PLANT || input.material == PLANT_TOP;
    let ndl = select(smoothstep(-0.05, 0.25, dot(input.normal, frame.light_direction)), 1.0, plant);
    var sun = 1.0;
    var above = vec4<f32>(1.0, 1.0, 1.0, 0.0);
    if shadows {
        sun = sun_visibility(input.position, input.normal) * ndl;
        if sun > 0.0 && input.fluid == 0u {
            above = translucent_above(input.position, input.normal);
        }
        // Under water, sunlight reaches the bottom in dancing bright lines.
        if caustics && above.a > 0.5 {
            sun *= 0.3 + 1.6 * caustic(input.position + frame.camera_position, 1.0, 8.0);
        }
    }

    // Shade only the light that comes from the sky, and less near torches.
    let day = daylight();
    let reach = input.light.y * input.light.y * (1.0 - input.light.x * 0.6)
        * shadow_strength * mix(0.3, 1.0, day) * (1.0 - frame.rain * 0.7);
    var c = base.rgb;
    c *= mix(vec3<f32>(1.0), vec3<f32>(0.46, 0.50, 0.72), (1.0 - sun) * reach);
    // Golden sunlight by day, deep orange as the sun sets (when vanilla's light is already dim).
    let sunlight = mix(vec3<f32>(1.12, 1.06, 0.95), vec3<f32>(1.45, 1.0, 0.7), sun_low());
    let warm = max(day, sun_low() * smoothstep(-0.1, 0.0, frame.sun_direction.y));
    c *= mix(vec3<f32>(1.0), sunlight, sun * reach * warm);
    // Sunlight through stained glass takes its colour.
    c *= mix(vec3<f32>(1.0), above.rgb, sun * reach);

    // Block light: warm and orange near torches, falling off fast, in the colour the manifest's
    // [[lights]] give the sources nearby (blue by soul fire, red by redstone).
    let near = block_light_color(input.position);
    // block_light_colors stores the [[lights]] colours over 4 (they range 0..4).
    let lamp = mix(vec3<f32>(1.0, 0.55, 0.22), near.rgb * 4.0, min(near.a, 1.0));
    let glow = pow(input.light.x, 2.0) * torch_light * (1.0 - day * input.light.y * 0.7);
    let surface = input.albedo.rgb * input.tint.rgb;
    // Tint rather than add: vanilla's light is already bright near a torch, so adding more
    // burns the picture white. The tint keeps the brightness and turns it orange.
    let hue = lamp / max(max(lamp.r, lamp.g), max(lamp.b, 1e-3));
    // Dim sources (soul fire, redstone) barely raise glow, so let their colour's own reach tint too.
    let fade = (1.0 - day * input.light.y * 0.7) * torch_light;
    let tint = max(glow, min(near.a, 1.0) * input.light.x * 0.6 * fade);
    c *= mix(vec3<f32>(1.0), hue * 1.15, tint * 0.75);
    c += surface * hue * tint * 0.14;
    // Held and dropped light sources (Horizon's dynamic lights) in their [[lights]] colour.
    // Light only a tint: dynamic lights already raise the block light (and so the glow above).
    c += surface * min(input.colored_light, vec3<f32>(1.0)) * torch_light * 0.1;

    // Moonlight: a cool blue cast where the night sky reaches, not near torches.
    let night = (1.0 - day) * select(0.0, 1.0, frame.dimension == 0);
    // Moonlit ground loses most of its colour, so torchlight stands out warm against it.
    let moonlit = night * input.light.y * (1.0 - input.light.x);
    c = saturate_color(c, 1.0 - moonlit * 0.55) * mix(vec3<f32>(1.0), vec3<f32>(0.85, 1.0, 1.3), moonlit);

    if input.fluid == 1u {
        if frame.eye_in == 0u {
            return Surface(water(input, sun));
        }
        if frame.eye_in == 1u && input.face == 1u {
            return Surface(water_from_below(input));
        }
        // Inside a waterfall: its walls are the same thin sheet, seen from the other side.
        if frame.eye_in == 1u {
            return Surface(water(input, sun));
        }
    }
    let wetness = rain_wetness(input);
    if wetness > 0.0 && input.fluid == 0u && !input.translucent {
        c = wet(input, c, wetness);
    }
    return Surface(vec4<f32>(apply_fog(c, input.position), base.a));
}
