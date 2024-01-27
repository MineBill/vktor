void process_mesh(const cgltf_mesh* mesh) {
    for (size_t i = 0; i < mesh->primitives_count; ++i) {
        const cgltf_primitive* primitive = &mesh->primitives[i];

        // Accessing vertex data
        const cgltf_accessor* position_accessor = primitive->attributes[0].data;
        const cgltf_accessor* normal_accessor = primitive->attributes[1].data;
        const cgltf_accessor* texcoord_accessor = primitive->attributes[2].data;

        // Assuming float data for simplicity (you may need to handle other formats)
        const float* positions = (const float*)position_accessor->buffer_view->buffer->data + position_accessor->offset / sizeof(float);
        const float* normals = (const float*)normal_accessor->buffer_view->buffer->data + normal_accessor->offset / sizeof(float);
        const float* texcoords = (const float*)texcoord_accessor->buffer_view->buffer->data + texcoord_accessor->offset / sizeof(float);

        // Accessing index data
        const cgltf_accessor* index_accessor = primitive->indices;
        const uint16_t* indices = (const uint16_t*)index_accessor->buffer_view->buffer->data + index_accessor->offset / sizeof(uint16_t);

        // Your code here to process the vertices and indices
        // Example: print the first vertex and index
        printf("First Vertex: (%f, %f, %f)\n", positions[0], positions[1], positions[2]);
        printf("First Normal: (%f, %f, %f)\n", normals[0], normals[1], normals[2]);
        printf("First Texcoord: (%f, %f)\n", texcoords[0], texcoords[1]);
        printf("First Index: %d\n", indices[0]);
    }
}

int main() {
    cgltf_options options = {0};
    cgltf_data* data = NULL;

    cgltf_result result = cgltf_parse_file(&options, "path/to/your/model.gltf", &data);

    if (result == cgltf_result_success) {
        // Successfully parsed the glTF file

        // Assuming there is at least one scene
        cgltf_scene* scene = &data->scenes[0];

        // Assuming there is at least one node in the scene
        cgltf_node* node = scene->nodes[0];

        // Assuming the first node has a mesh
        cgltf_mesh* mesh = node->mesh;

        // Process the mesh (extract vertices and indices)
        process_mesh(mesh);

        cgltf_free(data);
    } else {
        // Handle error
        // See cgltf_result enum in cgltf.h for possible error codes
    }

    return 0;
}
