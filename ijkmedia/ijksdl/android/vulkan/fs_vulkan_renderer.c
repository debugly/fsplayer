/*****************************************************************************
 * fs_vulkan_renderer.c
 *****************************************************************************
 *
 * Copyright (c) 2019 debugly <qianlongxu@gmail.com>
 *
 * This file is part of FSPlayer.
 *
 * FSPlayer is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 3 of the License, or (at your option) any later version.
 *
 * FSPlayer is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with FSPlayer; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

#include "fs_vulkan_renderer.h"

#include <stdlib.h>
#include <string.h>

#define VK_USE_PLATFORM_ANDROID_KHR 1
#include <vulkan/vulkan.h>
#include <android/native_window.h>

#include "libavutil/pixfmt.h"
#include "libavutil/pixdesc.h"
#include "libavutil/imgutils.h"
#include "libswscale/swscale.h"

#include "ijksdl/ijksdl_log.h"

/* 预编译的 SPIR-V 字节码 */
#include "shaders/yuv.vert.spv.h"
#include "shaders/yuv.frag.spv.h"

#define MAX_FRAMES_IN_FLIGHT 2

/* 全屏四边形：pos(x,y) + uv(u,v)，Vulkan NDC Y 向下 */
typedef struct {
    float pos[2];
    float uv[2];
} FSQuadVertex;

static const FSQuadVertex kQuadVertices[6] = {
    {{-1.0f, -1.0f}, {0.0f, 0.0f}},
    {{ 1.0f, -1.0f}, {1.0f, 0.0f}},
    {{ 1.0f,  1.0f}, {1.0f, 1.0f}},
    {{-1.0f, -1.0f}, {0.0f, 0.0f}},
    {{ 1.0f,  1.0f}, {1.0f, 1.0f}},
    {{-1.0f,  1.0f}, {0.0f, 1.0f}},
};

struct FSVulkanRenderer {
    VkInstance instance;
    VkPhysicalDevice physical_device;
    VkDevice device;
    VkQueue graphics_queue;
    VkQueue present_queue;
    uint32_t queue_family;

    VkSurfaceKHR surface;
    VkSwapchainKHR swapchain;
    VkFormat swapchain_format;
    VkExtent2D swapchain_extent;
    uint32_t image_count;
    VkImage *swapchain_images;
    VkImageView *swapchain_views;
    VkFramebuffer *framebuffers;

    VkRenderPass render_pass;
    VkPipelineLayout pipeline_layout;
    VkPipeline pipeline;

    VkDescriptorSetLayout descriptor_layout;
    VkDescriptorPool descriptor_pool;
    VkDescriptorSet descriptor_set;

    /* YUV 纹理（YUV420P：三个 R8 平面）*/
    VkImage y_image;
    VkDeviceMemory y_mem;
    VkImageView y_view;
    VkImage u_image;
    VkDeviceMemory u_mem;
    VkImageView u_view;
    VkImage v_image;
    VkDeviceMemory v_mem;
    VkImageView v_view;
    VkSampler sampler;
    int tex_w;
    int tex_h;

    VkBuffer staging_buffer;
    VkDeviceMemory staging_mem;
    VkDeviceSize staging_size;

    VkBuffer vertex_buffer;
    VkDeviceMemory vertex_mem;

    VkCommandPool command_pool;
    VkCommandBuffer command_buffer;

    VkSemaphore image_available;
    VkSemaphore render_finished;
    VkFence fence;

    struct SwsContext *sws_ctx;
    AVFrame *converted_frame;
    uint8_t *converted_buffer;
    int converted_buffer_size;

    ANativeWindow *window;
    int surface_ready;
};

/* ------------------------------------------------------------------------- */
/* 工具函数                                                                   */
/* ------------------------------------------------------------------------- */

static uint32_t find_memory_type(VkPhysicalDevice pd, uint32_t type_filter, VkMemoryPropertyFlags props)
{
    VkPhysicalDeviceMemoryProperties mem_props;
    vkGetPhysicalDeviceMemoryProperties(pd, &mem_props);
    for (uint32_t i = 0; i < mem_props.memoryTypeCount; i++) {
        if ((type_filter & (1u << i)) &&
            (mem_props.memoryTypes[i].propertyFlags & props) == props)
            return i;
    }
    return UINT32_MAX;
}

static VkResult create_buffer(FSVulkanRenderer *r, VkDeviceSize size,
                              VkBufferUsageFlags usage, VkMemoryPropertyFlags props,
                              VkBuffer *buffer, VkDeviceMemory *memory)
{
    VkBufferCreateInfo bi = {
        .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = size,
        .usage = usage,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
    };
    if (vkCreateBuffer(r->device, &bi, NULL, buffer) != VK_SUCCESS)
        return VK_ERROR_INITIALIZATION_FAILED;

    VkMemoryRequirements req;
    vkGetBufferMemoryRequirements(r->device, *buffer, &req);

    uint32_t mem_type = find_memory_type(r->physical_device, req.memoryTypeBits, props);
    if (mem_type == UINT32_MAX)
        return VK_ERROR_INITIALIZATION_FAILED;

    VkMemoryAllocateInfo ai = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = req.size,
        .memoryTypeIndex = mem_type,
    };
    if (vkAllocateMemory(r->device, &ai, NULL, memory) != VK_SUCCESS)
        return VK_ERROR_INITIALIZATION_FAILED;

    vkBindBufferMemory(r->device, *buffer, *memory, 0);
    return VK_SUCCESS;
}

/* ------------------------------------------------------------------------- */
/* 初始化（instance / device）                                                */
/* ------------------------------------------------------------------------- */

static VkResult create_instance(FSVulkanRenderer *r)
{
    VkApplicationInfo app = {
        .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "FSPlayer",
        .applicationVersion = VK_MAKE_VERSION(1, 0, 0),
        .pEngineName = "fsplayer",
        .engineVersion = VK_MAKE_VERSION(1, 0, 0),
        .apiVersion = VK_API_VERSION_1_0,
    };

    const char *extensions[] = {
        VK_KHR_SURFACE_EXTENSION_NAME,
        VK_KHR_ANDROID_SURFACE_EXTENSION_NAME,
    };

    VkInstanceCreateInfo ci = {
        .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &app,
        .enabledExtensionCount = 2,
        .ppEnabledExtensionNames = extensions,
    };
    return vkCreateInstance(&ci, NULL, &r->instance);
}

static VkResult create_device(FSVulkanRenderer *r)
{
    uint32_t count = 0;
    vkEnumeratePhysicalDevices(r->instance, &count, NULL);
    if (count == 0)
        return VK_ERROR_INITIALIZATION_FAILED;

    VkPhysicalDevice devices[8];
    if (count > 8)
        count = 8;
    vkEnumeratePhysicalDevices(r->instance, &count, devices);

    r->physical_device = VK_NULL_HANDLE;
    uint32_t chosen_family = UINT32_MAX;
    for (uint32_t i = 0; i < count; i++) {
        VkPhysicalDevice pd = devices[i];
        uint32_t qf_count = 0;
        vkGetPhysicalDeviceQueueFamilyProperties(pd, &qf_count, NULL);
        VkQueueFamilyProperties qf[16];
        if (qf_count > 16)
            qf_count = 16;
        vkGetPhysicalDeviceQueueFamilyProperties(pd, &qf_count, qf);

        for (uint32_t j = 0; j < qf_count; j++) {
            if (qf[j].queueFlags & VK_QUEUE_GRAPHICS_BIT) {
                r->physical_device = pd;
                chosen_family = j;
                break;
            }
        }
        if (r->physical_device)
            break;
    }
    if (!r->physical_device)
        return VK_ERROR_INITIALIZATION_FAILED;

    r->queue_family = chosen_family;

    float priority = 1.0f;
    VkDeviceQueueCreateInfo qci = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = chosen_family,
        .queueCount = 1,
        .pQueuePriorities = &priority,
    };

    const char *extensions[] = {
        VK_KHR_SWAPCHAIN_EXTENSION_NAME,
    };

    VkDeviceCreateInfo dci = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &qci,
        .enabledExtensionCount = 1,
        .ppEnabledExtensionNames = extensions,
    };

    if (vkCreateDevice(r->physical_device, &dci, NULL, &r->device) != VK_SUCCESS)
        return VK_ERROR_INITIALIZATION_FAILED;

    vkGetDeviceQueue(r->device, chosen_family, 0, &r->graphics_queue);
    r->present_queue = r->graphics_queue;
    return VK_SUCCESS;
}

/* ------------------------------------------------------------------------- */
/* surface / swapchain / 渲染资源                                             */
/* ------------------------------------------------------------------------- */

static VkResult create_image(FSVulkanRenderer *r, int w, int h, VkFormat format,
                             VkImageUsageFlags usage, VkImage *image, VkDeviceMemory *mem)
{
    VkImageCreateInfo ii = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .imageType = VK_IMAGE_TYPE_2D,
        .format = format,
        .extent = {w, h, 1},
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = VK_SAMPLE_COUNT_1_BIT,
        .tiling = VK_IMAGE_TILING_OPTIMAL,
        .usage = usage,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
    };
    if (vkCreateImage(r->device, &ii, NULL, image) != VK_SUCCESS)
        return VK_ERROR_INITIALIZATION_FAILED;

    VkMemoryRequirements req;
    vkGetImageMemoryRequirements(r->device, *image, &req);
    uint32_t mem_type = find_memory_type(r->physical_device, req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    if (mem_type == UINT32_MAX)
        return VK_ERROR_INITIALIZATION_FAILED;

    VkMemoryAllocateInfo ai = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = req.size,
        .memoryTypeIndex = mem_type,
    };
    if (vkAllocateMemory(r->device, &ai, NULL, mem) != VK_SUCCESS)
        return VK_ERROR_INITIALIZATION_FAILED;

    vkBindImageMemory(r->device, *image, *mem, 0);
    return VK_SUCCESS;
}

static VkResult create_image_view(FSVulkanRenderer *r, VkImage image, VkFormat format, VkImageView *view)
{
    VkImageViewCreateInfo vi = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .image = image,
        .viewType = VK_IMAGE_VIEW_TYPE_2D,
        .format = format,
        .subresourceRange = {
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
    };
    return vkCreateImageView(r->device, &vi, NULL, view);
}

static VkResult create_surface_swapchain(FSVulkanRenderer *r)
{
    /* 创建 Android surface */
    VkAndroidSurfaceCreateInfoKHR sci = {
        .sType = VK_STRUCTURE_TYPE_ANDROID_SURFACE_CREATE_INFO_KHR,
        .window = r->window,
    };
    if (vkCreateAndroidSurfaceKHR(r->instance, &sci, NULL, &r->surface) != VK_SUCCESS)
        return VK_ERROR_INITIALIZATION_FAILED;

    /* 查询 surface 能力 */
    VkSurfaceCapabilitiesKHR caps;
    vkGetPhysicalDeviceSurfaceCapabilitiesKHR(r->physical_device, r->surface, &caps);

    uint32_t fmt_count = 0;
    vkGetPhysicalDeviceSurfaceFormatsKHR(r->physical_device, r->surface, &fmt_count, NULL);
    VkSurfaceFormatKHR formats[16];
    if (fmt_count > 16) fmt_count = 16;
    vkGetPhysicalDeviceSurfaceFormatsKHR(r->physical_device, r->surface, &fmt_count, formats);

    VkSurfaceFormatKHR chosen = formats[0];
    for (uint32_t i = 0; i < fmt_count; i++) {
        if (formats[i].format == VK_FORMAT_R8G8B8A8_UNORM ||
            formats[i].format == VK_FORMAT_B8G8R8A8_UNORM) {
            chosen = formats[i];
            break;
        }
    }
    r->swapchain_format = chosen.format;

    VkExtent2D extent = caps.currentExtent;
    if (extent.width == UINT32_MAX) {
        extent.width = 1280;
        extent.height = 720;
    }
    r->swapchain_extent = extent;

    uint32_t image_count = caps.minImageCount + 1;
    if (caps.maxImageCount > 0 && image_count > caps.maxImageCount)
        image_count = caps.maxImageCount;
    r->image_count = image_count;

    VkSwapchainCreateInfoKHR swci = {
        .sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
        .surface = r->surface,
        .minImageCount = image_count,
        .imageFormat = chosen.format,
        .imageColorSpace = chosen.colorSpace,
        .imageExtent = extent,
        .imageArrayLayers = 1,
        .imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
        .imageSharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .preTransform = caps.currentTransform,
        .compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
        .presentMode = VK_PRESENT_MODE_FIFO_KHR,
        .clipped = VK_TRUE,
    };
    if (vkCreateSwapchainKHR(r->device, &swci, NULL, &r->swapchain) != VK_SUCCESS)
        return VK_ERROR_INITIALIZATION_FAILED;

    vkGetSwapchainImagesKHR(r->device, r->swapchain, &r->image_count, NULL);
    r->swapchain_images = calloc(r->image_count, sizeof(VkImage));
    r->swapchain_views = calloc(r->image_count, sizeof(VkImageView));
    vkGetSwapchainImagesKHR(r->device, r->swapchain, &r->image_count, r->swapchain_images);

    for (uint32_t i = 0; i < r->image_count; i++) {
        create_image_view(r, r->swapchain_images[i], r->swapchain_format, &r->swapchain_views[i]);
    }
    return VK_SUCCESS;
}

static VkResult create_render_pass(FSVulkanRenderer *r)
{
    VkAttachmentDescription color_att = {
        .format = r->swapchain_format,
        .samples = VK_SAMPLE_COUNT_1_BIT,
        .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
        .stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
        .finalLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
    };

    VkAttachmentReference color_ref = {
        .attachment = 0,
        .layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
    };

    VkSubpassDescription subpass = {
        .pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS,
        .colorAttachmentCount = 1,
        .pColorAttachments = &color_ref,
    };

    VkRenderPassCreateInfo rpi = {
        .sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        .attachmentCount = 1,
        .pAttachments = &color_att,
        .subpassCount = 1,
        .pSubpasses = &subpass,
    };
    return vkCreateRenderPass(r->device, &rpi, NULL, &r->render_pass);
}

static VkShaderModule create_shader_module(FSVulkanRenderer *r, const unsigned char *code, unsigned int len)
{
    VkShaderModuleCreateInfo ci = {
        .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = len,
        .pCode = (const uint32_t *)code,
    };
    VkShaderModule mod;
    if (vkCreateShaderModule(r->device, &ci, NULL, &mod) != VK_SUCCESS)
        return VK_NULL_HANDLE;
    return mod;
}

static VkResult create_pipeline(FSVulkanRenderer *r)
{
    VkShaderModule vert = create_shader_module(r, yuv_vert_spv, yuv_vert_spv_len);
    VkShaderModule frag = create_shader_module(r, yuv_frag_spv, yuv_frag_spv_len);
    if (!vert || !frag)
        return VK_ERROR_INITIALIZATION_FAILED;

    VkPipelineShaderStageCreateInfo stages[2] = {
        { .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
          .stage = VK_SHADER_STAGE_VERTEX_BIT, .module = vert, .pName = "main" },
        { .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
          .stage = VK_SHADER_STAGE_FRAGMENT_BIT, .module = frag, .pName = "main" },
    };

    VkVertexInputBindingDescription binding = {
        .binding = 0, .stride = sizeof(FSQuadVertex), .inputRate = VK_VERTEX_INPUT_RATE_VERTEX,
    };
    VkVertexInputAttributeDescription attrs[2] = {
        { .location = 0, .binding = 0, .format = VK_FORMAT_R32G32_SFLOAT, .offset = offsetof(FSQuadVertex, pos) },
        { .location = 1, .binding = 0, .format = VK_FORMAT_R32G32_SFLOAT, .offset = offsetof(FSQuadVertex, uv) },
    };
    VkPipelineVertexInputStateCreateInfo vis = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        .vertexBindingDescriptionCount = 1, .pVertexBindingDescriptions = &binding,
        .vertexAttributeDescriptionCount = 2, .pVertexAttributeDescriptions = attrs,
    };

    VkPipelineInputAssemblyStateCreateInfo ias = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        .topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
    };

    VkViewport viewport = { 0, 0, (float)r->swapchain_extent.width, (float)r->swapchain_extent.height, 0.0f, 1.0f };
    VkRect2D scissor = { {0, 0}, r->swapchain_extent };
    VkPipelineViewportStateCreateInfo vps = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        .viewportCount = 1, .pViewports = &viewport,
        .scissorCount = 1, .pScissors = &scissor,
    };

    VkPipelineRasterizationStateCreateInfo rs = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        .polygonMode = VK_POLYGON_MODE_FILL,
        .cullMode = VK_CULL_MODE_NONE,
        .lineWidth = 1.0f,
    };

    VkPipelineMultisampleStateCreateInfo ms = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        .rasterizationSamples = VK_SAMPLE_COUNT_1_BIT,
    };

    VkPipelineColorBlendAttachmentState blend_att = {
        .blendEnable = VK_FALSE,
        .colorWriteMask = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT |
                          VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT,
    };
    VkPipelineColorBlendStateCreateInfo cbs = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        .attachmentCount = 1, .pAttachments = &blend_att,
    };

    VkPipelineLayoutCreateInfo pli = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = 1, .pSetLayouts = &r->descriptor_layout,
    };
    if (vkCreatePipelineLayout(r->device, &pli, NULL, &r->pipeline_layout) != VK_SUCCESS)
        return VK_ERROR_INITIALIZATION_FAILED;

    VkGraphicsPipelineCreateInfo gpi = {
        .sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .stageCount = 2, .pStages = stages,
        .pVertexInputState = &vis,
        .pInputAssemblyState = &ias,
        .pViewportState = &vps,
        .pRasterizationState = &rs,
        .pMultisampleState = &ms,
        .pColorBlendState = &cbs,
        .layout = r->pipeline_layout,
        .renderPass = r->render_pass,
        .subpass = 0,
    };
    VkResult res = vkCreateGraphicsPipelines(r->device, VK_NULL_HANDLE, 1, &gpi, NULL, &r->pipeline);

    vkDestroyShaderModule(r->device, vert, NULL);
    vkDestroyShaderModule(r->device, frag, NULL);
    return res;
}

static VkResult create_descriptor_and_textures(FSVulkanRenderer *r)
{
    /* 采样器 */
    VkSamplerCreateInfo si = {
        .sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
        .magFilter = VK_FILTER_LINEAR,
        .minFilter = VK_FILTER_LINEAR,
        .mipmapMode = VK_SAMPLER_MIPMAP_MODE_LINEAR,
        .addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .maxLod = 1.0f,
    };
    if (vkCreateSampler(r->device, &si, NULL, &r->sampler) != VK_SUCCESS)
        return VK_ERROR_INITIALIZATION_FAILED;

    /* descriptor set layout：3 个 combined image sampler */
    VkDescriptorSetLayoutBinding bindings[3];
    for (int i = 0; i < 3; i++) {
        bindings[i] = (VkDescriptorSetLayoutBinding){
            .binding = i + 1,
            .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 1,
            .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT,
        };
    }
    VkDescriptorSetLayoutCreateInfo dli = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount = 3, .pBindings = bindings,
    };
    if (vkCreateDescriptorSetLayout(r->device, &dli, NULL, &r->descriptor_layout) != VK_SUCCESS)
        return VK_ERROR_INITIALIZATION_FAILED;

    VkDescriptorPoolSize pool_size = {
        .type = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 3,
    };
    VkDescriptorPoolCreateInfo dpi = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .maxSets = 1, .poolSizeCount = 1, .pPoolSizes = &pool_size,
    };
    if (vkCreateDescriptorPool(r->device, &dpi, NULL, &r->descriptor_pool) != VK_SUCCESS)
        return VK_ERROR_INITIALIZATION_FAILED;

    VkDescriptorSetAllocateInfo dai = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .descriptorPool = r->descriptor_pool,
        .descriptorSetCount = 1, .pSetLayouts = &r->descriptor_layout,
    };
    if (vkAllocateDescriptorSets(r->device, &dai, &r->descriptor_set) != VK_SUCCESS)
        return VK_ERROR_INITIALIZATION_FAILED;

    /* 顶点缓冲 */
    VkDeviceSize vbuf_size = sizeof(kQuadVertices);
    if (create_buffer(r, vbuf_size, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
                      VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                      &r->vertex_buffer, &r->vertex_mem) != VK_SUCCESS)
        return VK_ERROR_INITIALIZATION_FAILED;
    void *data;
    vkMapMemory(r->device, r->vertex_mem, 0, vbuf_size, 0, &data);
    memcpy(data, kQuadVertices, vbuf_size);
    vkUnmapMemory(r->device, r->vertex_mem);

    return VK_SUCCESS;
}

static VkResult create_framebuffers(FSVulkanRenderer *r)
{
    r->framebuffers = calloc(r->image_count, sizeof(VkFramebuffer));
    for (uint32_t i = 0; i < r->image_count; i++) {
        VkFramebufferCreateInfo fi = {
            .sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
            .renderPass = r->render_pass,
            .attachmentCount = 1,
            .pAttachments = &r->swapchain_views[i],
            .width = r->swapchain_extent.width,
            .height = r->swapchain_extent.height,
            .layers = 1,
        };
        if (vkCreateFramebuffer(r->device, &fi, NULL, &r->framebuffers[i]) != VK_SUCCESS)
            return VK_ERROR_INITIALIZATION_FAILED;
    }
    return VK_SUCCESS;
}

static VkResult create_command_and_sync(FSVulkanRenderer *r)
{
    VkCommandPoolCreateInfo cpi = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .queueFamilyIndex = r->queue_family,
    };
    if (vkCreateCommandPool(r->device, &cpi, NULL, &r->command_pool) != VK_SUCCESS)
        return VK_ERROR_INITIALIZATION_FAILED;

    VkCommandBufferAllocateInfo cai = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = r->command_pool,
        .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };
    if (vkAllocateCommandBuffers(r->device, &cai, &r->command_buffer) != VK_SUCCESS)
        return VK_ERROR_INITIALIZATION_FAILED;

    VkSemaphoreCreateInfo si = { .sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO };
    VkFenceCreateInfo fi = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
                             .flags = VK_FENCE_CREATE_SIGNALED_BIT };
    if (vkCreateSemaphore(r->device, &si, NULL, &r->image_available) != VK_SUCCESS ||
        vkCreateSemaphore(r->device, &si, NULL, &r->render_finished) != VK_SUCCESS ||
        vkCreateFence(r->device, &fi, NULL, &r->fence) != VK_SUCCESS)
        return VK_ERROR_INITIALIZATION_FAILED;
    return VK_SUCCESS;
}

/* ------------------------------------------------------------------------- */
/* 纹理上传                                                                   */
/* ------------------------------------------------------------------------- */

static VkResult ensure_yuv_textures(FSVulkanRenderer *r, int w, int h)
{
    if (r->tex_w == w && r->tex_h == h && r->y_image != VK_NULL_HANDLE)
        return VK_SUCCESS;

    /* 释放旧纹理 */
    if (r->y_view) vkDestroyImageView(r->device, r->y_view, NULL);
    if (r->u_view) vkDestroyImageView(r->device, r->u_view, NULL);
    if (r->v_view) vkDestroyImageView(r->device, r->v_view, NULL);
    if (r->y_image) vkDestroyImage(r->device, r->y_image, NULL);
    if (r->u_image) vkDestroyImage(r->device, r->u_image, NULL);
    if (r->v_image) vkDestroyImage(r->device, r->v_image, NULL);
    if (r->y_mem) vkFreeMemory(r->device, r->y_mem, NULL);
    if (r->u_mem) vkFreeMemory(r->device, r->u_mem, NULL);
    if (r->v_mem) vkFreeMemory(r->device, r->v_mem, NULL);
    r->y_view = r->u_view = r->v_view = VK_NULL_HANDLE;
    r->y_image = r->u_image = r->v_image = VK_NULL_HANDLE;
    r->y_mem = r->u_mem = r->v_mem = VK_NULL_HANDLE;

    r->tex_w = w;
    r->tex_h = h;

    VkImageUsageFlags usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT;

    if (create_image(r, w, h, VK_FORMAT_R8_UNORM, usage, &r->y_image, &r->y_mem) != VK_SUCCESS)
        return VK_ERROR_INITIALIZATION_FAILED;
    if (create_image(r, (w + 1) / 2, (h + 1) / 2, VK_FORMAT_R8_UNORM, usage, &r->u_image, &r->u_mem) != VK_SUCCESS)
        return VK_ERROR_INITIALIZATION_FAILED;
    if (create_image(r, (w + 1) / 2, (h + 1) / 2, VK_FORMAT_R8_UNORM, usage, &r->v_image, &r->v_mem) != VK_SUCCESS)
        return VK_ERROR_INITIALIZATION_FAILED;

    create_image_view(r, r->y_image, VK_FORMAT_R8_UNORM, &r->y_view);
    create_image_view(r, r->u_image, VK_FORMAT_R8_UNORM, &r->u_view);
    create_image_view(r, r->v_image, VK_FORMAT_R8_UNORM, &r->v_view);

    /* 更新 descriptor set */
    VkDescriptorImageInfo img_infos[3] = {
        { .sampler = r->sampler, .imageView = r->y_view, .imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL },
        { .sampler = r->sampler, .imageView = r->u_view, .imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL },
        { .sampler = r->sampler, .imageView = r->v_view, .imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL },
    };
    VkWriteDescriptorSet writes[3];
    for (int i = 0; i < 3; i++) {
        writes[i] = (VkWriteDescriptorSet){
            .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = r->descriptor_set,
            .dstBinding = i + 1,
            .descriptorCount = 1,
            .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .pImageInfo = &img_infos[i],
        };
    }
    vkUpdateDescriptorSets(r->device, 3, writes, 0, NULL);

    return VK_SUCCESS;
}

/* 把 YUV420P 上传到三个纹理 */
static VkResult upload_yuv420p(FSVulkanRenderer *r, const uint8_t *y, int y_stride,
                               const uint8_t *u, int u_stride,
                               const uint8_t *v, int v_stride,
                               int w, int h)
{
    VkDeviceSize y_size = (VkDeviceSize)y_stride * h;
    VkDeviceSize u_size = (VkDeviceSize)u_stride * ((h + 1) / 2);
    VkDeviceSize v_size = (VkDeviceSize)v_stride * ((h + 1) / 2);
    VkDeviceSize total = y_size + u_size + v_size;

    if (r->staging_buffer == VK_NULL_HANDLE || r->staging_size < total) {
        if (r->staging_buffer) {
            vkDestroyBuffer(r->device, r->staging_buffer, NULL);
            vkFreeMemory(r->device, r->staging_mem, NULL);
        }
        r->staging_size = total;
        if (create_buffer(r, total, VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                          VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                          &r->staging_buffer, &r->staging_mem) != VK_SUCCESS)
            return VK_ERROR_INITIALIZATION_FAILED;
    }

    void *data;
    vkMapMemory(r->device, r->staging_mem, 0, total, 0, &data);
    uint8_t *dst = (uint8_t *)data;
    for (int row = 0; row < h; row++)
        memcpy(dst + (VkDeviceSize)row * y_stride, y + (VkDeviceSize)row * y_stride, (size_t)w);
    for (int row = 0; row < (h + 1) / 2; row++)
        memcpy(dst + y_size + (VkDeviceSize)row * u_stride, u + (VkDeviceSize)row * u_stride, (size_t)((w + 1) / 2));
    for (int row = 0; row < (h + 1) / 2; row++)
        memcpy(dst + y_size + u_size + (VkDeviceSize)row * v_stride, v + (VkDeviceSize)row * v_stride, (size_t)((w + 1) / 2));
    vkUnmapMemory(r->device, r->staging_mem);

    /* 记录 copy 命令 */
    VkCommandBufferBeginInfo bi = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
                                    .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
    vkBeginCommandBuffer(r->command_buffer, &bi);

    /* Y 平面 */
    VkImageSubresourceLayers sub_y = { .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 };
    VkBufferImageCopy copy_y = {
        .bufferOffset = 0,
        .bufferRowLength = (uint32_t)y_stride,
        .bufferImageHeight = 0,
        .imageSubresource = sub_y,
        .imageOffset = {0, 0, 0},
        .imageExtent = {w, h, 1},
    };
    /* U 平面 */
    VkImageSubresourceLayers sub_u = { .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 };
    VkBufferImageCopy copy_u = {
        .bufferOffset = y_size,
        .bufferRowLength = (uint32_t)u_stride,
        .bufferImageHeight = 0,
        .imageSubresource = sub_u,
        .imageOffset = {0, 0, 0},
        .imageExtent = {(w + 1) / 2, (h + 1) / 2, 1},
    };
    /* V 平面 */
    VkImageSubresourceLayers sub_v = { .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 };
    VkBufferImageCopy copy_v = {
        .bufferOffset = y_size + u_size,
        .bufferRowLength = (uint32_t)v_stride,
        .bufferImageHeight = 0,
        .imageSubresource = sub_v,
        .imageOffset = {0, 0, 0},
        .imageExtent = {(w + 1) / 2, (h + 1) / 2, 1},
    };

    VkImageMemoryBarrier barriers[3];
    for (int i = 0; i < 3; i++) {
        barriers[i] = (VkImageMemoryBarrier){
            .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
            .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 },
        };
    }
    barriers[0].image = r->y_image;
    barriers[1].image = r->u_image;
    barriers[2].image = r->v_image;
    vkCmdPipelineBarrier(r->command_buffer, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                         VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 3, barriers);

    vkCmdCopyBufferToImage(r->command_buffer, r->staging_buffer, r->y_image,
                           VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &copy_y);
    vkCmdCopyBufferToImage(r->command_buffer, r->staging_buffer, r->u_image,
                           VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &copy_u);
    vkCmdCopyBufferToImage(r->command_buffer, r->staging_buffer, r->v_image,
                           VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &copy_v);

    for (int i = 0; i < 3; i++) {
        barriers[i].oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        barriers[i].newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    }
    vkCmdPipelineBarrier(r->command_buffer, VK_PIPELINE_STAGE_TRANSFER_BIT,
                         VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, NULL, 0, NULL, 3, barriers);

    vkEndCommandBuffer(r->command_buffer);

    VkSubmitInfo si = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .commandBufferCount = 1,
        .pCommandBuffers = &r->command_buffer,
    };
    vkQueueSubmit(r->graphics_queue, 1, &si, r->fence);
    vkWaitForFences(r->device, 1, &r->fence, VK_TRUE, UINT64_MAX);
    vkResetFences(r->device, 1, &r->fence);

    return VK_SUCCESS;
}

/* ------------------------------------------------------------------------- */
/* 公开接口                                                                   */
/* ------------------------------------------------------------------------- */

FSVulkanRenderer *fs_vulkan_renderer_create(void)
{
    FSVulkanRenderer *r = calloc(1, sizeof(FSVulkanRenderer));
    if (!r)
        return NULL;

    if (create_instance(r) != VK_SUCCESS)
        goto fail;
    if (create_device(r) != VK_SUCCESS)
        goto fail;

    /* 先创建采样器/descriptor 布局等不依赖 surface 的资源 */
    if (create_descriptor_and_textures(r) != VK_SUCCESS)
        goto fail;
    if (create_command_and_sync(r) != VK_SUCCESS)
        goto fail;

    r->converted_frame = av_frame_alloc();
    return r;

fail:
    fs_vulkan_renderer_destroy(r);
    return NULL;
}

int fs_vulkan_renderer_set_surface(FSVulkanRenderer *r, ANativeWindow *window)
{
    if (!r)
        return -1;

    if (r->window == window && r->surface_ready)
        return 0;

    r->window = window;
    if (!window) {
        r->surface_ready = 0;
        return 0;
    }

    if (create_surface_swapchain(r) != VK_SUCCESS)
        return -1;
    if (create_render_pass(r) != VK_SUCCESS)
        return -1;
    if (create_pipeline(r) != VK_SUCCESS)
        return -1;
    if (create_framebuffers(r) != VK_SUCCESS)
        return -1;

    r->surface_ready = 1;
    ALOGI("FSVulkanRenderer: surface ready, %ux%u\n", r->swapchain_extent.width, r->swapchain_extent.height);
    return 0;
}

/* 非 YUV420P 的帧先转成 YUV420P */
static int ensure_yuv420p(FSVulkanRenderer *r, const AVFrame *frame,
                          const uint8_t **y, int *y_stride,
                          const uint8_t **u, int *u_stride,
                          const uint8_t **v, int *v_stride,
                          int *w, int *h)
{
    *w = frame->width;
    *h = frame->height;

    if (frame->format == AV_PIX_FMT_YUV420P) {
        *y = frame->data[0]; *y_stride = frame->linesize[0];
        *u = frame->data[1]; *u_stride = frame->linesize[1];
        *v = frame->data[2]; *v_stride = frame->linesize[2];
        return 0;
    }

    int buf_size = av_image_get_buffer_size(AV_PIX_FMT_YUV420P, *w, *h, 1);
    if (r->converted_buffer_size < buf_size) {
        av_free(r->converted_buffer);
        r->converted_buffer = av_malloc(buf_size);
        r->converted_buffer_size = buf_size;
        if (!r->converted_buffer)
            return -1;
    }

    av_image_fill_arrays(r->converted_frame->data, r->converted_frame->linesize,
                         r->converted_buffer, AV_PIX_FMT_YUV420P, *w, *h, 1);

    r->sws_ctx = sws_getCachedContext(r->sws_ctx, *w, *h, frame->format,
                                      *w, *h, AV_PIX_FMT_YUV420P,
                                      SWS_BILINEAR, NULL, NULL, NULL);
    if (!r->sws_ctx)
        return -1;
    sws_scale(r->sws_ctx, (const uint8_t *const *)frame->data, frame->linesize,
              0, *h, r->converted_frame->data, r->converted_frame->linesize);

    *y = r->converted_frame->data[0]; *y_stride = r->converted_frame->linesize[0];
    *u = r->converted_frame->data[1]; *u_stride = r->converted_frame->linesize[1];
    *v = r->converted_frame->data[2]; *v_stride = r->converted_frame->linesize[2];
    return 0;
}

int fs_vulkan_renderer_display(FSVulkanRenderer *r, const AVFrame *frame,
                               int disp_w, int disp_h,
                               int rotate_degrees, int sar_num, int sar_den)
{
    (void)disp_w; (void)disp_h; (void)rotate_degrees; (void)sar_num; (void)sar_den;
    if (!r || !r->surface_ready || !frame)
        return -1;

    const uint8_t *y, *u, *v;
    int y_stride, u_stride, v_stride, w, h;
    if (ensure_yuv420p(r, frame, &y, &y_stride, &u, &u_stride, &v, &v_stride, &w, &h) != 0)
        return -1;

    if (ensure_yuv_textures(r, w, h) != VK_SUCCESS)
        return -1;

    if (upload_yuv420p(r, y, y_stride, u, u_stride, v, v_stride, w, h) != VK_SUCCESS)
        return -1;

    /* acquire swapchain image */
    uint32_t image_index = 0;
    VkResult res = vkAcquireNextImageKHR(r->device, r->swapchain, UINT64_MAX,
                                         r->image_available, VK_NULL_HANDLE, &image_index);
    if (res != VK_SUCCESS)
        return -1;

    vkResetCommandBuffer(r->command_buffer, 0);
    VkCommandBufferBeginInfo bi = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
                                    .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
    vkBeginCommandBuffer(r->command_buffer, &bi);

    VkClearValue clear = { .color = {{0.0f, 0.0f, 0.0f, 1.0f}} };
    VkRenderPassBeginInfo rpi = {
        .sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
        .renderPass = r->render_pass,
        .framebuffer = r->framebuffers[image_index],
        .renderArea = {{0, 0}, r->swapchain_extent},
        .clearValueCount = 1,
        .pClearValues = &clear,
    };
    vkCmdBeginRenderPass(r->command_buffer, &rpi, VK_SUBPASS_CONTENTS_INLINE);
    vkCmdBindPipeline(r->command_buffer, VK_PIPELINE_BIND_POINT_GRAPHICS, r->pipeline);
    vkCmdBindDescriptorSets(r->command_buffer, VK_PIPELINE_BIND_POINT_GRAPHICS,
                            r->pipeline_layout, 0, 1, &r->descriptor_set, 0, NULL);
    VkDeviceSize offsets = 0;
    vkCmdBindVertexBuffers(r->command_buffer, 0, 1, &r->vertex_buffer, &offsets);
    vkCmdDraw(r->command_buffer, 6, 1, 0, 0);
    vkCmdEndRenderPass(r->command_buffer);
    vkEndCommandBuffer(r->command_buffer);

    VkSubmitInfo si = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = &r->image_available,
        .pWaitDstStageMask = (VkPipelineStageFlags[]) { VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT },
        .commandBufferCount = 1,
        .pCommandBuffers = &r->command_buffer,
        .signalSemaphoreCount = 1,
        .pSignalSemaphores = &r->render_finished,
    };
    vkQueueSubmit(r->graphics_queue, 1, &si, VK_NULL_HANDLE);

    VkPresentInfoKHR pi = {
        .sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = &r->render_finished,
        .swapchainCount = 1,
        .pSwapchains = &r->swapchain,
        .pImageIndices = &image_index,
    };
    vkQueuePresentKHR(r->present_queue, &pi);

    return 0;
}

void fs_vulkan_renderer_destroy(FSVulkanRenderer *r)
{
    if (!r)
        return;

    if (r->device) {
        vkDeviceWaitIdle(r->device);

        if (r->sws_ctx) sws_freeContext(r->sws_ctx);
        if (r->converted_frame) av_frame_free(&r->converted_frame);
        av_free(r->converted_buffer);

        if (r->framebuffers) {
            for (uint32_t i = 0; i < r->image_count; i++)
                if (r->framebuffers[i]) vkDestroyFramebuffer(r->device, r->framebuffers[i], NULL);
            free(r->framebuffers);
        }
        if (r->pipeline) vkDestroyPipeline(r->device, r->pipeline, NULL);
        if (r->pipeline_layout) vkDestroyPipelineLayout(r->device, r->pipeline_layout, NULL);
        if (r->render_pass) vkDestroyRenderPass(r->device, r->render_pass, NULL);

        if (r->y_view) vkDestroyImageView(r->device, r->y_view, NULL);
        if (r->u_view) vkDestroyImageView(r->device, r->u_view, NULL);
        if (r->v_view) vkDestroyImageView(r->device, r->v_view, NULL);
        if (r->y_image) vkDestroyImage(r->device, r->y_image, NULL);
        if (r->u_image) vkDestroyImage(r->device, r->u_image, NULL);
        if (r->v_image) vkDestroyImage(r->device, r->v_image, NULL);
        if (r->y_mem) vkFreeMemory(r->device, r->y_mem, NULL);
        if (r->u_mem) vkFreeMemory(r->device, r->u_mem, NULL);
        if (r->v_mem) vkFreeMemory(r->device, r->v_mem, NULL);
        if (r->sampler) vkDestroySampler(r->device, r->sampler, NULL);
        if (r->descriptor_pool) vkDestroyDescriptorPool(r->device, r->descriptor_pool, NULL);
        if (r->descriptor_layout) vkDestroyDescriptorSetLayout(r->device, r->descriptor_layout, NULL);
        if (r->staging_buffer) vkDestroyBuffer(r->device, r->staging_buffer, NULL);
        if (r->staging_mem) vkFreeMemory(r->device, r->staging_mem, NULL);
        if (r->vertex_buffer) vkDestroyBuffer(r->device, r->vertex_buffer, NULL);
        if (r->vertex_mem) vkFreeMemory(r->device, r->vertex_mem, NULL);

        if (r->render_finished) vkDestroySemaphore(r->device, r->render_finished, NULL);
        if (r->image_available) vkDestroySemaphore(r->device, r->image_available, NULL);
        if (r->fence) vkDestroyFence(r->device, r->fence, NULL);
        if (r->command_pool) vkDestroyCommandPool(r->device, r->command_pool, NULL);

        if (r->swapchain_views) {
            for (uint32_t i = 0; i < r->image_count; i++)
                if (r->swapchain_views[i]) vkDestroyImageView(r->device, r->swapchain_views[i], NULL);
            free(r->swapchain_views);
        }
        if (r->swapchain_images) free(r->swapchain_images);
        if (r->swapchain) vkDestroySwapchainKHR(r->device, r->swapchain, NULL);
        if (r->surface) vkDestroySurfaceKHR(r->instance, r->surface, NULL);

        vkDestroyDevice(r->device, NULL);
    }
    if (r->instance)
        vkDestroyInstance(r->instance, NULL);

    free(r);
}
