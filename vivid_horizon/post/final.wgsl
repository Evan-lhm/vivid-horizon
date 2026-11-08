// Adds the bloom and god rays, then grades: exposure, a soft tone curve, contrast, saturation and vibrance.
override bloom_strength: f32 = 0.4;
override exposure: f32 = 1.0;
override contrast: f32 = 1.0;
override saturation: f32 = 1.1;
override vibrance: f32 = 0.2;
override vignette: bool = true;
override depth_of_field: f32 = 0.5;
override lens_flare: f32 = 0.6;

// Lens flare: when the sun is on screen and in sight, faint coloured discs and a ring lie
// along the line from the sun through the centre of the picture.
fn flare(uv: vec2<f32>) -> vec3<f32> {
    let s = project(vec4<f32>(frame.sun_direction, 0.0));
    if s.z <= 0.0 {
        return vec3<f32>(0.0);
    }
    let sun = s.xy;
    if any(sun < vec2<f32>(0.0)) || any(sun > vec2<f32>(1.0)) {
        return vec3<f32>(0.0);
    }
    // In sight: open sky at the sun and around it.
    let o = 6.0 / frame.resolution;
    let seen = (select(0.0, 1.0, depth_at(sun) == 0.0) + select(0.0, 1.0, depth_at(sun + vec2<f32>(o.x, 0.0)) == 0.0)
        + select(0.0, 1.0, depth_at(sun - vec2<f32>(o.x, 0.0)) == 0.0) + select(0.0, 1.0, depth_at(sun + vec2<f32>(0.0, o.y)) == 0.0)
        + select(0.0, 1.0, depth_at(sun - vec2<f32>(0.0, o.y)) == 0.0)) / 5.0;
    let strength = seen * daylight() * (1.0 - frame.rain) * f32(frame.eye_in == 0u) * (1.0 - smoothstep(0.3, 0.75, length(sun - 0.5)));
    if strength <= 0.0 {
        return vec3<f32>(0.0);
    }
    let aspect = vec2<f32>(frame.resolution.x / frame.resolution.y, 1.0);
    let axis = sun - vec2<f32>(0.5);
    var c = vec3<f32>(0.0);
    // Discs: where along the axis (1 is the sun, -1 its mirror), size and colour.
    let at = array<f32, 4>(0.45, -0.25, -0.6, -1.1);
    let size = array<f32, 4>(0.03, 0.05, 0.08, 0.14);
    let tint = array<vec3<f32>, 4>(vec3<f32>(1.0, 0.8, 0.5), vec3<f32>(0.5, 0.9, 0.7), vec3<f32>(0.6, 0.7, 1.0), vec3<f32>(1.0, 0.6, 0.8));
    for (var i = 0; i < 4; i++) {
        let d = length((uv - (0.5 + axis * at[i])) * aspect);
        c += tint[i] * (1.0 - smoothstep(size[i] * 0.6, size[i], d)) * 0.14;
    }
    // A thin ring around the mirror point.
    let ring = length((uv - (0.5 - axis * 0.8)) * aspect);
    c += vec3<f32>(0.7, 0.85, 1.0) * exp(-pow((ring - 0.22) * 60.0, 2.0)) * 0.1;
    return c * strength * lens_flare;
}

// Depth of field: focus on what the crosshair points at; what lies farther away blurs
// (only farther: the near world and the hand stay sharp), as a camera lens would.
fn defocus(input: PostInput, c: vec3<f32>) -> vec3<f32> {
    let focus = max(length(view_position(vec2<f32>(0.5), depth_at(vec2<f32>(0.5)))), 2.0);
    let dist = select(length(view_position(input.uv, input.depth)), 1e5, input.depth == 0.0);
    let blur = clamp((1.0 / focus - 1.0 / dist) * 6.0, 0.0, 1.0) * depth_of_field;
    if blur <= 0.01 {
        return c;
    }
    let radius = blur * 6.0 / frame.resolution.y;
    let aspect = vec2<f32>(frame.resolution.y / frame.resolution.x, 1.0);
    var sum = c;
    for (var i = 0; i < 12; i++) {
        let a = f32(i) * 2.39996;
        let r = sqrt((f32(i) + 0.5) / 12.0);
        let uv = input.uv + vec2<f32>(cos(a), sin(a)) * r * radius * aspect;
        let m = textureSampleLevel(wet, linear_sampler, uv, 0.0);
        sum += mix(textureSampleLevel(scene_color, linear_sampler, uv, 0.0).rgb, m.rgb, clamp(m.a, 0.0, 1.0));
    }
    return sum / 13.0;
}

fn post(input: PostInput) -> vec4<f32> {
    var c = input.color.rgb;
    // Wet ground mirrors the world (post/wet.wgsl).
    let mirror = textureSampleLevel(wet, linear_sampler, input.uv, 0.0);
    c = mix(c, mirror.rgb, clamp(mirror.a, 0.0, 1.0));
    if depth_of_field > 0.0 {
        c = defocus(input, c);
    }
    // Ambient occlusion, softened over a few pixels to hide its grain.
    let ao_step = 2.0 / frame.resolution;
    let shade = (textureSampleLevel(rays, linear_sampler, input.uv + ao_step * vec2<f32>(1.0, 1.0), 0.0).g
        + textureSampleLevel(rays, linear_sampler, input.uv + ao_step * vec2<f32>(-1.0, 1.0), 0.0).g
        + textureSampleLevel(rays, linear_sampler, input.uv + ao_step * vec2<f32>(1.0, -1.0), 0.0).g
        + textureSampleLevel(rays, linear_sampler, input.uv + ao_step * vec2<f32>(-1.0, -1.0), 0.0).g) * 0.25;
    c *= shade;
    // Under water: a blue-green tint and a thick fog that hides what is far, darker where the
    // sky's light doesn't reach.
    if frame.in_water > 0.0 {
        let dist = select(length(view_position(input.uv, input.depth)), 64.0, input.depth == 0.0);
        let light = mix(0.3, 1.0, frame.eye_light_smooth.y) * mix(0.55, 1.0, daylight());
        let water_fog = vec3<f32>(0.04, 0.22, 0.32) * light;
        // Near the lit surface (or inside a waterfall, open to the air on its sides) the water is
        // thin and clear: much less fog and tint than down in the depths.
        let shallow = smoothstep(0.72, 0.9, frame.eye_light_smooth.y);
        let tinted = mix(c * vec3<f32>(0.55, 0.85, 0.95), c * vec3<f32>(0.8, 0.95, 1.0), shallow);
        let fogged = mix(tinted, water_fog, 1.0 - exp(-dist * 0.09 * mix(1.0, 0.25, shallow)));
        c = mix(c, fogged, frame.in_water);
    }
    let glow = textureSampleLevel(bloom, linear_sampler, input.uv, 0.0).rgb;
    c += glow * bloom_strength * 1.6;

    // God rays, golden when the sun is low, pale yellow at noon.
    // A small blur hides the rays' dither, which reads as grain.
    let o = 2.0 / frame.resolution;
    let shafts = (textureSampleLevel(rays, linear_sampler, input.uv, 0.0).r * 2.0
        + textureSampleLevel(rays, linear_sampler, input.uv + vec2<f32>(o.x, o.y), 0.0).r
        + textureSampleLevel(rays, linear_sampler, input.uv + vec2<f32>(-o.x, o.y), 0.0).r
        + textureSampleLevel(rays, linear_sampler, input.uv + vec2<f32>(o.x, -o.y), 0.0).r
        + textureSampleLevel(rays, linear_sampler, input.uv + vec2<f32>(-o.x, -o.y), 0.0).r) / 6.0;
    var ray_color = mix(vec3<f32>(1.0, 0.92, 0.75), vec3<f32>(1.0, 0.6, 0.3), sun_low());
    ray_color = mix(vec3<f32>(0.6, 0.72, 0.9), ray_color, daylight());
    ray_color = mix(ray_color, vec3<f32>(0.45, 0.85, 1.0), frame.in_water);
    c += ray_color * shafts;
    if lens_flare > 0.0 {
        c += flare(input.uv);
    }

    // Storms: a dimmer picture. (No grey "wet" grade: Horizon leaves frame.wetness at 0, and the
    // user liked the rain's colours without one.)
    c *= 1.0 - frame.thunder * 0.1;
    // Rainy nights: lift the near-black toward a dim blue-grey so the world stays readable.
    let gloom = (1.0 - daylight()) * frame.rain * select(0.0, 1.0, frame.dimension == 0) * (1.0 - frame.in_water);
    c = c * (1.0 + 0.6 * gloom) + vec3<f32>(0.012, 0.018, 0.03) * gloom;

    c *= exposure;
    // Soft shoulder so bright colours roll off instead of clipping.
    c = c / (1.0 + 0.2 * c) * 1.2;
    // Contrast around mid grey.
    c = (c - 0.5) * contrast + 0.5;
    c = max(c, vec3<f32>(0.0));

    c = saturate_color(c, saturation);
    // Vibrance: the less saturated a colour is, the more it gets.
    let mx = max(c.r, max(c.g, c.b));
    let mn = min(c.r, min(c.g, c.b));
    let sat = (mx - mn) / max(mx, 1e-4);
    c = saturate_color(c, 1.0 + vibrance * (1.0 - sat));

    if vignette {
        let aspect = frame.resolution.x / frame.resolution.y;
        let d = length((input.uv - 0.5) * vec2<f32>(aspect, 1.0)) / length(vec2<f32>(aspect, 1.0) * 0.5);
        c *= 1.0 - smoothstep(0.6, 1.15, d) * 0.3;
    }
    return vec4<f32>(clamp(c, vec3<f32>(0.0), vec3<f32>(1.0)), input.color.a);
}
