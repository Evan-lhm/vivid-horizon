// Reflections in wet ground: where the material stage marked the ground smooth (set_surface),
// follow the reflected ray across the picture and take the colour of what it meets: trees,
// walls, torches. rgb the reflection, a how much of it to lay over the ground.
override wet_reflections: f32 = 1.0;

const WET_STEPS: i32 = 24;

fn post(input: PostInput) -> vec4<f32> {
    // Dry weather: nothing set a wet surface, so skip the surface read too.
    if wet_reflections <= 0.0 || input.depth == 0.0 || max(frame.rain, frame.wetness) <= 0.0 {
        return vec4<f32>(0.0);
    }
    let s = surface_at(vec2<i32>(input.uv * frame.resolution));
    if !s.present || s.smoothness <= 0.0 {
        return vec4<f32>(0.0);
    }
    let p = view_position(input.uv, input.depth);
    let view = -normalize(p);
    let r = reflect(-view, s.normal);
    let fresnel = 0.04 + 0.96 * pow(1.0 - max(dot(s.normal, view), 0.0), 5.0);
    var t = 0.3;
    for (var i = 0; i < WET_STEPS; i++) {
        let q = p + r * t;
        let s2 = project(vec4<f32>(q, 1.0));
        if s2.z <= 0.0 {
            break;
        }
        let uv = s2.xy;
        if any(uv < vec2<f32>(0.0)) || any(uv > vec2<f32>(1.0)) {
            break;
        }
        let d = depth_at(uv);
        if d > 0.0 {
            let scene = length(view_position(uv, d));
            let dq = length(q);
            if dq > scene && dq < scene + 0.8 + t * 0.2 {
                let edge = smoothstep(0.0, 0.1, min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y)));
                let fade = 1.0 - smoothstep(24.0, 48.0, length(p));
                let col = textureSampleLevel(scene_color, linear_sampler, uv, 0.0).rgb;
                return vec4<f32>(col, s.smoothness * mix(0.15, 0.85, fresnel) * edge * fade * wet_reflections);
            }
        }
        t = t * 1.2 + 0.2;
    }
    return vec4<f32>(0.0);
}
