#version 450

#include "common.glsl"


layout(binding = 0) uniform Uniform_Block {
    View_Data view_data;
    Scene_Data scene_data;
};

layout(binding = 1) uniform Material_Block {
    Material material;
};

layout(binding = 2) uniform sampler2D texSampler;

layout(location = 0) in vec3 fragColor;
layout(location = 1) in vec2 fragTexCoord;
layout(location = 2) in vec3 fragNormal;
layout(location = 3) in vec3 fragPos;

layout(location = 0) out vec4 outColor;

void main() {
    vec3 ambient = vec3(1, 0, 1) * 0.01;
    vec3 norm = normalize(fragNormal);
    vec3 lightDir = normalize(scene_data.main_light.position.xyz - fragPos);
    float diff = max(dot(norm, lightDir), 0.0);
    vec3 tex = vec3(texture(texSampler, fragTexCoord));
    vec3 diffuse = diff * scene_data.main_light.color.xyz * tex;

    vec3 view_dir = normalize(scene_data.view_position.xyz - fragPos);
    vec3 reflected_light = reflect(-lightDir, norm);
    float spec = pow(max(dot(view_dir, reflected_light), 0.0), 32);
    vec3 specular = spec * scene_data.main_light.color.xyz;


    vec3 result = (ambient + diffuse + specular) * vec3(material.albedo_color);
    outColor = vec4(result, 1.0);
    // outColor = vec4(1, 0, 0, 1);
}
