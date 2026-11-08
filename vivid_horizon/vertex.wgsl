// Waving leaves and plants. The offset depends only on the corner's world position (and, for
// plants, how high up the sprite it is), so corners blocks share move together: no cracks.
override waving: bool = true;
override wind_strength: f32 = 1.0;


fn wind(p: vec3<f32>, t: f32) -> vec3<f32> {
    // Two slow waves across the world plus a faster flutter; gusts come and go.
    let gust = 0.6 + 0.4 * sin(t * 0.35 + p.x * 0.02 + p.z * 0.015);
    let a = sin(t * 1.7 + p.x * 0.45 + p.z * 0.3);
    let b = sin(t * 2.3 + p.z * 0.5 - p.x * 0.2);
    let c = sin(t * 5.1 + p.x * 1.3 + p.y * 1.1 + p.z * 0.9);
    return vec3<f32>(a + c * 0.3, c * 0.25, b + c * 0.3) * gust;
}

fn vertex(input: VertexInput) -> vec3<f32> {
    if !waving || input.material == 0u {
        return input.position;
    }
    // Wrap the world position so sin stays precise far from the origin.
    let world = (input.position + frame.camera_position) % vec3<f32>(1024.0);
    let storm = 1.0 + frame.rain * 0.8 + frame.thunder * 0.7;
    let w = wind(world, frame.time) * wind_strength * storm;
    var offset = vec3<f32>(0.0);
    if input.material == LEAVES {
        offset = w * 0.05;
    } else if input.material == PLANT {
        offset = w * vec3<f32>(0.13, 0.04, 0.13) * (1.0 - input.uv.y);
    } else if input.material == PLANT_TOP {
        offset = w * vec3<f32>(0.13, 0.04, 0.13) * (2.0 - input.uv.y);
    }
    // Less wind where the sky can't reach (caves, under roofs).
    return input.position + offset * smoothstep(0.2, 0.7, input.light.y);
}
