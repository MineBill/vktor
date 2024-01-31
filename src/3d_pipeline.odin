package main
import vk "vendor:vulkan"

Mesh_Pipeline :: struct {
    using pipeline:     Pipeline,
    swapchain:          ^Swapchain,

    pipeline_layout:    vk.PipelineLayout,
    descriptor_sets:    []vk.DescriptorSet,
    descriptor_layout:  vk.DescriptorSetLayout,
    descriptor_pool:    vk.DescriptorPool,

    uniform_buffers:        []Buffer,
    uniform_mapped_buffers: []rawptr,
}
