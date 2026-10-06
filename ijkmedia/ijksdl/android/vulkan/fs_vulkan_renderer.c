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
#include <vulkan/vulkan_android.h>
#include <android/native_window.h>
#include <android/hardware_buffer.h>

#include "libavutil/pixfmt.h"
#include "libavutil/pixdesc.h"
#include "libavutil/imgutils.h"
#include "libavcodec/mediacodec.h"
#include "libswscale/swscale.h"

#include "ijksdl/ijksdl_log.h"
#include "ijksdl/android/ijksdl_android_image_reader.h"

/* 预编译的 SPIR-V 字节码 */
#include "shaders/yuv.vert.spv.h"
#include "shaders/yuv.frag.spv.h"
#include "shaders/external.frag.spv.h"

/*
 * VK_ANDROID_external_memory_android_hardware_buffer 相关入口在 Vulkan 1.1 才
 * 由 loader 导出，为避免在老 loader 上加载失败，统一用 vkGetDeviceProcAddr 取。
 */
typedef VkResult (VKAPI_PTR *PFN_vkGetAndroidHardwareBufferPropertiesANDROID_t)(
    VkDevice, const AHardwareBuffer *, VkAndroidHardwareBufferPropertiesANDROID *);
typedef VkResult (VKAPI_PTR *PFN_vkCreateSamplerYcbcrConversion_t)(
    VkDevice, const VkSamplerYcbcrConversionCreateInfo *, const VkAllocationCallbacks *,
    VkSamplerYcbcrConversion *);
typedef void (VKAPI_PTR *PFN_vkDestroySamplerYcbcrConversion_t)(
    VkDevice, VkSamplerYcbcrConversion, const VkAllocationCallbacks *);

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

    /* ---- MediaCodec 零拷贝通路（VK_ANDROID_external_memory_android_hardware_buffer）---- */
    int instance_11;                        /* instance 是否为 Vulkan 1.1 */
    int mc_supported;                       /* 设备是否支持硬解零拷贝 */
    SDL_AndroidImageReader *mc_reader;      /* 硬解输出目标的硬件 buffer 队列 */
    PFN_vkGetAndroidHardwareBufferPropertiesANDROID_t mcGetAHBProps;
    PFN_vkCreateSamplerYcbcrConversion_t   mcCreateYcbcr;
    PFN_vkDestroySamplerYcbcrConversion_t  mcDestroyYcbcr;

    VkSamplerYcbcrConversion mc_conversion;
    VkSampler                mc_sampler;
    VkDescriptorSetLayout    mc_desc_layout;
    VkDescriptorPool         mc_desc_pool;
    VkDescriptorSet          mc_desc_set;
    VkPipelineLayout         mc_pipeline_layout;
    VkPipeline               mc_pipeline;

    VkImage        mc_image;                /* 每次 acquire 的硬件 buffer 导入 */
    VkDeviceMemory mc_mem;
    VkImageView    mc_view;
    int            mc_w;
    int            mc_h;
    uint64_t       mc_external_format;
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
        .apiVersion = VK_API_VERSION_1_1,
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

    VkResult res = vkCreateInstance(&ci, NULL, &r->instance);
    if (res == VK_SUCCESS) {
        r->instance_11 = 1;
        return res;
    }

    /* 老 loader（Vulkan 1.0）不支持 1.1：退回 1.0，硬解零拷贝通路随后自动关闭。 */
    app.apiVersion = VK_API_VERSION_1_0;
    r->instance_11 = 0;
    res = vkCreateInstance(&ci, NULL, &r->instance);
    if (res != VK_SUCCESS)
        return res;
    ALOGW("FSVulkanRenderer: Vulkan 1.1 instance unavailable, using 1.0\n");
    return res;
}

/* 设备是否导出指定扩展 */
static int device_has_extension(VkPhysicalDevice pd, const char *name)
{
    uint32_t count = 0;
    if (vkEnumerateDeviceExtensionProperties(pd, NULL, &count, NULL) != VK_SUCCESS || !count)
        return 0;

    VkExtensionProperties *exts = (VkExtensionProperties *) calloc(count, sizeof(*exts));
    if (!exts)
        return 0;

    int found = 0;
    if (vkEnumerateDeviceExtensionProperties(pd, NULL, &count, exts) == VK_SUCCESS) {
        for (uint32_t i = 0; i < count; i++) {
            if (strcmp(exts[i].extensionName, name) == 0) {
                found = 1;
                break;
            }
        }
    }
    free(exts);
    return found;
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

    /*
     * 探测 MediaCodec 零拷贝能力：
     * 需要 Vulkan 1.1（VkSamplerYcbcrConversion）＋外部显存扩展。
     * 不满足则走软解上传通路。
     */
    VkPhysicalDeviceProperties pd_props;
    vkGetPhysicalDeviceProperties(r->physical_device, &pd_props);
    int has_ahb = device_has_extension(r->physical_device,
                                       VK_ANDROID_EXTERNAL_MEMORY_ANDROID_HARDWARE_BUFFER_EXTENSION_NAME);
    int mc_ok = r->instance_11 && has_ahb &&
                (pd_props.apiVersion >= VK_API_VERSION_1_1);

    const char *extensions[2];
    uint32_t ext_count = 0;
    extensions[ext_count++] = VK_KHR_SWAPCHAIN_EXTENSION_NAME;
    if (mc_ok)
        extensions[ext_count++] = VK_ANDROID_EXTERNAL_MEMORY_ANDROID_HARDWARE_BUFFER_EXTENSION_NAME;

    VkPhysicalDeviceSamplerYcbcrConversionFeatures ycbcr_feat = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SAMPLER_YCBCR_CONVERSION_FEATURES,
        .samplerYcbcrConversion = VK_TRUE,
    };

    VkDeviceCreateInfo dci = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .pNext = mc_ok ? (void *) &ycbcr_feat : NULL,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &qci,
        .enabledExtensionCount = ext_count,
        .ppEnabledExtensionNames = extensions,
    };

    if (vkCreateDevice(r->physical_device, &dci, NULL, &r->device) != VK_SUCCESS)
        return VK_ERROR_INITIALIZATION_FAILED;

    vkGetDeviceQueue(r->device, chosen_family, 0, &r->graphics_queue);
    r->present_queue = r->graphics_queue;

    if (mc_ok) {
        r->mcGetAHBProps = (PFN_vkGetAndroidHardwareBufferPropertiesANDROID_t)(void *)
            vkGetDeviceProcAddr(r->device, "vkGetAndroidHardwareBufferPropertiesANDROID");
        r->mcCreateYcbcr = (PFN_vkCreateSamplerYcbcrConversion_t)(void *)
            vkGetDeviceProcAddr(r->device, "vkCreateSamplerYcbcrConversion");
        r->mcDestroyYcbcr = (PFN_vkDestroySamplerYcbcrConversion_t)(void *)
            vkGetDeviceProcAddr(r->device, "vkDestroySamplerYcbcrConversion");

        r->mc_supported = r->mcGetAHBProps && r->mcCreateYcbcr && r->mcDestroyYcbcr;
    }
    if (!r->mc_supported)
        ALOGW("FSVulkanRenderer: MediaCodec zero-copy path unavailable "
              "(vulkan11=%d ahb=%d api=0x%x)\n",
              r->instance_11, has_ahb, (unsigned) pd_props.apiVersion);
    else
        ALOGI("FSVulkanRenderer: MediaCodec zero-copy path available\n");

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

static VkResult build_graphics_pipeline(FSVulkanRenderer *r, const unsigned char *frag_spv,
                                        unsigned int frag_spv_len, VkPipelineLayout layout,
                                        VkPipeline *out_pipeline)
{
    VkShaderModule vert = create_shader_module(r, yuv_vert_spv, yuv_vert_spv_len);
    VkShaderModule frag = create_shader_module(r, frag_spv, frag_spv_len);
    if (!vert || !frag) {
        if (vert) vkDestroyShaderModule(r->device, vert, NULL);
        if (frag) vkDestroyShaderModule(r->device, frag, NULL);
        return VK_ERROR_INITIALIZATION_FAILED;
    }

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

    VkGraphicsPipelineCreateInfo gpi = {
        .sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .stageCount = 2, .pStages = stages,
        .pVertexInputState = &vis,
        .pInputAssemblyState = &ias,
        .pViewportState = &vps,
        .pRasterizationState = &rs,
        .pMultisampleState = &ms,
        .pColorBlendState = &cbs,
        .layout = layout,
        .renderPass = r->render_pass,
        .subpass = 0,
    };
    VkResult res = vkCreateGraphicsPipelines(r->device, VK_NULL_HANDLE, 1, &gpi, NULL, out_pipeline);

    vkDestroyShaderModule(r->device, vert, NULL);
    vkDestroyShaderModule(r->device, frag, NULL);
    return res;
}

static VkResult create_pipeline(FSVulkanRenderer *r)
{
    VkPipelineLayoutCreateInfo pli = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = 1, .pSetLayouts = &r->descriptor_layout,
    };
    if (vkCreatePipelineLayout(r->device, &pli, NULL, &r->pipeline_layout) != VK_SUCCESS)
        return VK_ERROR_INITIALIZATION_FAILED;

    return build_graphics_pipeline(r, yuv_frag_spv, yuv_frag_spv_len,
                                   r->pipeline_layout, &r->pipeline);
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

    /*
     * 硬解零拷贝需要先把 MediaCodec 的输出目标（AImageReader）准备好，
     * 解码器配置时要用它导出的 Surface。
     */
    if (r->mc_supported) {
        r->mc_reader = SDL_AndroidImageReader_create(3);
        if (!r->mc_reader) {
            ALOGW("FSVulkanRenderer: AImageReader unavailable, disabling hw zero-copy\n");
            r->mc_supported = 0;
        }
    }

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

static int draw_and_present(FSVulkanRenderer *r, VkPipeline pipeline,
                            VkPipelineLayout layout, VkDescriptorSet desc_set,
                            VkImage pre_image)
{
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

    /* 外部显存导入的 image 首次使用时需要转成可采样布局 */
    if (pre_image) {
        VkImageMemoryBarrier ib = {
            .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
            .newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .image = pre_image,
            .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 },
            .srcAccessMask = 0,
            .dstAccessMask = VK_ACCESS_SHADER_READ_BIT,
        };
        vkCmdPipelineBarrier(r->command_buffer,
                             VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                             VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                             0, 0, NULL, 0, NULL, 1, &ib);
    }

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
    vkCmdBindPipeline(r->command_buffer, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
    vkCmdBindDescriptorSets(r->command_buffer, VK_PIPELINE_BIND_POINT_GRAPHICS,
                            layout, 0, 1, &desc_set, 0, NULL);
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

/* ------------------------------------------------------------------------- */
/* MediaCodec 零拷贝：AHardwareBuffer -> VkImage（外部显存导入）               */
/* ------------------------------------------------------------------------- */

static void destroy_mc_image(FSVulkanRenderer *r)
{
    if (!r->device)
        return;
    if (r->mc_view)  { vkDestroyImageView(r->device, r->mc_view, NULL); r->mc_view  = VK_NULL_HANDLE; }
    if (r->mc_image) { vkDestroyImage(r->device, r->mc_image, NULL);    r->mc_image = VK_NULL_HANDLE; }
    if (r->mc_mem)   { vkFreeMemory(r->device, r->mc_mem, NULL);        r->mc_mem   = VK_NULL_HANDLE; }
    r->mc_w = r->mc_h = 0;
}

static void destroy_mc_resources(FSVulkanRenderer *r)
{
    if (!r->device)
        return;

    destroy_mc_image(r);

    if (r->mc_pipeline)        { vkDestroyPipeline(r->device, r->mc_pipeline, NULL);               r->mc_pipeline = VK_NULL_HANDLE; }
    if (r->mc_pipeline_layout) { vkDestroyPipelineLayout(r->device, r->mc_pipeline_layout, NULL);  r->mc_pipeline_layout = VK_NULL_HANDLE; }
    if (r->mc_desc_pool)       { vkDestroyDescriptorPool(r->device, r->mc_desc_pool, NULL);        r->mc_desc_pool = VK_NULL_HANDLE; }
    if (r->mc_desc_layout)     { vkDestroyDescriptorSetLayout(r->device, r->mc_desc_layout, NULL); r->mc_desc_layout = VK_NULL_HANDLE; }
    if (r->mc_sampler)         { vkDestroySampler(r->device, r->mc_sampler, NULL);                 r->mc_sampler = VK_NULL_HANDLE; }
    if (r->mc_conversion && r->mcDestroyYcbcr) {
        r->mcDestroyYcbcr(r->device, r->mc_conversion, NULL);
        r->mc_conversion = VK_NULL_HANDLE;
    }
    r->mc_desc_set = VK_NULL_HANDLE;
    r->mc_external_format = 0;
}

/*
 * 依据 AHardwareBuffer 的实际格式建立 YCbCr 转换 / 采样器 / descriptor /
 * 渲染管线。转换以不可变采样器绑定在 descriptor set layout 上，因此外部格式
 * 变化时必须整体重建（实际上一路视频只会发生一次）。
 */
static VkResult create_mc_pipeline(FSVulkanRenderer *r,
                                   const VkAndroidHardwareBufferFormatPropertiesANDROID *fmt)
{
    destroy_mc_resources(r);

    VkExternalFormatANDROID ext_fmt = {
        .sType = VK_STRUCTURE_TYPE_EXTERNAL_FORMAT_ANDROID,
        .externalFormat = fmt->externalFormat,
    };
    VkSamplerYcbcrConversionCreateInfo cci = {
        .sType = VK_STRUCTURE_TYPE_SAMPLER_YCBCR_CONVERSION_CREATE_INFO,
        .pNext = &ext_fmt,
        .format = VK_FORMAT_UNDEFINED,
        .ycbcrModel = fmt->suggestedYcbcrModel,
        .ycbcrRange = fmt->suggestedYcbcrRange,
        .xChromaOffset = fmt->suggestedXChromaOffset,
        .yChromaOffset = fmt->suggestedYChromaOffset,
        .chromaFilter = VK_FILTER_LINEAR,
    };
    if (r->mcCreateYcbcr(r->device, &cci, NULL, &r->mc_conversion) != VK_SUCCESS) {
        ALOGE("FSVulkanRenderer: vkCreateSamplerYcbcrConversion failed\n");
        return VK_ERROR_INITIALIZATION_FAILED;
    }

    VkSamplerYcbcrConversionInfo conv_info = {
        .sType = VK_STRUCTURE_TYPE_SAMPLER_YCBCR_CONVERSION_INFO,
        .conversion = r->mc_conversion,
    };
    VkSamplerCreateInfo si = {
        .sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
        .pNext = &conv_info,
        .magFilter = VK_FILTER_LINEAR,
        .minFilter = VK_FILTER_LINEAR,
        .mipmapMode = VK_SAMPLER_MIPMAP_MODE_NEAREST,
        .addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .maxLod = 1.0f,
    };
    if (vkCreateSampler(r->device, &si, NULL, &r->mc_sampler) != VK_SUCCESS)
        return VK_ERROR_INITIALIZATION_FAILED;

    VkDescriptorSetLayoutBinding b = {
        .binding = 0,
        .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .descriptorCount = 1,
        .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT,
        .pImmutableSamplers = &r->mc_sampler,
    };
    VkDescriptorSetLayoutCreateInfo dli = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount = 1, .pBindings = &b,
    };
    if (vkCreateDescriptorSetLayout(r->device, &dli, NULL, &r->mc_desc_layout) != VK_SUCCESS)
        return VK_ERROR_INITIALIZATION_FAILED;

    VkDescriptorPoolSize ps = {
        .type = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1,
    };
    VkDescriptorPoolCreateInfo dpi = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .maxSets = 1, .poolSizeCount = 1, .pPoolSizes = &ps,
    };
    if (vkCreateDescriptorPool(r->device, &dpi, NULL, &r->mc_desc_pool) != VK_SUCCESS)
        return VK_ERROR_INITIALIZATION_FAILED;

    VkDescriptorSetAllocateInfo dai = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .descriptorPool = r->mc_desc_pool,
        .descriptorSetCount = 1, .pSetLayouts = &r->mc_desc_layout,
    };
    if (vkAllocateDescriptorSets(r->device, &dai, &r->mc_desc_set) != VK_SUCCESS)
        return VK_ERROR_INITIALIZATION_FAILED;

    VkPipelineLayoutCreateInfo pli = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = 1, .pSetLayouts = &r->mc_desc_layout,
    };
    if (vkCreatePipelineLayout(r->device, &pli, NULL, &r->mc_pipeline_layout) != VK_SUCCESS)
        return VK_ERROR_INITIALIZATION_FAILED;

    if (build_graphics_pipeline(r, external_frag_spv, external_frag_spv_len,
                                r->mc_pipeline_layout, &r->mc_pipeline) != VK_SUCCESS)
        return VK_ERROR_INITIALIZATION_FAILED;

    r->mc_external_format = fmt->externalFormat;
    ALOGI("FSVulkanRenderer: mc pipeline ready externalFormat=0x%llx model=%d range=%d\n",
          (unsigned long long) fmt->externalFormat, (int) fmt->suggestedYcbcrModel,
          (int) fmt->suggestedYcbcrRange);
    return VK_SUCCESS;
}

/* 把一帧 AHardwareBuffer 导入为外部格式 VkImage，并绑定到 descriptor。 */
static int import_hardware_buffer(FSVulkanRenderer *r, AHardwareBuffer *ahb,
                                  const VkAndroidHardwareBufferPropertiesANDROID *props,
                                  int w, int h)
{
    destroy_mc_image(r);

    VkExternalFormatANDROID ext_fmt = {
        .sType = VK_STRUCTURE_TYPE_EXTERNAL_FORMAT_ANDROID,
        .externalFormat = r->mc_external_format,
    };
    VkImageCreateInfo ici = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .pNext = &ext_fmt,
        .imageType = VK_IMAGE_TYPE_2D,
        .format = VK_FORMAT_UNDEFINED,
        .extent = { (uint32_t) w, (uint32_t) h, 1 },
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = VK_SAMPLE_COUNT_1_BIT,
        .tiling = VK_IMAGE_TILING_OPTIMAL,
        .usage = VK_IMAGE_USAGE_SAMPLED_BIT,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
    };
    if (vkCreateImage(r->device, &ici, NULL, &r->mc_image) != VK_SUCCESS) {
        ALOGE("FSVulkanRenderer: vkCreateImage external failed\n");
        return -1;
    }

    /* AHB 每个分配都是独立内存，导入时用 dedicated 内存 */
    VkMemoryDedicatedAllocateInfo dedicated = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO,
        .image = r->mc_image,
    };
    VkImportAndroidHardwareBufferInfoANDROID import = {
        .sType = VK_STRUCTURE_TYPE_IMPORT_ANDROID_HARDWARE_BUFFER_INFO_ANDROID,
        .pNext = &dedicated,
        .buffer = ahb,
    };

    uint32_t mem_type = find_memory_type(r->physical_device, props->memoryTypeBits,
                                         VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    if (mem_type == UINT32_MAX) {
        /* 某些设备导入内存不在 DEVICE_LOCAL 类型，退化为取第一个可用位 */
        for (uint32_t i = 0; i < 32; i++) {
            if (props->memoryTypeBits & (1u << i)) { mem_type = i; break; }
        }
    }
    if (mem_type == UINT32_MAX) {
        destroy_mc_image(r);
        return -1;
    }

    VkMemoryAllocateInfo mai = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .pNext = &import,
        .allocationSize = props->allocationSize,
        .memoryTypeIndex = mem_type,
    };
    if (vkAllocateMemory(r->device, &mai, NULL, &r->mc_mem) != VK_SUCCESS) {
        ALOGE("FSVulkanRenderer: vkAllocateMemory import AHB failed\n");
        destroy_mc_image(r);
        return -1;
    }
    if (vkBindImageMemory(r->device, r->mc_image, r->mc_mem, 0) != VK_SUCCESS) {
        destroy_mc_image(r);
        return -1;
    }

    VkSamplerYcbcrConversionInfo conv_info = {
        .sType = VK_STRUCTURE_TYPE_SAMPLER_YCBCR_CONVERSION_INFO,
        .conversion = r->mc_conversion,
    };
    VkImageViewCreateInfo vci = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .pNext = &conv_info,
        .image = r->mc_image,
        .viewType = VK_IMAGE_VIEW_TYPE_2D,
        .format = VK_FORMAT_UNDEFINED,
        .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 },
    };
    if (vkCreateImageView(r->device, &vci, NULL, &r->mc_view) != VK_SUCCESS) {
        destroy_mc_image(r);
        return -1;
    }

    VkDescriptorImageInfo dii = {
        .sampler = VK_NULL_HANDLE,      /* layout 里是 immutable sampler，此字段被忽略 */
        .imageView = r->mc_view,
        .imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
    };
    VkWriteDescriptorSet write = {
        .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
        .dstSet = r->mc_desc_set,
        .dstBinding = 0,
        .descriptorCount = 1,
        .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .pImageInfo = &dii,
    };
    vkUpdateDescriptorSets(r->device, 1, &write, 0, NULL);

    r->mc_w = w;
    r->mc_h = h;
    return 0;
}

/*
 * 硬解帧显示：MediaCodec -> AImageReader(gralloc) -> VkImage 外部显存 -> 上屏。
 * 全程不做 CPU 拷贝。
 */
static int display_mc_frame(FSVulkanRenderer *r, const AVFrame *frame)
{
    if (!r->mc_supported || !r->surface_ready || !r->mc_reader)
        return -1;

    AVMediaCodecBuffer *buffer = (AVMediaCodecBuffer *) frame->data[3];
    if (!buffer)
        return -1;

    /*
     * 上一帧仍在 GPU 上使用时不能释放/重建它引用的硬件 buffer，
     * 这里等 GPU 排空再进入下一帧（后续可换成 fence 异步等待）。
     */
    vkQueueWaitIdle(r->graphics_queue);

    /* 让 MediaCodec 把这一帧渲染到 AImageReader 的输出 Surface */
    int err = av_mediacodec_release_buffer(buffer, 1);
    if (err != 0)
        ALOGW("FSVulkanRenderer: av_mediacodec_release_buffer err=%d\n", err);

    void *ahb = NULL;
    int w = 0, h = 0;
    if (SDL_AndroidImageReader_acquireLatest(r->mc_reader, &ahb, &w, &h, 100) != 0 || !ahb) {
        ALOGW("FSVulkanRenderer: acquire latest image failed\n");
        return -1;
    }

    VkAndroidHardwareBufferFormatPropertiesANDROID fmt_props;
    memset(&fmt_props, 0, sizeof(fmt_props));
    fmt_props.sType = VK_STRUCTURE_TYPE_ANDROID_HARDWARE_BUFFER_FORMAT_PROPERTIES_ANDROID;

    VkAndroidHardwareBufferPropertiesANDROID props;
    memset(&props, 0, sizeof(props));
    props.sType = VK_STRUCTURE_TYPE_ANDROID_HARDWARE_BUFFER_PROPERTIES_ANDROID;
    props.pNext = &fmt_props;

    if (r->mcGetAHBProps(r->device, (AHardwareBuffer *) ahb, &props) != VK_SUCCESS) {
        ALOGE("FSVulkanRenderer: vkGetAndroidHardwareBufferPropertiesANDROID failed\n");
        SDL_AndroidImageReader_releaseImage(r->mc_reader);
        return -1;
    }

    if (!r->mc_pipeline || r->mc_external_format != fmt_props.externalFormat) {
        if (create_mc_pipeline(r, &fmt_props) != VK_SUCCESS) {
            SDL_AndroidImageReader_releaseImage(r->mc_reader);
            return -1;
        }
    }

    if (import_hardware_buffer(r, (AHardwareBuffer *) ahb, &props, w, h) != 0) {
        SDL_AndroidImageReader_releaseImage(r->mc_reader);
        return -1;
    }

    int ret = draw_and_present(r, r->mc_pipeline, r->mc_pipeline_layout,
                               r->mc_desc_set, r->mc_image);

    SDL_AndroidImageReader_releaseImage(r->mc_reader);
    return ret;
}

int fs_vulkan_renderer_display(FSVulkanRenderer *r, const AVFrame *frame,
                               int disp_w, int disp_h,
                               int rotate_degrees, int sar_num, int sar_den)
{
    (void)disp_w; (void)disp_h; (void)rotate_degrees; (void)sar_num; (void)sar_den;
    if (!r || !r->surface_ready || !frame)
        return -1;

    /* MediaCodec 硬解：零拷贝外部显存通路 */
    if (frame->format == AV_PIX_FMT_MEDIACODEC)
        return display_mc_frame(r, frame);

    const uint8_t *y, *u, *v;
    int y_stride, u_stride, v_stride, w, h;
    if (ensure_yuv420p(r, frame, &y, &y_stride, &u, &u_stride, &v, &v_stride, &w, &h) != 0)
        return -1;

    if (ensure_yuv_textures(r, w, h) != VK_SUCCESS)
        return -1;

    if (upload_yuv420p(r, y, y_stride, u, u_stride, v, v_stride, w, h) != VK_SUCCESS)
        return -1;

    return draw_and_present(r, r->pipeline, r->pipeline_layout, r->descriptor_set,
                            VK_NULL_HANDLE);
}

void fs_vulkan_renderer_destroy(FSVulkanRenderer *r)
{
    if (!r)
        return;

    if (r->device) {
        vkDeviceWaitIdle(r->device);

        destroy_mc_resources(r);

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
    if (r->mc_reader) {
        SDL_AndroidImageReader_destroy(r->mc_reader);
        r->mc_reader = NULL;
    }
    if (r->instance)
        vkDestroyInstance(r->instance, NULL);

    free(r);
}

int fs_vulkan_renderer_is_mediacodec_supported(FSVulkanRenderer *r)
{
    return r && r->mc_supported && r->mc_reader;
}

jobject fs_vulkan_renderer_get_mediacodec_surface(JNIEnv *env, FSVulkanRenderer *r)
{
    if (!env || !r || !r->mc_supported || !r->mc_reader)
        return NULL;

    return SDL_AndroidImageReader_getSurface(env, r->mc_reader);
}
