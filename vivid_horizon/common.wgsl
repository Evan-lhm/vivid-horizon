fn luminance(c: vec3<f32>) -> f32 {
    return dot(c, vec3<f32>(0.2126, 0.7152, 0.0722));
}

// 1 while the sun is up in the Overworld, fading out around the horizon.
fn daylight() -> f32 {
    return select(0.0, smoothstep(-0.1, 0.15, frame.sun_direction.y), frame.dimension == 0);
}

// 1 when the sun is on the horizon, 0 from a third of the way up.
fn sun_low() -> f32 {
    return 1.0 - smoothstep(0.0, 0.35, abs(frame.sun_direction.y));
}

// A camera-relative point (w = 1) or direction (w = 0) on screen: xy its uv (0..1 from the
// top left), z the clip w (<= 0 behind the camera, where xy means nothing).
fn project(v: vec4<f32>) -> vec3<f32> {
    let clip = frame.projection * frame.view * v;
    let ndc = clip.xy / clip.w;
    return vec3<f32>(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5, clip.w);
}

fn saturate_color(c: vec3<f32>, amount: f32) -> vec3<f32> {
    return mix(vec3<f32>(luminance(c)), c, amount);
}

// [[materials]] ids from horizon-shaders.toml.
const LEAVES: u32 = 10u;
const PLANT: u32 = 20u;       // rooted at the bottom of its sprite
const PLANT_TOP: u32 = 21u;   // the upper half of a two-block plant

override sky_saturation: f32 = 1.0;
override sunset_glow: f32 = 1.0;
override cloud_coverage: f32 = 0.55;
override haze: f32 = 0.6;

// How strongly the sky shows sunset colours: up while the sun is low, gone soon after it sets.
fn dusk_amount() -> f32 {
    let y = frame.sun_direction.y;
    return (1.0 - smoothstep(0.0, 0.4, y)) * smoothstep(-0.2, -0.02, y) * sunset_glow;
}

// The pack's sky along a camera-relative direction, without clouds: the sky stage, water's
// reflections and the haze all use it, so they match. `vanilla` is vanilla's colour (for rain).
fn vivid_sky(dir_in: vec3<f32>, vanilla: vec3<f32>) -> vec3<f32> {
    let dir = normalize(dir_in);
    let sun = frame.sun_direction;
    let day = smoothstep(-0.12, 0.2, sun.y);
    let dusk = clamp(dusk_amount(), 0.0, 1.0);
    let up = clamp(dir.y, 0.0, 1.0);
    let toward = max(dot(dir, sun), 0.0);
    // How far round toward the sun this direction faces, ignoring height.
    let side = dot(normalize(dir.xz + vec2<f32>(1e-4)), normalize(sun.xz + vec2<f32>(1e-4))) * 0.5 + 0.5;

    // Day: soft blue overhead to a hazy lavender-white horizon.
    let day_sky = mix(vec3<f32>(0.80, 0.80, 0.93), vec3<f32>(0.30, 0.50, 0.86), pow(up, 0.5));
    // Dusk: a warm band toward the sun, lavender-pink away from it, muted blue-violet overhead.
    let dusk_horizon = mix(vec3<f32>(0.62, 0.50, 0.70), vec3<f32>(1.0, 0.55, 0.28), pow(side, 2.0));
    let dusk_sky = mix(dusk_horizon, vec3<f32>(0.32, 0.36, 0.62), pow(up, 0.45));
    // Night: a deep blue-grey, a little lighter and greener toward the horizon.
    let night_sky = mix(vec3<f32>(0.06, 0.085, 0.11), vec3<f32>(0.015, 0.03, 0.055), pow(up, 0.5));

    var c = mix(night_sky, day_sky, day);
    c = mix(c, dusk_sky, dusk * 0.8);

    // Glow around the sun: a wide warm haze and a bright core, orange when it's low.
    let glow_color = mix(vec3<f32>(1.0, 0.92, 0.78), vec3<f32>(1.0, 0.58, 0.25), dusk);
    let above = smoothstep(-0.2, 0.0, sun.y);
    c += glow_color * (pow(toward, 10.0) * 0.12 + pow(toward, 120.0) * 0.35) * above;
    // A soft glow round the moon at night.
    let to_moon = max(dot(dir, frame.moon_direction), 0.0);
    c += vec3<f32>(0.55, 0.65, 0.8) * (pow(to_moon, 8.0) * 0.08 + pow(to_moon, 80.0) * 0.3) * (1.0 - day);

    // Below the horizon, fade toward a darker version so the void isn't bright.
    c = mix(c, c * 0.45, smoothstep(0.0, -0.3, dir.y));

    // Overcast: toward vanilla's grey rain sky.
    c = mix(c, vanilla, frame.rain * 0.75) * (1.0 - frame.thunder * 0.35);
    return saturate_color(c, sky_saturation);
}

// An integer hash of a lattice point, 0..1 (a sin-based hash loses precision on GPUs at large
// inputs and draws straight-edged shards).
fn hash2(p: vec2<f32>) -> f32 {
    var h = bitcast<u32>(vec2<i32>(p).x) * 1597334673u ^ bitcast<u32>(vec2<i32>(p).y) * 3812015801u;
    h = (h ^ (h >> 16u)) * 2246822519u;
    h = (h ^ (h >> 13u)) * 3266489917u;
    h ^= h >> 16u;
    return f32(h) / 4294967295.0;
}

fn value_noise(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash2(i), hash2(i + vec2<f32>(1.0, 0.0)), u.x),
               mix(hash2(i + vec2<f32>(0.0, 1.0)), hash2(i + vec2<f32>(1.0, 1.0)), u.x), u.y);
}

// Five octaves of noise, each turned a little so the layers don't line up.
fn fbm(p_in: vec2<f32>) -> f32 {
    var p = p_in;
    var sum = 0.0;
    var amp = 0.5;
    let turn = mat2x2<f32>(0.8, 0.6, -0.6, 0.8);
    for (var i = 0; i < 5; i++) {
        sum += value_noise(p) * amp;
        p = turn * p * 2.03 + vec2<f32>(1.7, 9.2);
        amp *= 0.5;
    }
    return sum;
}

fn cloud_density(p: vec2<f32>) -> f32 {
    let cover = clamp(cloud_coverage + frame.rain * 0.4, 0.0, 1.0);
    // fbm sits mostly between 0.35 and 0.7: map coverage onto that range.
    let t = 0.69 - cover * 0.35;
    return smoothstep(t, t + 0.1, fbm(p));
}

// Soft rounded clouds over the sky: a layer of noise high above, lit from the sun's side,
// white by day, pink and orange at sunset, dim at night.
fn sky_with_clouds(dir_in: vec3<f32>, vanilla: vec3<f32>) -> vec3<f32> {
    let dir = normalize(dir_in);
    let sky = vivid_sky(dir, vanilla);
    if cloud_coverage <= 0.0 || dir.y <= 0.01 || frame.dimension != 0 {
        return sky;
    }
    // Where the ray meets the cloud layer, drifting with time and with the camera.
    let drift = vec2<f32>(frame.time * 0.004, frame.time * 0.0015);
    let p = dir.xz / (dir.y + 0.06) * 0.45 + frame.camera_position.xz * 0.0002 + drift;
    let d = cloud_density(p);
    if d <= 0.0 {
        return sky;
    }
    let sun = frame.sun_direction;
    // Thicker cloud toward the sun means this side is in its own shadow.
    let shade = 1.0 - cloud_density(p + normalize(sun.xz + vec2<f32>(1e-4)) * 0.08) * 0.45;
    let day = smoothstep(-0.12, 0.2, sun.y);
    let dusk = clamp(dusk_amount(), 0.0, 1.0);
    var lit = mix(vec3<f32>(0.16, 0.19, 0.24), vec3<f32>(1.05, 1.02, 0.98), day);
    lit = mix(lit, vec3<f32>(1.0, 0.62, 0.50), dusk * 0.85);
    let dark = mix(sky * 0.8, mix(vec3<f32>(0.05, 0.06, 0.08), vec3<f32>(0.55, 0.58, 0.70), day), 0.5);
    var c = mix(dark, lit, shade);
    // A bright edge where thin cloud lies in front of the sun.
    c += mix(vec3<f32>(1.0, 0.9, 0.75), vec3<f32>(1.0, 0.6, 0.3), dusk)
        * pow(max(dot(dir, sun), 0.0), 6.0) * (1.0 - d) * 0.6 * day;
    c = mix(c, vec3<f32>(luminance(c)) * 0.8, frame.rain * 0.7);
    let fade = smoothstep(0.01, 0.2, dir.y);
    return mix(sky, c, d * fade * 0.95);
}

// What fog fades distant terrain toward.
fn fog_toward(position: vec3<f32>) -> vec3<f32> {
    if frame.eye_in == 1u {
        // Under water: the same dark teal as the pack's underwater fog.
        return vec3<f32>(0.04, 0.22, 0.32) * mix(0.15, 1.0, frame.eye_light_smooth.y) * mix(0.25, 1.0, daylight());
    }
    if frame.dimension != 0 || frame.eye_in != 0u {
        return frame.fog_color;
    }
    return vivid_sky(position, frame.fog_color);
}

// Vanilla's fog at the edge of the world, plus a soft haze that grows with distance in the
// Overworld's open air, in the sky's colour, so far hills fade into the horizon.
fn apply_fog(c: vec3<f32>, position: vec3<f32>) -> vec3<f32> {
    let d = max(length(position.xz), abs(position.y));
    var f = smoothstep(frame.fog_start, frame.fog_end, d);
    if frame.dimension == 0 && frame.eye_in == 0u {
        // No haze in caves: it follows the sky light where the camera is.
        f = max(f, (1.0 - exp(-length(position) * 0.006 * haze)) * 0.85 * frame.eye_light_smooth.y);
    }
    return mix(c, fog_toward(position), f);
}

// Light through moving water: bright lines where two drifting noise layers cross, 0..1.
// `world` is a world position; it is slid along the light to y = 0, so every point on one ray
// of light reads the same value and the pattern draws shafts in the water.
// `scale` sizes the pattern and `sharp` how thin its lines are.
fn caustic(world: vec3<f32>, scale: f32, sharp: f32) -> f32 {
    let l = frame.light_direction;
    let q = ((world.xz - l.xz / max(l.y, 0.2) * world.y) % vec2<f32>(4096.0)) * scale;
    let t = frame.time;
    let a = value_noise(q * 0.9 + vec2<f32>(t * 0.45, t * 0.3));
    let b = value_noise(q * 1.5 - vec2<f32>(t * 0.35, -t * 0.4) + vec2<f32>(5.2, 1.3));
    return pow(1.0 - abs(a - b), sharp);
}
