struct View_Data {
    mat4 view;
    mat4 proj;
};

struct Main_Light {
    vec4 position;
    vec4 color;
};

struct Scene_Data {
	vec4 view_position;
    vec4 ambient_color;
	Main_Light main_light;
};

struct Material {
    vec4 albedo_color;

    float metallic;
    float roughness;
};
