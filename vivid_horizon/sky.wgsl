// The sky is drawn by sky_with_clouds (common.wgsl), shared with the water and the fog.
// The direction this pixel really looks along. Horizon gives the sky a ray built without the
// walking bob, which it multiplies into the projection; recover the pixel from that ray, then
// take it back through frame.projection (with the bob), so the sky moves with the world.
fn bobbed_direction(d: vec3<f32>) -> vec3<f32> {
    let v = (frame.view * vec4<f32>(d, 0.0)).xyz;
    if v.z > -1e-4 {
        return d;
    }
    let tan_half = 1.0 / frame.projection[1][1];
    let aspect = frame.resolution.x / frame.resolution.y;
    let ndc = vec2<f32>(v.x / (-v.z) / (aspect * tan_half), v.y / (-v.z) / tan_half);
    // A point far out along the pixel (reversed depth: near 0 is far), so the bob's small
    // sideways shift of the eye doesn't bend the direction.
    let q = frame.projection_inverse * vec4<f32>(ndc, 1e-4, 1.0);
    let dir = (frame.view_inverse * vec4<f32>(q.xyz / q.w, 0.0)).xyz;
    return select(d, normalize(dir), dot(dir, dir) > 0.0);
}

// The Milky Way at night: a faint band of light with darker lanes and a dust of small stars,
// fixed to the sky so it turns with the stars (the sky turns about the z axis).
override milky_way: f32 = 1.0;

fn galaxy(d: vec3<f32>) -> vec3<f32> {
    let a = atan2(frame.sun_direction.y, frame.sun_direction.x);
    let ca = cos(-a);
    let sa = sin(-a);
    let s = vec3<f32>(d.x * ca - d.y * sa, d.x * sa + d.y * ca, d.z);
    let pole = normalize(vec3<f32>(0.35, 0.55, 0.76));
    let b = dot(s, pole);
    let along = atan2(dot(s, normalize(cross(pole, vec3<f32>(0.0, 0.0, 1.0)))), s.z);
    let band = exp(-b * b * 30.0);
    let glow = smoothstep(0.35, 0.75, fbm(vec2<f32>(along * 3.0, b * 9.0) + 11.0));
    let lanes = smoothstep(0.45, 0.65, fbm(vec2<f32>(along * 7.0, b * 22.0) + 3.0));
    var c = mix(vec3<f32>(0.45, 0.5, 0.75), vec3<f32>(0.75, 0.68, 0.85), glow) * band * glow * (1.0 - lanes * 0.6) * 0.18;
    // Small faint stars, thicker in the band.
    let cell = floor(s * 260.0);
    let h = hash2(cell.xy + vec2<f32>(cell.z * 37.0, cell.z * 11.0));
    c += vec3<f32>(0.8, 0.85, 1.0) * step(1.0 - (0.004 + band * 0.02), h) * 0.25;
    return c;
}

// Clouds with depth: march through a thick layer, its density from the same noise as the
// flat clouds, rounded at top and bottom, each step shaded by how much cloud lies toward the
// sun above it. Only the sky draws them; reflections and fog keep the cheaper flat layer.
override volumetric_clouds: bool = true;

const CLOUD_STEPS: i32 = 10;

// Three octaves of fbm, scaled to the five-octave range: enough for the soft self-shadow.
fn fbm3(p_in: vec2<f32>) -> f32 {
    var p = p_in;
    var sum = 0.0;
    var amp = 0.5;
    let turn = mat2x2<f32>(0.8, 0.6, -0.6, 0.8);
    for (var i = 0; i < 3; i++) {
        sum += value_noise(p) * amp;
        p = turn * p * 2.03 + vec2<f32>(1.7, 9.2);
        amp *= 0.5;
    }
    return sum * (0.96875 / 0.875);
}

fn cloud_volume(p: vec2<f32>, h: f32) -> f32 {
    return cloud_shape(fbm(p), h);
}

fn cloud_volume_coarse(p: vec2<f32>, h: f32) -> f32 {
    return cloud_shape(fbm3(p), h);
}

fn cloud_shape(noise: f32, h: f32) -> f32 {
    let cover = clamp(cloud_coverage + frame.rain * 0.4, 0.0, 1.0);
    let t = 0.69 - cover * 0.35;
    // Rounder toward the middle of the layer, so tops bulge and bottoms stay flatter.
    let profile = smoothstep(0.0, 0.25, h) * (1.0 - smoothstep(0.45, 1.0, h));
    return clamp((noise - t - (1.0 - profile) * 0.12) * 8.0, 0.0, 1.0);
}

fn volume_clouds(dir: vec3<f32>, vanilla: vec3<f32>) -> vec3<f32> {
    let sky = vivid_sky(dir, vanilla);
    if cloud_coverage <= 0.0 || dir.y <= 0.01 || frame.dimension != 0 {
        return sky;
    }
    let drift = vec2<f32>(frame.time * 0.004, frame.time * 0.0015) + frame.camera_position.xz * 0.0002;
    let sun = frame.sun_direction;
    let day = smoothstep(-0.12, 0.2, sun.y);
    let dusk = clamp(dusk_amount(), 0.0, 1.0);
    var lit = mix(vec3<f32>(0.16, 0.19, 0.24), vec3<f32>(1.08, 1.05, 1.0), day);
    lit = mix(lit, vec3<f32>(1.0, 0.62, 0.50), dusk * 0.85);
    let shadow = mix(sky * 0.8, mix(vec3<f32>(0.05, 0.06, 0.08), vec3<f32>(0.5, 0.54, 0.68), day), 0.55);
    let toward_sun = normalize(sun.xz + vec2<f32>(1e-4)) * 0.07;
    // The layer, from height 1 to 1.4 above the eye in the flat layer's units.
    let t0 = 1.0 / (dir.y + 0.06);
    let t1 = 1.4 / (dir.y + 0.06);
    let dither = fract(sin(dot(dir.xz, vec2<f32>(91.3, 47.7))) * 4375.85);
    let dt = (t1 - t0) / f32(CLOUD_STEPS);
    var light = vec3<f32>(0.0);
    var through = 1.0;
    for (var i = 0; i < CLOUD_STEPS; i++) {
        let t = t0 + (f32(i) + dither) * dt;
        let h = (f32(i) + dither) / f32(CLOUD_STEPS);
        let p = dir.xz * t * 0.45 + drift;
        let d = cloud_volume(p, h);
        if d <= 0.0 {
            continue;
        }
        // Cloud between here and the sun, a little higher up the layer.
        let block = cloud_volume_coarse(p + toward_sun, min(h + 0.25, 1.0));
        let shade = exp(-block * 1.6) * mix(0.75, 1.0, h);
        let absorb = 1.0 - exp(-d * dt * 9.0);
        light += mix(shadow, lit, shade) * absorb * through;
        through *= 1.0 - absorb;
        if through < 0.03 {
            break;
        }
    }
    var c = light + sky * through;
    // A bright rim where thin cloud lies in front of the sun.
    c += mix(vec3<f32>(1.0, 0.9, 0.75), vec3<f32>(1.0, 0.6, 0.3), dusk)
        * pow(max(dot(dir, sun), 0.0), 6.0) * through * (1.0 - through) * 1.2 * day;
    c = mix(c, vec3<f32>(luminance(c)) * 0.8, frame.rain * 0.7 * (1.0 - through));
    return mix(sky, c, smoothstep(0.01, 0.2, dir.y));
}

fn sky(input: SkyInput) -> vec4<f32> {
    let d = bobbed_direction(input.direction);
    var c = select(sky_with_clouds(d, input.color.rgb), volume_clouds(d, input.color.rgb), volumetric_clouds);
    // The sun's disc, round with a soft edge. Only here: the haze and reflections use the sky
    // without it, or distant hills would show a ghost of the sun through their haze.
    let sun = frame.sun_direction;
    let dusk = clamp(dusk_amount(), 0.0, 1.0);
    let disc = smoothstep(0.9993, 0.9997, dot(d, sun)) * smoothstep(-0.2, 0.0, sun.y) * (1.0 - frame.rain);
    // Hidden behind clouds: how far they changed the clear sky here.
    let cloud = clamp(length(c - vivid_sky(d, input.color.rgb)) * 4.0, 0.0, 1.0);
    c += mix(vec3<f32>(1.0, 0.97, 0.9), vec3<f32>(1.0, 0.7, 0.4), dusk) * disc * (1.0 - cloud * 0.85) * 2.0;
    let dark = (1.0 - smoothstep(-0.25, 0.05, sun.y)) * (1.0 - frame.rain) * smoothstep(0.0, 0.25, d.y);
    c += galaxy(d) * dark * (1.0 - cloud) * milky_way * select(0.0, 1.0, frame.dimension == 0);
    return vec4<f32>(c, input.color.a);
}
