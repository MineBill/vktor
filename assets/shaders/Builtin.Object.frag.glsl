#version 450

layout(binding = 1) uniform sampler2D texSampler;
layout(binding = 2) uniform Material {
    bool unlit;
    vec4 albedo_color;
} material;

layout(location = 0) in vec3 fragColor;
layout(location = 1) in vec2 fragTexCoord;

layout(location = 0) out vec4 outColor;

void main() {
    outColor = vec4(1, 1, 1, 1) * texture(texSampler, fragTexCoord);
    // outColor = vec4(1, 0, 0, 1);
}
