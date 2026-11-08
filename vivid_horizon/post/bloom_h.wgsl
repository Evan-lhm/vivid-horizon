// Bloom, first half: the bright parts of the picture, blurred sideways, at a quarter of its size.
override bloom_threshold: f32 = 0.8;

fn bright(uv: vec2<f32>) -> vec3<f32> {
    let c = textureSampleLevel(previous, linear_sampler, uv, 0.0).rgb;
    // The daytime sky is bright everywhere; let it glow less.
    let sky = select(1.0, 0.15, depth_at(uv) == 0.0);
    let l = luminance(c);
    let k = smoothstep(bloom_threshold, 1.0, l);
    return c * k * k * sky;
}

fn post(input: PostInput) -> vec4<f32> {
    // One step is two texels of this quarter-size target, so the blur is wide.
    let step = vec2<f32>(8.0 / frame.resolution.x, 0.0);
    var sum = bright(input.uv) * 0.2;
    let w = array<f32, 4>(0.18, 0.13, 0.08, 0.04);
    for (var i = 0; i < 4; i++) {
        let o = step * f32(i + 1);
        sum += (bright(input.uv + o) + bright(input.uv - o)) * w[i];
    }
    return vec4<f32>(sum, 1.0);
}
