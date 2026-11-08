// God rays. Without a shadow map, from each pixel, march toward the sun on screen and count how much open sky lies
// on the way. Where terrain or leaves block the sky, the streak breaks: shafts of light.
override godrays: f32 = 0.8;

const RAY_STEPS: i32 = 32;

// Where the sun is on screen (uv, 0..1 from the top left), and 0 when it is behind the camera.
fn sun_screen() -> vec3<f32> {
    let s = project(vec4<f32>(frame.sun_direction, 0.0));
    if s.z <= 0.0 {
        return vec3<f32>(0.0);
    }
    return vec3<f32>(s.xy, 1.0);
}

const VOLUME_STEPS: i32 = 16;

// With a shadow map: march through the air along the view ray and count the points the sun
// reaches. Light gets through gaps in leaves, so the shafts do too, even with the sun off screen.
fn volumetric(input: PostInput, strength: f32) -> f32 {
    let end = view_position(input.uv, input.depth);
    let dist = select(min(length(end), frame.shadow_distance * 0.8), frame.shadow_distance * 0.8, input.depth == 0.0);
    let dir = normalize(end);
    let dither = hash2(input.pixel);
    var lit = 0.0;
    for (var i = 0; i < VOLUME_STEPS; i++) {
        // Denser samples near the camera, where shafts are seen best.
        let t = (f32(i) + dither) / f32(VOLUME_STEPS);
        let sp = shadow_position(dir * dist * t * t);
        lit += textureSampleCompareLevel(shadow_map, shadow_sampler, sp.xy, sp.z);
    }
    lit /= f32(VOLUME_STEPS);
    // Scattering is strongest looking toward the sun, with a faint haze elsewhere.
    // Toward the body casting the shadows: the sun by day, the moon by night.
    let toward = max(dot(dir, frame.light_direction), 0.0);
    let phase = pow(toward, 8.0) * 0.4 + 0.06;
    let air = 1.0 - exp(-dist * 0.012);
    return lit * phase * air * strength;
}

// Under water: shafts of light coming down from the surface, where the sun reaches.
fn underwater_rays(input: PostInput) -> f32 {
    let end = view_position(input.uv, input.depth);
    let dist = select(min(length(end), 32.0), 32.0, input.depth == 0.0);
    let dir = normalize(end);
    // A fixed dither: a changing one shimmers under water.
    let dither = hash2(floor(input.pixel / 2.0)) * 0.5;
    var lit = 0.0;
    for (var i = 0; i < VOLUME_STEPS; i++) {
        let t = (f32(i) + dither) / f32(VOLUME_STEPS);
        let pos = dir * dist * t;
        var sun = 1.0;
        if frame.has_shadow == 1u {
            let sp = shadow_position(pos);
            sun = textureSampleCompareLevel(shadow_map, shadow_sampler, sp.xy, sp.z);
        }
        // Broad, soft shafts: a coarser pattern than the caustics on the bottom.
        lit += sun * caustic(pos + frame.camera_position, 0.3, 3.0);
    }
    lit /= f32(VOLUME_STEPS);
    let light = daylight() * frame.eye_light_smooth.y * (1.0 - frame.rain * 0.6);
    return lit * (1.0 - exp(-dist * 0.08)) * light * godrays * 1.2;
}

fn shafts(input: PostInput) -> f32 {
    if frame.eye_in == 1u {
        return underwater_rays(input);
    }
    // Moonbeams at night too, fainter, while the shadow map follows the moon.
    let moon = select(0.0, 0.3, frame.has_shadow == 1u && frame.dimension == 0);
    let strength = godrays * max(daylight(), moon * (1.0 - daylight())) * (1.0 - frame.rain * 0.85) * f32(frame.eye_in == 0u);
    if strength <= 0.0 {
        return 0.0;
    }
    if frame.has_shadow == 1u {
        return volumetric(input, strength);
    }
    let sun = sun_screen();
    if sun.z == 0.0 {
        return 0.0;
    }
    let aspect = vec2<f32>(frame.resolution.x / frame.resolution.y, 1.0);
    let to_sun = sun.xy - input.uv;
    let dither = hash2(input.pixel);
    // Only the sky close to the sun shines; each sample's weight is how close to the sun it is.
    // lit / total is how much of that shining sky this pixel sees along its line to the sun.
    var lit = 0.0;
    var total = 0.0;
    for (var i = 0; i < RAY_STEPS; i++) {
        let t = (f32(i) + dither) / f32(RAY_STEPS);
        let uv = input.uv + to_sun * t;
        let w = exp(-length((sun.xy - uv) * aspect) * 5.0);
        // Off screen counts as half open, so rays don't pop at the edges.
        let inside = all(uv >= vec2<f32>(0.0)) && all(uv <= vec2<f32>(1.0));
        let open = select(0.5, select(0.0, 1.0, depth_at(uv) == 0.0), inside);
        lit += open * w;
        total += w;
    }
    let seen = lit / max(total, 1e-4);
    // Strongest looking toward the sun, reaching across most of the screen.
    let falloff = exp(-length(to_sun * aspect) * 1.3);
    return seen * falloff * strength;
}

// Ambient occlusion: soft darkening in corners, under ledges and leaves, where nearby
// geometry hides part of the sky. From the depth alone: rebuild the surface's point and
// facing, test a few points in the half-sphere above it, and count those buried in geometry.
override ambient_occlusion: f32 = 1.0;

const AO_SAMPLES: i32 = 8;
const AO_RADIUS: f32 = 1.0;

fn ambient(input: PostInput) -> f32 {
    if input.depth == 0.0 || ambient_occlusion <= 0.0 {
        return 1.0;
    }
    let p = view_position(input.uv, input.depth);
    let dist = length(p);
    // The surface's facing from its neighbours on screen.
    let texel = 1.0 / frame.resolution;
    // On each axis take the neighbour on the same surface (the nearer one), so block edges
    // don't get a wrong facing and a dark outline.
    let pr = view_position(input.uv + vec2<f32>(texel.x, 0.0), depth_at(input.uv + vec2<f32>(texel.x, 0.0))) - p;
    let pl = p - view_position(input.uv - vec2<f32>(texel.x, 0.0), depth_at(input.uv - vec2<f32>(texel.x, 0.0)));
    let pd = view_position(input.uv + vec2<f32>(0.0, texel.y), depth_at(input.uv + vec2<f32>(0.0, texel.y))) - p;
    let pu = p - view_position(input.uv - vec2<f32>(0.0, texel.y), depth_at(input.uv - vec2<f32>(0.0, texel.y)));
    let dx = select(pl, pr, dot(pr, pr) < dot(pl, pl));
    let dy = select(pu, pd, dot(pd, pd) < dot(pu, pu));
    var n = normalize(cross(dy, dx));
    if dot(n, p) > 0.0 {
        n = -n;
    }
    // A basis around the facing, turned a random angle per pixel so the few samples don't band.
    let a = hash2(input.pixel) * 6.2831853;
    let up = select(vec3<f32>(0.0, 1.0, 0.0), vec3<f32>(1.0, 0.0, 0.0), abs(n.y) > 0.9);
    let t0 = normalize(cross(up, n));
    let b0 = cross(n, t0);
    let t = t0 * cos(a) + b0 * sin(a);
    let b = cross(n, t);

    var occluded = 0.0;
    for (var i = 0; i < AO_SAMPLES; i++) {
        // A spiral of points filling the half-sphere, nearer ones denser.
        let f = (f32(i) + 0.5) / f32(AO_SAMPLES);
        let ang = f32(i) * 2.39996;
        let r = sqrt(1.0 - f * f);
        let dir = t * cos(ang) * r + b * sin(ang) * r + n * (f * 0.8 + 0.2);
        let s = p + dir * AO_RADIUS * mix(0.25, 1.0, f);
        let uv = project(vec4<f32>(s, 1.0)).xy;
        if any(uv < vec2<f32>(0.0)) || any(uv > vec2<f32>(1.0)) {
            continue;
        }
        let q = view_position(uv, depth_at(uv));
        let behind = length(s) - length(q);
        // Buried: the geometry on screen lies in front of the sample, but not far in front
        // (a distant wall in front isn't touching this surface).
        occluded += smoothstep(0.02, 0.12, behind) * (1.0 - smoothstep(AO_RADIUS, AO_RADIUS * 2.5, behind));
    }
    let ao = 1.0 - occluded / f32(AO_SAMPLES) * ambient_occlusion * (1.0 - smoothstep(48.0, 96.0, dist));
    return ao;
}

// Two results in one pass (a pack may write only 4): r the light shafts, g the ambient occlusion.
fn post(input: PostInput) -> vec4<f32> {
    return vec4<f32>(shafts(input), ambient(input), 0.0, 1.0);
}
