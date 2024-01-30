#version 450

#include "common.glsl"

layout(binding = 0) uniform Uniform_Block {
    View_Data view_data;
    Scene_Data scene_data;
};
layout(binding = 1) uniform samplerCube cubeMap;

layout(location = 0) in vec3 fragTexCoord;

layout(location = 0) out vec4 outColor;

void main() {
    outColor = texture(cubeMap, fragTexCoord);
}
