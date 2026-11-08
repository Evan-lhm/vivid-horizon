// Rain as soft grey-white streaks lit like the sky around them, snow as white flakes. Horizon
// applies no light or fog here, so the streaks take the daylight and sky light themselves.
fn weather(input: WeatherInput) -> vec4<f32> {
    let sky = input.light.y * mix(0.12, 1.0, daylight()) * (1.0 - frame.thunder * 0.4);
    let lamp = input.light.x * vec3<f32>(1.0, 0.85, 0.6);
    let light = max(vec3<f32>(sky), lamp * 0.8) + 0.03;
    if input.snow {
        return vec4<f32>(vec3<f32>(0.95, 0.97, 1.0) * light, input.color.a * 0.85);
    }
    let rain = vec3<f32>(0.72, 0.78, 0.85) * light;
    return vec4<f32>(apply_fog(rain, input.position), input.color.a * 0.3);
}
