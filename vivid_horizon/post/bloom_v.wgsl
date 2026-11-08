// Bloom, second half: the sideways blur blurred again up and down.
fn post(input: PostInput) -> vec4<f32> {
    let step = vec2<f32>(0.0, 8.0 / frame.resolution.y);
    var sum = textureSampleLevel(bloom_h, linear_sampler, input.uv, 0.0).rgb * 0.2;
    let w = array<f32, 4>(0.18, 0.13, 0.08, 0.04);
    for (var i = 0; i < 4; i++) {
        let o = step * f32(i + 1);
        sum += (textureSampleLevel(bloom_h, linear_sampler, input.uv + o, 0.0).rgb
            + textureSampleLevel(bloom_h, linear_sampler, input.uv - o, 0.0).rgb) * w[i];
    }
    return vec4<f32>(sum, 1.0);
}
