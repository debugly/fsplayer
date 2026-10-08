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

#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <math.h>

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
#include "shaders/sub.vert.spv.h"
#include "shaders/sub.frag.spv.h"
#include "shaders/blur.vert.spv.h"
#include "shaders/blur.frag.spv.h"

#include "ijksdl/ijksdl_gpu.h"
#include "fs_vulkan_internal.h"

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
    int swapchain_dirty;    /* 需要（下一帧安全点）重建 surface/swapchain，例如 surface 尺寸变了或 acquire/present 返回 OUT_OF_DATE/SUBOPTIMAL */

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

    /* ---- 字幕叠加层（SDL_GPU 产出的纹理，由 vout 每帧塞进来）---- */
    FSVulkanContext       ctx;                /* 暴露给 SDL_GPU 层的设备上下文 */
    SDL_TextureOverlay   *sub_overlay;
    VkPipeline            sub_pipeline;
    VkPipelineLayout      sub_pipeline_layout;
    VkDescriptorSetLayout sub_desc_layout;
    VkDescriptorPool      sub_desc_pool;
    VkDescriptorSet       sub_desc_set;
    VkBuffer              sub_quad_buffer;
    VkDeviceMemory        sub_quad_mem;
    int                   sub_desc_pending;   /* overlay 变了，描述符待重写 */

    /*
     * 缩放/旋转/letterbox：视频和字幕共用同一套 NDC 变换，
     * 字幕才会跟着视频一起缩放、旋转、留黑边（见 compute_video_transform）。
     */
    int   scaling_mode;             /* FSScalingMode */
    float x_rotate_degrees;         /* 手动 X 轴旋转（度），对齐 iOS xRotateDegrees */
    float y_rotate_degrees;         /* 手动 Y 轴旋转（度） */
    float z_rotate_degrees;         /* 手动 Z 轴旋转（度）；最终与自动 Z 旋转相加 */
    float video_rect[4];            /* x0, y0, x1, y1（NDC） */
    float video_uvmat[4];           /* 2x2 列主序，uv' = M * (uv - 0.5) + 0.5（保留兼容） */
    float video_posmat[4];          /* 2x2 列主序，pos' = M * pos：三轴旋转（含自动 Z） */

    /* 上一帧的画面：快照要用同样的管线和参数重画一次 */
    int              video_w, video_h;      /* 解码帧原始尺寸 */
    int              last_rot;              /* 归一化到 0/90/180/270 */
    VkPipeline       last_pipeline;
    VkPipelineLayout last_layout;
    VkDescriptorSet  last_desc_set;

    /* ---- 高斯模糊背景（对齐 iOS backgroundImage/BlurIterations/BlurSigma） ---- */
    pthread_mutex_t bg_mutex;          /* 保护下面三个“挂起请求”字段 */
    void           *bg_pending_pixels; /* 待上传的 RGBA8888（App 线程给，渲染线程取） */
    int             bg_pending_w, bg_pending_h;
    int             bg_pending_clear;  /* 1 = 要清掉背景 */
    int             bg_pending_params; /* 参数变了，要重跑模糊 */
    volatile int    bg_iterations;
    volatile float  bg_sigma;
    int             bg_w, bg_h;        /* 工作分辨率（最长边 <= 400，和 iOS 一致） */
    #define FS_BG_SLOT_SRC  0          /* 原始图 */
    #define FS_BG_SLOT_A    1          /* ping */
    #define FS_BG_SLOT_B    2          /* pong */
    VkImage         bg_img[3];
    VkDeviceMemory  bg_mem[3];
    VkImageView     bg_view[3];
    VkFramebuffer   bg_fb[2];          /* ping/pong 各自的 framebuffer */
    int             bg_layout[3];      /* 每个槽当前的 layout */
    VkDescriptorSet bg_desc_set[3];
    VkDescriptorSetLayout bg_desc_layout;
    VkDescriptorPool bg_desc_pool;
    VkSampler       bg_sampler;
    VkRenderPass    bg_pass;
    VkPipeline      bg_blur_pipeline;
    VkPipelineLayout bg_blur_layout;
    VkPipeline      bg_draw_pipeline;  /* 铺满整个显示区的合成 */
    VkPipelineLayout bg_draw_layout;
    VkBuffer        bg_staging;
    VkDeviceMemory  bg_staging_mem;
    VkDeviceSize    bg_staging_size;
    VkBuffer        bg_quad_buffer;    /* 自己的 0..1 全屏四边形，不依赖字幕那套 */
    VkDeviceMemory  bg_quad_mem;
    int             bg_ready;          /* 模糊结果可用 */
    int             bg_result_slot;    /* 结果在哪个槽 */

    /* ---- 色彩调整（亮度/饱和度/对比度，对齐 iOS 的 colorPreference）---- */
    volatile float color_brightness;
    volatile float color_saturation;
    volatile float color_contrast;
    volatile int   color_adjust_on;    /* 三者都是 1.0 时为 0，走原样输出 */
    float          bg_color[3];        /* 无视频区域的背景色（iOS 的 setBackgroundColor）*/

    /* ---- HDR / 10bit（对齐 iOS 的 FSMetalPipelineMeta + hdr2sdr）---- */
    int tex10bit;            /* 视频纹理是 R16_UNORM（10bit 输入）还是 R8_UNORM */
    int hdr_content;         /* 当前帧是 BT.2020（iOS 判定 HDR 的唯一依据）*/
    int hdr_transfer;        /* 0 线性 / 1 PQ / 2 HLG，和 iOS FSColorTransferFunc 一致 */
    int hdr_full_range;      /* 帧的 color_range 是 full */
    int hdr_display;         /* 直显 HDR（= 内容 HDR && 允许 && 屏支持）*/
    int allow_hdr_display;   /* iOS 的 allowHDRDirectDisplay，默认允许 */
    int display_hdr_support; /* 当前 swapchain 能否直接输出 HDR（8bit UNORM 时为 0）*/

    /* ---- 快照 ---- */
    volatile int   snapshot_type;      /* -1 = 没有请求 */
    volatile int   snapshot_ready;     /* 0 等待 / 1 完成 / -1 失败 */
    int            snapshot_w, snapshot_h;
    void          *snapshot_pixels;    /* RGBA8888，交给调用方 free */
    VkRenderPass   snap_pass;
    VkImage        snap_image;
    VkDeviceMemory snap_mem;
    VkImageView    snap_view;
    VkFramebuffer  snap_framebuffer;
    VkBuffer       snap_buffer;
    VkDeviceMemory snap_buffer_mem;
    VkDeviceSize   snap_buffer_size;
    int            snap_w, snap_h;
    int            snap_recorded;      /* 本帧录了快照 pass */
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
    /* 动态视口：快照要把同一套管线画到别的分辨率的离屏图上 */
    VkDynamicState dyn_states[] = { VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR };
    VkPipelineDynamicStateCreateInfo ds = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        .dynamicStateCount = 2, .pDynamicStates = dyn_states,
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
        .pDynamicState = &ds,
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
    /* push constant：顶点侧 rect(4) + uvmat(4) + posmat(4) 做缩放/letterbox/旋转；
       片元侧再接一段色彩调整（brightness, saturation, contrast, on），
       两段范围不能重叠，所以后者从 offset 48 开始。 */
    VkPushConstantRange pcr[2] = {
        {
            .stageFlags = VK_SHADER_STAGE_VERTEX_BIT,
            .offset = 0,
            .size = sizeof(float) * 12,
        },
        {
            .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT,
            .offset = sizeof(float) * 12,
            .size = sizeof(float) * 8,   /* 色彩调整 + HDR 参数 */
        },
    };
    VkPipelineLayoutCreateInfo pli = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = 1, .pSetLayouts = &r->descriptor_layout,
        .pushConstantRangeCount = 2, .pPushConstantRanges = pcr,
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

static VkResult ensure_yuv_textures(FSVulkanRenderer *r, int w, int h, int is10bit)
{
    if (r->tex_w == w && r->tex_h == h && r->tex10bit == is10bit && r->y_image != VK_NULL_HANDLE)
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
    r->tex10bit = is10bit;

    /* 10bit（HDR/10bit SDR）用 R16_UNORM，采样值仍然是 [0,1] 归一的码值 */
    VkFormat plane_fmt = is10bit ? VK_FORMAT_R16_UNORM : VK_FORMAT_R8_UNORM;
    VkImageUsageFlags usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT;

    if (create_image(r, w, h, plane_fmt, usage, &r->y_image, &r->y_mem) != VK_SUCCESS)
        return VK_ERROR_INITIALIZATION_FAILED;
    if (create_image(r, (w + 1) / 2, (h + 1) / 2, plane_fmt, usage, &r->u_image, &r->u_mem) != VK_SUCCESS)
        return VK_ERROR_INITIALIZATION_FAILED;
    if (create_image(r, (w + 1) / 2, (h + 1) / 2, plane_fmt, usage, &r->v_image, &r->v_mem) != VK_SUCCESS)
        return VK_ERROR_INITIALIZATION_FAILED;

    create_image_view(r, r->y_image, plane_fmt, &r->y_view);
    create_image_view(r, r->u_image, plane_fmt, &r->u_view);
    create_image_view(r, r->v_image, plane_fmt, &r->v_view);

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

/*
 * 把 YUV420P（bpp=1，8bit）或 YUV420P10LE（bpp=2，10bit）上传到三个平面纹理。
 * 注意 VkBufferImageCopy.bufferRowLength 的单位是**纹素**，所以 10bit 要除以 2。
 */
static VkResult upload_yuv420p(FSVulkanRenderer *r, const uint8_t *y, int y_stride,
                               const uint8_t *u, int u_stride,
                               const uint8_t *v, int v_stride,
                               int w, int h, int bpp)
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
    const size_t y_row = (size_t)w * bpp;
    const size_t c_row = (size_t)((w + 1) / 2) * bpp;
    for (int row = 0; row < h; row++)
        memcpy(dst + (VkDeviceSize)row * y_stride, y + (VkDeviceSize)row * y_stride, y_row);
    for (int row = 0; row < (h + 1) / 2; row++)
        memcpy(dst + y_size + (VkDeviceSize)row * u_stride, u + (VkDeviceSize)row * u_stride, c_row);
    for (int row = 0; row < (h + 1) / 2; row++)
        memcpy(dst + y_size + u_size + (VkDeviceSize)row * v_stride, v + (VkDeviceSize)row * v_stride, c_row);
    vkUnmapMemory(r->device, r->staging_mem);

    /* 记录 copy 命令 */
    VkCommandBufferBeginInfo bi = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
                                    .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
    vkBeginCommandBuffer(r->command_buffer, &bi);

    /* Y 平面 */
    VkImageSubresourceLayers sub_y = { .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 };
    VkBufferImageCopy copy_y = {
        .bufferOffset = 0,
        .bufferRowLength = (uint32_t)(y_stride / bpp),
        .bufferImageHeight = 0,
        .imageSubresource = sub_y,
        .imageOffset = {0, 0, 0},
        .imageExtent = {w, h, 1},
    };
    /* U 平面 */
    VkImageSubresourceLayers sub_u = { .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 };
    VkBufferImageCopy copy_u = {
        .bufferOffset = y_size,
        .bufferRowLength = (uint32_t)(u_stride / bpp),
        .bufferImageHeight = 0,
        .imageSubresource = sub_u,
        .imageOffset = {0, 0, 0},
        .imageExtent = {(w + 1) / 2, (h + 1) / 2, 1},
    };
    /* V 平面 */
    VkImageSubresourceLayers sub_v = { .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 };
    VkBufferImageCopy copy_v = {
        .bufferOffset = y_size + u_size,
        .bufferRowLength = (uint32_t)(v_stride / bpp),
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
/* 字幕叠加层                                                                 */
/* ------------------------------------------------------------------------- */

/* 单位四边形（0..1 + uv），字幕矩形由 push constant 给出 */
static const FSQuadVertex kSubQuadVertices[6] = {
    {{0.0f, 0.0f}, {0.0f, 0.0f}},
    {{1.0f, 0.0f}, {1.0f, 0.0f}},
    {{1.0f, 1.0f}, {1.0f, 1.0f}},
    {{0.0f, 0.0f}, {0.0f, 0.0f}},
    {{1.0f, 1.0f}, {1.0f, 1.0f}},
    {{0.0f, 1.0f}, {0.0f, 1.0f}},
};

const FSVulkanContext *fs_vulkan_renderer_context(FSVulkanRenderer *r)
{
    if (!r)
        return NULL;
    r->ctx.physical_device  = r->physical_device;
    r->ctx.device           = r->device;
    r->ctx.queue            = r->graphics_queue;
    r->ctx.queue_family     = r->queue_family;
    r->ctx.command_pool     = r->command_pool;
    r->ctx.swapchain_format = r->swapchain_format;
    return &r->ctx;
}

/* overlay 变了 -> 重写描述符（只能在没有在飞的命令缓冲引用它时做） */
static void update_sub_descriptor(FSVulkanRenderer *r)
{
    if (!r->sub_desc_pending)
        return;
    if (!r->sub_desc_set || !r->sub_overlay) {
        r->sub_desc_pending = 0;
        return;
    }

    FSVulkanSubTexture *tex = r->sub_overlay->getTexture(r->sub_overlay);
    if (!tex || !tex->view) {
        /* 纹理还没准备好，下一帧再试 */
        return;
    }

    VkDescriptorImageInfo ii = {
        .imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        .imageView = tex->view,
        .sampler = r->sampler,
    };
    VkWriteDescriptorSet wr = {
        .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
        .dstSet = r->sub_desc_set,
        .dstBinding = 1,
        .descriptorCount = 1,
        .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .pImageInfo = &ii,
    };
    vkUpdateDescriptorSets(r->device, 1, &wr, 0, NULL);
    r->sub_desc_pending = 0;
}

/* 建字幕管线：单纹理 + 预乘 alpha 混合 */
static int create_sub_resources(FSVulkanRenderer *r)
{
    if (r->sub_pipeline)
        return 0;
    if (r->swapchain_extent.width == 0)
        return -1;

    VkShaderModule vs = create_shader_module(r, sub_vert_spv, sub_vert_spv_len);
    VkShaderModule fs = create_shader_module(r, sub_frag_spv, sub_frag_spv_len);
    if (!vs || !fs)
        goto fail;

    {
        VkDescriptorSetLayoutBinding b = {
            .binding = 1,
            .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 1,
            .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT,
        };
        VkDescriptorSetLayoutCreateInfo dli = {
            .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .bindingCount = 1, .pBindings = &b,
        };
        if (vkCreateDescriptorSetLayout(r->device, &dli, NULL, &r->sub_desc_layout) != VK_SUCCESS)
            goto fail;

        VkDescriptorPoolSize ps = {
            .type = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 1,
        };
        VkDescriptorPoolCreateInfo pci = {
            .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .maxSets = 1,
            .poolSizeCount = 1, .pPoolSizes = &ps,
        };
        if (vkCreateDescriptorPool(r->device, &pci, NULL, &r->sub_desc_pool) != VK_SUCCESS)
            goto fail;

        VkDescriptorSetAllocateInfo dai = {
            .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .descriptorPool = r->sub_desc_pool,
            .descriptorSetCount = 1,
            .pSetLayouts = &r->sub_desc_layout,
        };
        if (vkAllocateDescriptorSets(r->device, &dai, &r->sub_desc_set) != VK_SUCCESS)
            goto fail;

        VkPushConstantRange pcr = {
            .stageFlags = VK_SHADER_STAGE_VERTEX_BIT,
            .offset = 0,
            .size = sizeof(float) * 12,   /* rect + uvmat + posmat，和视频用同一套变换 */
        };
        VkPipelineLayoutCreateInfo pli = {
            .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .setLayoutCount = 1, .pSetLayouts = &r->sub_desc_layout,
            .pushConstantRangeCount = 1, .pPushConstantRanges = &pcr,
        };
        if (vkCreatePipelineLayout(r->device, &pli, NULL, &r->sub_pipeline_layout) != VK_SUCCESS)
            goto fail;
    }

    {
        VkPipelineShaderStageCreateInfo stages[2] = {
            { .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
              .stage = VK_SHADER_STAGE_VERTEX_BIT, .module = vs, .pName = "main" },
            { .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
              .stage = VK_SHADER_STAGE_FRAGMENT_BIT, .module = fs, .pName = "main" },
        };
        VkVertexInputBindingDescription binding = {
            .binding = 0, .stride = sizeof(FSQuadVertex), .inputRate = VK_VERTEX_INPUT_RATE_VERTEX,
        };
        VkVertexInputAttributeDescription attrs[2] = {
            { .location = 0, .binding = 0, .format = VK_FORMAT_R32G32_SFLOAT,
              .offset = offsetof(FSQuadVertex, pos) },
            { .location = 1, .binding = 0, .format = VK_FORMAT_R32G32_SFLOAT,
              .offset = offsetof(FSQuadVertex, uv) },
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
        VkViewport viewport = { 0, 0, (float)r->swapchain_extent.width,
                                    (float)r->swapchain_extent.height, 0.0f, 1.0f };
        VkRect2D scissor = { {0, 0}, r->swapchain_extent };
        VkPipelineViewportStateCreateInfo vps = {
            .sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
            .viewportCount = 1, .pViewports = &viewport,
            .scissorCount = 1, .pScissors = &scissor,
        };
        VkDynamicState dyn_states[] = { VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR };
        VkPipelineDynamicStateCreateInfo ds = {
            .sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
            .dynamicStateCount = 2, .pDynamicStates = dyn_states,
        };
        VkPipelineRasterizationStateCreateInfo rs = {
            .sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
            .polygonMode = VK_POLYGON_MODE_FILL, .cullMode = VK_CULL_MODE_NONE, .lineWidth = 1.0f,
        };
        VkPipelineMultisampleStateCreateInfo ms = {
            .sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
            .rasterizationSamples = VK_SAMPLE_COUNT_1_BIT,
        };
        /* 字幕位图已经预乘，源因子 ONE（对齐 Metal 字幕管线） */
        VkPipelineColorBlendAttachmentState blend = {
            .blendEnable = VK_TRUE,
            .srcColorBlendFactor = VK_BLEND_FACTOR_ONE,
            .dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
            .colorBlendOp = VK_BLEND_OP_ADD,
            .srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE,
            .dstAlphaBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
            .alphaBlendOp = VK_BLEND_OP_ADD,
            .colorWriteMask = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT |
                              VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT,
        };
        VkPipelineColorBlendStateCreateInfo cbs = {
            .sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .attachmentCount = 1, .pAttachments = &blend,
        };
        VkGraphicsPipelineCreateInfo gpi = {
            .sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            .stageCount = 2, .pStages = stages,
            .pVertexInputState = &vis,
            .pInputAssemblyState = &ias,
            .pViewportState = &vps,
            .pDynamicState = &ds,
            .pRasterizationState = &rs,
            .pMultisampleState = &ms,
            .pColorBlendState = &cbs,
            .layout = r->sub_pipeline_layout,
            .renderPass = r->render_pass,
            .subpass = 0,
        };
        if (vkCreateGraphicsPipelines(r->device, VK_NULL_HANDLE, 1, &gpi, NULL,
                                      &r->sub_pipeline) != VK_SUCCESS)
            goto fail;
    }

    {
        VkDeviceSize vbuf_size = sizeof(kSubQuadVertices);
        if (create_buffer(r, vbuf_size, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
                          VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                          &r->sub_quad_buffer, &r->sub_quad_mem) != VK_SUCCESS)
            goto fail;
        void *data = NULL;
        vkMapMemory(r->device, r->sub_quad_mem, 0, vbuf_size, 0, &data);
        memcpy(data, kSubQuadVertices, vbuf_size);
        vkUnmapMemory(r->device, r->sub_quad_mem);
    }

    vkDestroyShaderModule(r->device, vs, NULL);
    vkDestroyShaderModule(r->device, fs, NULL);
    ALOGI("FSVulkanRenderer: subtitle pipeline ready\n");
    return 0;

fail:
    if (vs) vkDestroyShaderModule(r->device, vs, NULL);
    if (fs) vkDestroyShaderModule(r->device, fs, NULL);
    ALOGE("FSVulkanRenderer: subtitle pipeline create failed\n");
    return -1;
}

static void destroy_sub_resources(FSVulkanRenderer *r)
{
    if (r->sub_overlay) {
        SDL_TextureOverlay_Release(&r->sub_overlay);
    }
    if (r->sub_pipeline)        vkDestroyPipeline(r->device, r->sub_pipeline, NULL);
    if (r->sub_pipeline_layout) vkDestroyPipelineLayout(r->device, r->sub_pipeline_layout, NULL);
    if (r->sub_desc_pool)       vkDestroyDescriptorPool(r->device, r->sub_desc_pool, NULL);
    if (r->sub_desc_layout)     vkDestroyDescriptorSetLayout(r->device, r->sub_desc_layout, NULL);
    if (r->sub_quad_buffer)     vkDestroyBuffer(r->device, r->sub_quad_buffer, NULL);
    if (r->sub_quad_mem)        vkFreeMemory(r->device, r->sub_quad_mem, NULL);
    r->sub_pipeline = VK_NULL_HANDLE;
    r->sub_pipeline_layout = VK_NULL_HANDLE;
    r->sub_desc_pool = VK_NULL_HANDLE;
    r->sub_desc_layout = VK_NULL_HANDLE;
    r->sub_desc_set = VK_NULL_HANDLE;
    r->sub_quad_buffer = VK_NULL_HANDLE;
    r->sub_quad_mem = VK_NULL_HANDLE;
    r->sub_desc_pending = 0;
}

void fs_vulkan_renderer_set_sub_overlay(FSVulkanRenderer *r, struct SDL_TextureOverlay *overlay)
{
    if (!r)
        return;
    if (r->sub_overlay == overlay)
        return;

    if (r->sub_overlay)
        SDL_TextureOverlay_Release(&r->sub_overlay);

    r->sub_overlay = SDL_TextureOverlay_Retain(overlay);
    r->sub_desc_pending = 1;
}

struct SDL_TextureOverlay *fs_vulkan_renderer_get_sub_overlay(FSVulkanRenderer *r)
{
    if (!r || !r->sub_overlay)
        return NULL;
    return SDL_TextureOverlay_Retain(r->sub_overlay);
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

    r->snapshot_type = -1;
    pthread_mutex_init(&r->bg_mutex, NULL);
    r->bg_iterations = 3;      /* 和 iOS 的默认值一致 */
    r->bg_sigma = 30.0f;
    r->color_brightness = 1.0f;
    r->color_saturation = 1.0f;
    r->color_contrast   = 1.0f;
    r->color_adjust_on  = 0;   /* 默认不变，走原样输出 */
    r->bg_color[0] = r->bg_color[1] = r->bg_color[2] = 0.0f;   /* 默认黑底，和 iOS 一致 */
    r->tex10bit  = 0;
    r->hdr_content = 0;
    r->hdr_transfer = 0;
    r->hdr_full_range = 0;
    r->hdr_display = 0;
    r->allow_hdr_display = 1;   /* iOS 的默认值是 YES */
    r->display_hdr_support = 0; /* swapchain 是 8bit UNORM，直接输出 HDR 需要 10bit/浮点交换链 */
    r->bg_result_slot = -1;
    r->scaling_mode = FS_SCALING_MODE_ASPECT_FIT;
    r->x_rotate_degrees = 0.0f;
    r->y_rotate_degrees = 0.0f;
    r->z_rotate_degrees = 0.0f;
    r->video_rect[0] = -1.0f; r->video_rect[1] = -1.0f;
    r->video_rect[2] =  1.0f; r->video_rect[3] =  1.0f;
    r->video_uvmat[0] = 1.0f; r->video_uvmat[1] = 0.0f;
    r->video_uvmat[2] = 0.0f; r->video_uvmat[3] = 1.0f;
    r->video_posmat[0] = 1.0f; r->video_posmat[1] = 0.0f;
    r->video_posmat[2] = 0.0f; r->video_posmat[3] = 1.0f;
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

    /* 字幕管线依赖 swapchain 尺寸（viewpoint 固定），失败只降级为无字幕 */
    if (create_sub_resources(r) != 0)
        ALOGW("FSVulkanRenderer: subtitle disabled (pipeline create failed)\n");

    r->surface_ready = 1;
    ALOGI("FSVulkanRenderer: surface ready, %ux%u\n", r->swapchain_extent.width, r->swapchain_extent.height);
    return 0;
}

/* 非 YUV420P 的帧先转成 YUV420P */
static int ensure_yuv420p(FSVulkanRenderer *r, const AVFrame *frame,
                          const uint8_t **y, int *y_stride,
                          const uint8_t **u, int *u_stride,
                          const uint8_t **v, int *v_stride,
                          int *w, int *h, int *is10bit)
{
    *w = frame->width;
    *h = frame->height;
    *is10bit = 0;

    if (frame->format == AV_PIX_FMT_YUV420P || frame->format == AV_PIX_FMT_YUV420P10LE) {
        *is10bit = (frame->format == AV_PIX_FMT_YUV420P10LE) ? 1 : 0;
        *y = frame->data[0]; *y_stride = frame->linesize[0];
        *u = frame->data[1]; *u_stride = frame->linesize[1];
        *v = frame->data[2]; *v_stride = frame->linesize[2];
        return 0;
    }

    /* 其它格式转平面：10bit 源（HDR 常见 p010）转 YUV420P10LE，别掉到 8bit 丢精度 */
    const AVPixFmtDescriptor *desc = av_pix_fmt_desc_get(frame->format);
    int src10 = (desc && desc->comp[0].depth > 8) ? 1 : 0;
    *is10bit = src10;
    enum AVPixelFormat dst_fmt = src10 ? AV_PIX_FMT_YUV420P10LE : AV_PIX_FMT_YUV420P;

    int buf_size = av_image_get_buffer_size(dst_fmt, *w, *h, 1);
    if (r->converted_buffer_size < buf_size) {
        av_free(r->converted_buffer);
        r->converted_buffer = av_malloc(buf_size);
        r->converted_buffer_size = buf_size;
        if (!r->converted_buffer)
            return -1;
    }

    av_image_fill_arrays(r->converted_frame->data, r->converted_frame->linesize,
                         r->converted_buffer, dst_fmt, *w, *h, 1);

    r->sws_ctx = sws_getCachedContext(r->sws_ctx, *w, *h, frame->format,
                                      *w, *h, dst_fmt,
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


/* 背景模糊 + 合成（实现在文件后面，主 pass / 快照 pass 都要用） */
static void background_prepare(FSVulkanRenderer *r);
static void draw_background(FSVulkanRenderer *r);

/* ------------------------------------------------------------------------- */
/* 快照：把当前帧离屏重画一次并回读成 RGBA                                        */
/* ------------------------------------------------------------------------- */

static void destroy_snapshot_target(FSVulkanRenderer *r)
{
    if (!r->device)
        return;
    if (r->snap_framebuffer)  { vkDestroyFramebuffer(r->device, r->snap_framebuffer, NULL); r->snap_framebuffer = VK_NULL_HANDLE; }
    if (r->snap_view)         { vkDestroyImageView(r->device, r->snap_view, NULL);         r->snap_view = VK_NULL_HANDLE; }
    if (r->snap_image)        { vkDestroyImage(r->device, r->snap_image, NULL);            r->snap_image = VK_NULL_HANDLE; }
    if (r->snap_mem)          { vkFreeMemory(r->device, r->snap_mem, NULL);                r->snap_mem = VK_NULL_HANDLE; }
    if (r->snap_buffer)       { vkDestroyBuffer(r->device, r->snap_buffer, NULL);          r->snap_buffer = VK_NULL_HANDLE; }
    if (r->snap_buffer_mem)   { vkFreeMemory(r->device, r->snap_buffer_mem, NULL);         r->snap_buffer_mem = VK_NULL_HANDLE; }
    r->snap_buffer_size = 0;
    r->snap_w = r->snap_h = 0;
}

/*
 * 快照的 render pass：附件格式必须和 swapchain 一致，现有的视频/字幕管线才和它兼容
 * （Vulkan 的 render pass 兼容性只看附件格式/采样数/子 pass 结构，不看 load/store 与 layout）。
 */
static VkResult create_snapshot_resources(FSVulkanRenderer *r, int w, int h)
{
    if (w <= 0 || h <= 0)
        return VK_ERROR_INITIALIZATION_FAILED;

    if (!r->snap_pass) {
        VkAttachmentDescription att = {
            .format = r->swapchain_format,
            .samples = VK_SAMPLE_COUNT_1_BIT,
            .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
            .stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
            .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
            .finalLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        };
        VkAttachmentReference ref = { 0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
        VkSubpassDescription sub = {
            .pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS,
            .colorAttachmentCount = 1, .pColorAttachments = &ref,
        };
        VkRenderPassCreateInfo rpci = {
            .sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
            .attachmentCount = 1, .pAttachments = &att,
            .subpassCount = 1, .pSubpasses = &sub,
        };
        if (vkCreateRenderPass(r->device, &rpci, NULL, &r->snap_pass) != VK_SUCCESS)
            return VK_ERROR_INITIALIZATION_FAILED;
    }

    if (r->snap_framebuffer && r->snap_w == w && r->snap_h == h)
        return VK_SUCCESS;

    destroy_snapshot_target(r);

    VkDeviceSize size = (VkDeviceSize)w * h * 4;
    if (create_image(r, w, h, r->swapchain_format,
                     VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
                     &r->snap_image, &r->snap_mem) != VK_SUCCESS)
        goto fail;
    if (create_image_view(r, r->snap_image, r->swapchain_format, &r->snap_view) != VK_SUCCESS)
        goto fail;
    {
        VkFramebufferCreateInfo fci = {
            .sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
            .renderPass = r->snap_pass,
            .attachmentCount = 1, .pAttachments = &r->snap_view,
            .width = (uint32_t)w, .height = (uint32_t)h, .layers = 1,
        };
        if (vkCreateFramebuffer(r->device, &fci, NULL, &r->snap_framebuffer) != VK_SUCCESS)
            goto fail;
    }
    if (create_buffer(r, size, VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                      VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                      &r->snap_buffer, &r->snap_buffer_mem) != VK_SUCCESS)
        goto fail;

    r->snap_buffer_size = size;
    r->snap_w = w;
    r->snap_h = h;
    ALOGD("FSVulkanRenderer: snapshot target %dx%d\n", w, h);
    return VK_SUCCESS;

fail:
    destroy_snapshot_target(r);
    return VK_ERROR_INITIALIZATION_FAILED;
}

/*
 * 在本帧的 command buffer 上（主 pass 之后）把当前帧按快照类型重画到离屏图像，
 * 再 copy 到 host 可见 buffer。真正回读在 finish_snapshot_readback 里做。
 */
static void record_snapshot_pass(FSVulkanRenderer *r)
{
    int type = r->snapshot_type;
    int with_sub = 0, use_display_transform = 0;
    int w, h;
    float rect[4]   = { -1.0f, -1.0f, 1.0f, 1.0f };
    float uvmat[4]  = { 1.0f, 0.0f, 0.0f, 1.0f };
    float posmat[4] = { 1.0f, 0.0f, 0.0f, 1.0f };

    switch (type) {
    case FS_SNAPSHOT_TYPE_SCREEN:
        w = (int)r->swapchain_extent.width;
        h = (int)r->swapchain_extent.height;
        with_sub = 1;
        use_display_transform = 1;   /* 屏幕上怎么显示就怎么截 */
        break;
    case FS_SNAPSHOT_TYPE_EFFECT_SUBTITLE_ORIGIN:
        /* 原始尺寸 + 带字幕 + 带效果（Android 目前的效果就是三轴旋转） */
        w = r->video_w; h = r->video_h;
        with_sub = 1;
        if (((r->last_rot / 90) % 2) == 1) {   /* 90 的奇数倍：交换宽高 */
            int t = w; w = h; h = t;
        }
        /* 旋转由位置矩阵执行，与屏幕用同一个三轴旋转 */
        memcpy(posmat, r->video_posmat, sizeof(posmat));
        break;
    case FS_SNAPSHOT_TYPE_EFFECT_ORIGIN:
        w = r->video_w; h = r->video_h;
        with_sub = 1;               /* 原始尺寸 + 字幕，不带效果 */
        break;
    default:                        /* ORIGIN: 原始尺寸，字幕和效果都不要 */
        w = r->video_w; h = r->video_h;
        break;
    }

    if (w <= 0 || h <= 0 ||
        create_snapshot_resources(r, w, h) != VK_SUCCESS) {
        r->snapshot_type = -1;
        r->snapshot_ready = -1;
        return;
    }

    if (use_display_transform) {
        memcpy(rect,   r->video_rect,   sizeof(rect));
        memcpy(uvmat,  r->video_uvmat,  sizeof(uvmat));
        memcpy(posmat, r->video_posmat, sizeof(posmat));
    }

    /* 快照的清屏色和屏幕一样用背景色，这样 SCREEN 快照所见即所得 */
    VkClearValue clear = { .color = {{r->bg_color[0], r->bg_color[1], r->bg_color[2], 1.0f}} };
    VkRenderPassBeginInfo rpi = {
        .sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
        .renderPass = r->snap_pass,
        .framebuffer = r->snap_framebuffer,
        .renderArea = {{0, 0}, {(uint32_t)w, (uint32_t)h}},
        .clearValueCount = 1,
        .pClearValues = &clear,
    };
    vkCmdBeginRenderPass(r->command_buffer, &rpi, VK_SUBPASS_CONTENTS_INLINE);

    VkViewport vp = { 0, 0, (float)w, (float)h, 0.0f, 1.0f };
    VkRect2D sc = { {0, 0}, {(uint32_t)w, (uint32_t)h} };
    vkCmdSetViewport(r->command_buffer, 0, 1, &vp);
    vkCmdSetScissor(r->command_buffer, 0, 1, &sc);

    float pc[12];
    memcpy(pc,     rect,   sizeof(rect));
    memcpy(pc + 4, uvmat,  sizeof(uvmat));
    memcpy(pc + 8, posmat, sizeof(posmat));
    /* 快照和屏幕用的是同一条管线，色彩参数也得重新 push（否则读到未定义值） */
    /* 片元侧：色彩调整 + HDR 参数（hdrContent, hdrDisplay, transferFunc, bits）*/
    float color_pc[8] = { r->color_brightness, r->color_saturation,
                          r->color_contrast, r->color_adjust_on ? 1.0f : 0.0f,
                          r->hdr_content ? 1.0f : 0.0f,
                          r->hdr_display ? 1.0f : 0.0f,
                          (float)r->hdr_transfer,
                          (float)((r->tex10bit ? 1 : 0) | (r->hdr_full_range ? 2 : 0)) };

    VkDeviceSize off = 0;

    /* 屏幕所见类型要连模糊背景一起截（iOS 的 _snapshotScreen 也是这样） */
    if (use_display_transform && r->bg_ready && r->scaling_mode == FS_SCALING_MODE_ASPECT_FIT)
        draw_background(r);

    vkCmdBindPipeline(r->command_buffer, VK_PIPELINE_BIND_POINT_GRAPHICS, r->last_pipeline);
    vkCmdBindDescriptorSets(r->command_buffer, VK_PIPELINE_BIND_POINT_GRAPHICS,
                            r->last_layout, 0, 1, &r->last_desc_set, 0, NULL);
    vkCmdBindVertexBuffers(r->command_buffer, 0, 1, &r->vertex_buffer, &off);
    vkCmdPushConstants(r->command_buffer, r->last_layout, VK_SHADER_STAGE_VERTEX_BIT,
                       0, sizeof(pc), pc);
    vkCmdPushConstants(r->command_buffer, r->last_layout, VK_SHADER_STAGE_FRAGMENT_BIT,
                       sizeof(pc), sizeof(color_pc), color_pc);
    vkCmdDraw(r->command_buffer, 6, 1, 0, 0);

    if (with_sub && r->sub_overlay && r->sub_pipeline && !r->sub_desc_pending) {
        FSVulkanSubTexture *tex = r->sub_overlay->getTexture(r->sub_overlay);
        if (tex && tex->view) {
            vkCmdBindPipeline(r->command_buffer, VK_PIPELINE_BIND_POINT_GRAPHICS, r->sub_pipeline);
            vkCmdBindDescriptorSets(r->command_buffer, VK_PIPELINE_BIND_POINT_GRAPHICS,
                                    r->sub_pipeline_layout, 0, 1, &r->sub_desc_set, 0, NULL);
            vkCmdBindVertexBuffers(r->command_buffer, 0, 1, &r->sub_quad_buffer, &off);
            vkCmdPushConstants(r->command_buffer, r->sub_pipeline_layout, VK_SHADER_STAGE_VERTEX_BIT,
                               0, sizeof(pc), pc);
            vkCmdDraw(r->command_buffer, 6, 1, 0, 0);
        }
    }

    vkCmdEndRenderPass(r->command_buffer);

    VkBufferImageCopy copy = {
        .imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 },
        .imageOffset = { 0, 0, 0 },
        .imageExtent = { (uint32_t)w, (uint32_t)h, 1 },
    };
    vkCmdCopyImageToBuffer(r->command_buffer, r->snap_image,
                           VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                           r->snap_buffer, 1, &copy);

    VkBufferMemoryBarrier bb = {
        .sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
        .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
        .dstAccessMask = VK_ACCESS_HOST_READ_BIT,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .buffer = r->snap_buffer,
        .offset = 0,
        .size = VK_WHOLE_SIZE,
    };
    vkCmdPipelineBarrier(r->command_buffer, VK_PIPELINE_STAGE_TRANSFER_BIT,
                         VK_PIPELINE_STAGE_HOST_BIT, 0, 0, NULL, 1, &bb, 0, NULL);

    r->snap_recorded = 1;
}

/* 回读成 RGBA8888（BGRA 的 swapchain 顺手换一下字节序），交给 take_snapshot 的调用方 */
static void finish_snapshot_readback(FSVulkanRenderer *r)
{
    r->snap_recorded = 0;

    /* 一次性操作：等 GPU 做完，省得再管 fence */
    vkDeviceWaitIdle(r->device);

    int w = r->snap_w, h = r->snap_h;
    void *data = NULL;
    uint8_t *out = NULL;
    if (vkMapMemory(r->device, r->snap_buffer_mem, 0, r->snap_buffer_size, 0, &data) == VK_SUCCESS) {
        out = malloc((size_t)w * h * 4);
        if (out) {
            int swap_rb = (r->swapchain_format == VK_FORMAT_B8G8R8A8_UNORM ||
                           r->swapchain_format == VK_FORMAT_B8G8R8A8_SRGB);
            const uint8_t *src = data;
            for (int y = 0; y < h; y++) {
                uint8_t *dst = out + (size_t)y * w * 4;
                memcpy(dst, src + (size_t)y * w * 4, (size_t)w * 4);
                for (int x = 0; x < w; x++) {
                    if (swap_rb) {
                        uint8_t t = dst[x * 4];
                        dst[x * 4] = dst[x * 4 + 2];
                        dst[x * 4 + 2] = t;
                    }
                    dst[x * 4 + 3] = 0xFF;   /* swapchain 的 alpha 不可靠 */
                }
            }
        }
        vkUnmapMemory(r->device, r->snap_buffer_mem);
    }

    free(r->snapshot_pixels);
    r->snapshot_pixels = out;
    r->snapshot_w = w;
    r->snapshot_h = h;
    r->snapshot_type = -1;
    r->snapshot_ready = out ? 1 : -1;
}



/* 全屏四边形管线（背景模糊用）：blur.vert 直接把 0..1 的顶点映射到 NDC，
   不透明混合，视口是动态状态（两个 pass 的分辨率不同）。 */
static VkResult create_full_screen_pipeline(FSVulkanRenderer *r, VkRenderPass render_pass,
                                            VkShaderModule vert, VkShaderModule frag,
                                            VkPipelineLayout layout, VkPipeline *out_pipeline)
{
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
    VkViewport viewport = { 0, 0, 1.0f, 1.0f, 0.0f, 1.0f };
    VkRect2D scissor = { {0, 0}, {1, 1} };
    VkPipelineViewportStateCreateInfo vps = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        .viewportCount = 1, .pViewports = &viewport,
        .scissorCount = 1, .pScissors = &scissor,
    };
    VkDynamicState dyn_states[] = { VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR };
    VkPipelineDynamicStateCreateInfo ds = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        .dynamicStateCount = 2, .pDynamicStates = dyn_states,
    };
    VkPipelineRasterizationStateCreateInfo rs = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        .polygonMode = VK_POLYGON_MODE_FILL, .cullMode = VK_CULL_MODE_NONE, .lineWidth = 1.0f,
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
        .pDynamicState = &ds,
        .pRasterizationState = &rs,
        .pMultisampleState = &ms,
        .pColorBlendState = &cbs,
        .layout = layout,
        .renderPass = render_pass,
        .subpass = 0,
    };
    return vkCreateGraphicsPipelines(r->device, VK_NULL_HANDLE, 1, &gpi, NULL, out_pipeline);
}

/* ------------------------------------------------------------------------- */
/* 高斯模糊背景                                                                 */
/*                                                                             */
/* 语义对齐 iOS（FSMetalView + FSMetalBlurFilter）：                             */
/*   backgroundImage        用户给的图，降采样到最长边 400 后上传（Java 侧缩）     */
/*   backgroundBlurIterations 默认 3，每轮做一次 σ 高斯（方差可加 = iOS 的语义）  */
/*   backgroundBlurSigma    默认 30，单位是工作分辨率下的纹素                     */
/* 结果铺满整个显示区、画在视频下面，只在 AspectFit（会留黑边）时画。              */
/* ------------------------------------------------------------------------- */

#define FS_BG_MAX_SIDE 400

typedef struct {
    float step[2];        /* 采样步长（含方向），单位纹理坐标 */
    int   taps;
    float pad;
    float weights[16];
} FSBlurPush;

static void destroy_background_resources(FSVulkanRenderer *r)
{
    if (!r->device)
        return;

    for (int i = 0; i < 2; i++) {
        if (r->bg_fb[i]) { vkDestroyFramebuffer(r->device, r->bg_fb[i], NULL); r->bg_fb[i] = VK_NULL_HANDLE; }
    }
    for (int i = 0; i < 3; i++) {
        if (r->bg_view[i]) { vkDestroyImageView(r->device, r->bg_view[i], NULL); r->bg_view[i] = VK_NULL_HANDLE; }
        if (r->bg_img[i])  { vkDestroyImage(r->device, r->bg_img[i], NULL);     r->bg_img[i] = VK_NULL_HANDLE; }
        if (r->bg_mem[i])  { vkFreeMemory(r->device, r->bg_mem[i], NULL);       r->bg_mem[i] = VK_NULL_HANDLE; }
        r->bg_desc_set[i] = VK_NULL_HANDLE;
        r->bg_layout[i] = VK_IMAGE_LAYOUT_UNDEFINED;
    }
    if (r->bg_staging)     { vkDestroyBuffer(r->device, r->bg_staging, NULL);  r->bg_staging = VK_NULL_HANDLE; }
    if (r->bg_staging_mem) { vkFreeMemory(r->device, r->bg_staging_mem, NULL); r->bg_staging_mem = VK_NULL_HANDLE; }
    r->bg_staging_size = 0;
    r->bg_w = r->bg_h = 0;
    r->bg_ready = 0;
    r->bg_result_slot = -1;
}

/* 模糊 pass 的 render pass：附件格式随意（不对外），结束时转成可采样 */
static VkResult create_bg_pass(FSVulkanRenderer *r)
{
    VkAttachmentDescription att = {
        .format = VK_FORMAT_R8G8B8A8_UNORM,
        .samples = VK_SAMPLE_COUNT_1_BIT,
        .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
        .stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        .finalLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
    };
    VkAttachmentReference ref = { 0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
    VkSubpassDescription sub = {
        .pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS,
        .colorAttachmentCount = 1, .pColorAttachments = &ref,
    };
    VkRenderPassCreateInfo rpci = {
        .sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        .attachmentCount = 1, .pAttachments = &att,
        .subpassCount = 1, .pSubpasses = &sub,
    };
    if (vkCreateRenderPass(r->device, &rpci, NULL, &r->bg_pass) != VK_SUCCESS)
        return VK_ERROR_INITIALIZATION_FAILED;

    /* 采样器：线性 + clamp，对齐 MPSImageGaussianBlur 的 edgeMode Clamp */
    VkSamplerCreateInfo sci = {
        .sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
        .magFilter = VK_FILTER_LINEAR, .minFilter = VK_FILTER_LINEAR,
        .mipmapMode = VK_SAMPLER_MIPMAP_MODE_NEAREST,
        .addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .maxLod = 0.0f,
    };
    if (vkCreateSampler(r->device, &sci, NULL, &r->bg_sampler) != VK_SUCCESS)
        return VK_ERROR_INITIALIZATION_FAILED;

    {
        VkDescriptorSetLayoutBinding b = {
            .binding = 1,
            .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 1,
            .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT,
        };
        VkDescriptorSetLayoutCreateInfo dli = {
            .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .bindingCount = 1, .pBindings = &b,
        };
        if (vkCreateDescriptorSetLayout(r->device, &dli, NULL, &r->bg_desc_layout) != VK_SUCCESS)
            return VK_ERROR_INITIALIZATION_FAILED;

        VkDescriptorPoolSize ps = {
            .type = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 8,
        };
        VkDescriptorPoolCreateInfo pci = {
            .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .maxSets = 8,
            .poolSizeCount = 1, .pPoolSizes = &ps,
        };
        if (vkCreateDescriptorPool(r->device, &pci, NULL, &r->bg_desc_pool) != VK_SUCCESS)
            return VK_ERROR_INITIALIZATION_FAILED;
    }

    /* 模糊管线：blur.vert + blur.frag，片元侧一段 push constant（步长 + 权重） */
    {
        VkShaderModule vs = create_shader_module(r, blur_vert_spv, blur_vert_spv_len);
        VkShaderModule fs = create_shader_module(r, blur_frag_spv, blur_frag_spv_len);
        if (!vs || !fs)
            return VK_ERROR_INITIALIZATION_FAILED;

        VkPushConstantRange pcr = {
            .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT,
            .offset = 0,
            .size = sizeof(FSBlurPush),
        };
        VkPipelineLayoutCreateInfo pli = {
            .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .setLayoutCount = 1, .pSetLayouts = &r->bg_desc_layout,
            .pushConstantRangeCount = 1, .pPushConstantRanges = &pcr,
        };
        VkResult res = vkCreatePipelineLayout(r->device, &pli, NULL, &r->bg_blur_layout);
        if (res != VK_SUCCESS) {
            vkDestroyShaderModule(r->device, vs, NULL);
            vkDestroyShaderModule(r->device, fs, NULL);
            return res;
        }
        res = create_full_screen_pipeline(r, r->bg_pass, vs, fs, r->bg_blur_layout,
                                          &r->bg_blur_pipeline);
        vkDestroyShaderModule(r->device, vs, NULL);
        vkDestroyShaderModule(r->device, fs, NULL);
        if (res != VK_SUCCESS)
            return res;
    }

    /* 合成管线：blur.vert + sub.frag（就是采样一张纹理铺满），画进主 render pass */
    {
        VkShaderModule vs = create_shader_module(r, blur_vert_spv, blur_vert_spv_len);
        VkShaderModule fs = create_shader_module(r, sub_frag_spv, sub_frag_spv_len);
        if (!vs || !fs)
            return VK_ERROR_INITIALIZATION_FAILED;

        VkPipelineLayoutCreateInfo pli = {
            .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .setLayoutCount = 1, .pSetLayouts = &r->bg_desc_layout,
        };
        VkResult res = vkCreatePipelineLayout(r->device, &pli, NULL, &r->bg_draw_layout);
        if (res != VK_SUCCESS) {
            vkDestroyShaderModule(r->device, vs, NULL);
            vkDestroyShaderModule(r->device, fs, NULL);
            return res;
        }
        res = create_full_screen_pipeline(r, r->render_pass, vs, fs, r->bg_draw_layout,
                                          &r->bg_draw_pipeline);
        vkDestroyShaderModule(r->device, vs, NULL);
        vkDestroyShaderModule(r->device, fs, NULL);
        if (res != VK_SUCCESS)
            return res;
    }

    /* 自己的全屏四边形（0..1），blur.vert 直接映射到 NDC */
    {
        VkDeviceSize size = sizeof(kSubQuadVertices);
        if (create_buffer(r, size, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
                          VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                          &r->bg_quad_buffer, &r->bg_quad_mem) != VK_SUCCESS)
            return VK_ERROR_INITIALIZATION_FAILED;
        void *data = NULL;
        vkMapMemory(r->device, r->bg_quad_mem, 0, size, 0, &data);
        memcpy(data, kSubQuadVertices, size);
        vkUnmapMemory(r->device, r->bg_quad_mem);
    }

    return VK_SUCCESS;
}

static VkResult create_background_target(FSVulkanRenderer *r, int w, int h)
{
    if (!r->bg_pass && create_bg_pass(r) != VK_SUCCESS)
        return VK_ERROR_INITIALIZATION_FAILED;

    destroy_background_resources(r);
    vkResetDescriptorPool(r->device, r->bg_desc_pool, 0);

    r->bg_w = w;
    r->bg_h = h;

    for (int i = 0; i < 3; i++) {
        if (create_image(r, w, h, VK_FORMAT_R8G8B8A8_UNORM,
                         VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT |
                             VK_IMAGE_USAGE_SAMPLED_BIT,
                         &r->bg_img[i], &r->bg_mem[i]) != VK_SUCCESS)
            goto fail;
        if (create_image_view(r, r->bg_img[i], VK_FORMAT_R8G8B8A8_UNORM, &r->bg_view[i]) != VK_SUCCESS)
            goto fail;
        r->bg_layout[i] = VK_IMAGE_LAYOUT_UNDEFINED;
    }
    for (int i = 0; i < 2; i++) {
        VkImageView view = r->bg_view[FS_BG_SLOT_A + i];
        VkFramebufferCreateInfo fci = {
            .sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
            .renderPass = r->bg_pass,
            .attachmentCount = 1, .pAttachments = &view,
            .width = (uint32_t)w, .height = (uint32_t)h, .layers = 1,
        };
        if (vkCreateFramebuffer(r->device, &fci, NULL, &r->bg_fb[i]) != VK_SUCCESS)
            goto fail;
    }

    VkDeviceSize size = (VkDeviceSize)w * h * 4;
    if (create_buffer(r, size, VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                      VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                      &r->bg_staging, &r->bg_staging_mem) != VK_SUCCESS)
        goto fail;
    r->bg_staging_size = size;

    {
        VkDescriptorSetLayout layouts[3] = { r->bg_desc_layout, r->bg_desc_layout, r->bg_desc_layout };
        VkDescriptorSetAllocateInfo dai = {
            .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .descriptorPool = r->bg_desc_pool,
            .descriptorSetCount = 3,
            .pSetLayouts = layouts,
        };
        if (vkAllocateDescriptorSets(r->device, &dai, r->bg_desc_set) != VK_SUCCESS)
            goto fail;
    }
    for (int i = 0; i < 3; i++) {
        VkDescriptorImageInfo ii = {
            .sampler = r->bg_sampler,
            .imageView = r->bg_view[i],
            .imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };
        VkWriteDescriptorSet wr = {
            .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = r->bg_desc_set[i],
            .dstBinding = 1,
            .descriptorCount = 1,
            .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .pImageInfo = &ii,
        };
        vkUpdateDescriptorSets(r->device, 1, &wr, 0, NULL);
    }

    ALOGD("FSVulkanRenderer: background target %dx%d\n", w, h);
    return VK_SUCCESS;

fail:
    destroy_background_resources(r);
    return VK_ERROR_INITIALIZATION_FAILED;
}

static void upload_background_source(FSVulkanRenderer *r, const void *pixels)
{
    void *data = NULL;
    if (vkMapMemory(r->device, r->bg_staging_mem, 0, r->bg_staging_size, 0, &data) != VK_SUCCESS)
        return;
    memcpy(data, pixels, (size_t)r->bg_w * r->bg_h * 4);
    vkUnmapMemory(r->device, r->bg_staging_mem);

    int src = FS_BG_SLOT_SRC;
    VkImageMemoryBarrier b = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .oldLayout = r->bg_layout[src],
        .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = r->bg_img[src],
        .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 },
        .srcAccessMask = (r->bg_layout[src] == VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)
                             ? VK_ACCESS_SHADER_READ_BIT : 0,
        .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
    };
    vkCmdPipelineBarrier(r->command_buffer,
                         (r->bg_layout[src] == VK_IMAGE_LAYOUT_UNDEFINED)
                             ? VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT : VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                         VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &b);

    VkBufferImageCopy region = {
        .imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 },
        .imageOffset = { 0, 0, 0 },
        .imageExtent = { (uint32_t)r->bg_w, (uint32_t)r->bg_h, 1 },
    };
    vkCmdCopyBufferToImage(r->command_buffer, r->bg_staging, r->bg_img[src],
                           VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);

    b.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    b.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    b.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    b.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
    vkCmdPipelineBarrier(r->command_buffer, VK_PIPELINE_STAGE_TRANSFER_BIT,
                         VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, NULL, 0, NULL, 1, &b);
    r->bg_layout[src] = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
}

/* 一次一维高斯：读 read_slot，写 write_slot */
static void background_blur_pass(FSVulkanRenderer *r, int read_slot, int write_slot,
                                 float dx, float dy, float stride,
                                 const float *weights, int taps)
{
    VkImageLayout old = r->bg_layout[write_slot];
    VkImageMemoryBarrier b = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .oldLayout = old,
        .newLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = r->bg_img[write_slot],
        .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 },
        .srcAccessMask = (old == VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)
                             ? VK_ACCESS_SHADER_READ_BIT : 0,
        .dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
    };
    vkCmdPipelineBarrier(r->command_buffer,
                         (old == VK_IMAGE_LAYOUT_UNDEFINED) ? VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT
                                                            : VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                         VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, 0, 0, NULL, 0, NULL, 1, &b);

    VkClearValue clear = { .color = {{0.0f, 0.0f, 0.0f, 1.0f}} };
    VkFramebuffer fb = r->bg_fb[write_slot == FS_BG_SLOT_A ? 0 : 1];
    VkRenderPassBeginInfo rpi = {
        .sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
        .renderPass = r->bg_pass,
        .framebuffer = fb,
        .renderArea = {{0, 0}, {(uint32_t)r->bg_w, (uint32_t)r->bg_h}},
        .clearValueCount = 1,
        .pClearValues = &clear,
    };
    vkCmdBeginRenderPass(r->command_buffer, &rpi, VK_SUBPASS_CONTENTS_INLINE);

    VkViewport vp = { 0, 0, (float)r->bg_w, (float)r->bg_h, 0.0f, 1.0f };
    VkRect2D sc = { {0, 0}, {(uint32_t)r->bg_w, (uint32_t)r->bg_h} };
    vkCmdSetViewport(r->command_buffer, 0, 1, &vp);
    vkCmdSetScissor(r->command_buffer, 0, 1, &sc);

    FSBlurPush pc;
    memset(&pc, 0, sizeof(pc));
    pc.step[0] = dx * stride / (float)r->bg_w;
    pc.step[1] = dy * stride / (float)r->bg_h;
    pc.taps = taps;
    for (int i = 0; i < taps && i < 16; i++)
        pc.weights[i] = weights[i];

    vkCmdBindPipeline(r->command_buffer, VK_PIPELINE_BIND_POINT_GRAPHICS, r->bg_blur_pipeline);
    vkCmdBindDescriptorSets(r->command_buffer, VK_PIPELINE_BIND_POINT_GRAPHICS,
                            r->bg_blur_layout, 0, 1, &r->bg_desc_set[read_slot], 0, NULL);
    VkDeviceSize off = 0;
    vkCmdBindVertexBuffers(r->command_buffer, 0, 1, &r->bg_quad_buffer, &off);
    vkCmdPushConstants(r->command_buffer, r->bg_blur_layout, VK_SHADER_STAGE_FRAGMENT_BIT,
                       0, sizeof(pc), &pc);
    vkCmdDraw(r->command_buffer, 6, 1, 0, 0);

    vkCmdEndRenderPass(r->command_buffer);
    r->bg_layout[write_slot] = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
}

/* 权重取在真实偏移 i*stride 上，着色器里再归一化；stride 最多摊到 σ/3（覆盖 ±5σ） */
static void compute_blur_weights(float sigma, float *stride_out, float *weights, int *taps)
{
    if (sigma <= 0.0f)
        sigma = 30.0f;
    float stride = sigma / 3.0f;
    if (stride < 1.0f) stride = 1.0f;
    if (stride > 16.0f) stride = 16.0f;

    for (int i = 0; i < 16; i++) {
        float d = (float)i * stride;
        weights[i] = expf(-(d * d) / (2.0f * sigma * sigma));
    }
    weights[0] = 1.0f;
    *stride_out = stride;
    *taps = 16;
}

static void run_background_blur(FSVulkanRenderer *r)
{
    float weights[16];
    float stride = 1.0f;
    int taps = 16;
    compute_blur_weights(r->bg_sigma, &stride, weights, &taps);

    int iters = r->bg_iterations;
    if (iters < 1) iters = 1;
    if (iters > 16) iters = 16;

    int read = FS_BG_SLOT_SRC;
    int write = FS_BG_SLOT_A;

    for (int i = 0; i < iters; i++) {
        background_blur_pass(r, read, write, 1.0f, 0.0f, stride, weights, taps);
        int tmp = (write == FS_BG_SLOT_A) ? FS_BG_SLOT_B : FS_BG_SLOT_A;
        background_blur_pass(r, write, tmp, 0.0f, 1.0f, stride, weights, taps);
        read = tmp;
        write = (tmp == FS_BG_SLOT_A) ? FS_BG_SLOT_B : FS_BG_SLOT_A;
    }
    r->bg_result_slot = read;

    /* 结果马上要在主 pass 里当纹理采样 */
    VkImageMemoryBarrier b = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .oldLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        .newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = r->bg_img[read],
        .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 },
        .srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        .dstAccessMask = VK_ACCESS_SHADER_READ_BIT,
    };
    vkCmdPipelineBarrier(r->command_buffer, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                         VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, NULL, 0, NULL, 1, &b);
}

/* 渲染线程：把 App 线程挂起的背景请求落地（每帧开头调一次） */
static void background_prepare(FSVulkanRenderer *r)
{
    void *pixels = NULL;
    int w = 0, h = 0, clear = 0, reparam = 0;

    pthread_mutex_lock(&r->bg_mutex);
    pixels = r->bg_pending_pixels;
    w = r->bg_pending_w;
    h = r->bg_pending_h;
    clear = r->bg_pending_clear;
    reparam = r->bg_pending_params;
    r->bg_pending_pixels = NULL;
    r->bg_pending_w = r->bg_pending_h = 0;
    r->bg_pending_clear = 0;
    r->bg_pending_params = 0;
    pthread_mutex_unlock(&r->bg_mutex);

    if (!pixels && !clear && !reparam)
        return;

    if (clear) {
        destroy_background_resources(r);
        free(pixels);
        return;
    }

    if (pixels && (w != r->bg_w || h != r->bg_h)) {
        if (create_background_target(r, w, h) != VK_SUCCESS) {
            free(pixels);
            return;
        }
    }
    if (!r->bg_w)
        return;

    if (pixels)
        upload_background_source(r, pixels);
    free(pixels);

    run_background_blur(r);
    r->bg_ready = 1;
}

/* 铺满整个显示区，画在视频下面（只在 AspectFit 或没有视频帧时用） */
static void draw_background(FSVulkanRenderer *r)
{
    if (!r->bg_ready || !r->bg_draw_pipeline || r->bg_result_slot < 0)
        return;

    vkCmdBindPipeline(r->command_buffer, VK_PIPELINE_BIND_POINT_GRAPHICS, r->bg_draw_pipeline);
    vkCmdBindDescriptorSets(r->command_buffer, VK_PIPELINE_BIND_POINT_GRAPHICS,
                            r->bg_draw_layout, 0, 1, &r->bg_desc_set[r->bg_result_slot], 0, NULL);
    VkDeviceSize off = 0;
    vkCmdBindVertexBuffers(r->command_buffer, 0, 1, &r->bg_quad_buffer, &off);
    vkCmdDraw(r->command_buffer, 6, 1, 0, 0);
}


void fs_vulkan_renderer_set_background_image(FSVulkanRenderer *r,
                                             const void *pixels, int width, int height)
{
    if (!r)
        return;

    void *copy = NULL;
    if (pixels && width > 0 && height > 0) {
        size_t size = (size_t)width * height * 4;
        copy = malloc(size);
        if (!copy)
            return;
        memcpy(copy, pixels, size);
    }

    pthread_mutex_lock(&r->bg_mutex);
    free(r->bg_pending_pixels);
    r->bg_pending_pixels = copy;
    r->bg_pending_w = copy ? width : 0;
    r->bg_pending_h = copy ? height : 0;
    r->bg_pending_clear = copy ? 0 : 1;   /* 传 NULL 就是清掉背景 */
    pthread_mutex_unlock(&r->bg_mutex);
}

void fs_vulkan_renderer_set_background_blur(FSVulkanRenderer *r, int iterations, float sigma)
{
    if (!r)
        return;
    if (iterations < 1) iterations = 1;
    if (sigma <= 0.0f) sigma = 30.0f;

    pthread_mutex_lock(&r->bg_mutex);
    if (r->bg_iterations != iterations || r->bg_sigma != sigma) {
        r->bg_iterations = iterations;
        r->bg_sigma = sigma;
        if (r->bg_w > 0)
            r->bg_pending_params = 1;     /* 让渲染线程用原图重跑一遍 */
    }
    pthread_mutex_unlock(&r->bg_mutex);
}

/*
 * 色彩调整，语义对齐 iOS 的 FSColorConvertPreference（colorPreference）：
 * 三者默认都是 1.0，全为 1.0 时走原样输出（和 iOS 的 applyAdjust 判断一致）。
 * 公式照抄 iOS 的 rgb_adjust，在 yuv.frag / external.frag 里执行，软解硬解都生效，
 * 字幕不受影响（iOS 的字幕片元也没有做 rgb_adjust）。
 */
void fs_vulkan_renderer_set_color_adjust(FSVulkanRenderer *r,
                                         float brightness, float saturation, float contrast)
{
    if (!r)
        return;

    r->color_brightness = brightness;
    r->color_saturation = saturation;
    r->color_contrast   = contrast;
    r->color_adjust_on  = (brightness != 1.0f || saturation != 1.0f || contrast != 1.0f);
}

/*
 * 是否允许 HDR 直显，对齐 iOS 的 allowHDRDirectDisplay（默认 YES）。
 * 只有「内容 HDR && 允许直显 && 屏能直出」时才不做色调映射；当前 8bit UNORM 交换链
 * 永远走色调映射（相当于 iOS 上屏不支持 EDR 的情形）。
 */
void fs_vulkan_renderer_set_allow_hdr_display(FSVulkanRenderer *r, int allow)
{
    if (!r)
        return;
    r->allow_hdr_display = allow ? 1 : 0;
    r->hdr_display = (r->hdr_content && r->allow_hdr_display && r->display_hdr_support) ? 1 : 0;
}

/* 当前帧是不是 HDR 内容（BT.2020），对齐 iOS 的 isHDRContent */
int fs_vulkan_renderer_is_hdr_content(FSVulkanRenderer *r)
{
    return r ? r->hdr_content : 0;
}

/* 是否正在直显 HDR，对齐 iOS 的 directDisplayHDRSupportted（内容 HDR + 允许 + 屏能直出） */
int fs_vulkan_renderer_is_hdr_display_active(FSVulkanRenderer *r)
{
    return r ? r->hdr_display : 0;
}

/* 无视频区域（黑边）的背景色，对齐 iOS 的 -setBackgroundColor:g:b:（0~255） */
void fs_vulkan_renderer_set_background_color(FSVulkanRenderer *r, int red, int green, int blue)
{
    if (!r)
        return;

    if (red   < 0)   red   = 0;   if (red   > 255) red   = 255;
    if (green < 0)   green = 0;   if (green > 255) green = 255;
    if (blue  < 0)   blue  = 0;   if (blue  > 255) blue  = 255;

    r->bg_color[0] = red   / 255.0f;
    r->bg_color[1] = green / 255.0f;
    r->bg_color[2] = blue  / 255.0f;
}

int fs_vulkan_renderer_take_snapshot(FSVulkanRenderer *r, int type,
                                     int *out_w, int *out_h, void **out_pixels)
{
    if (!r || !out_w || !out_h || !out_pixels)
        return -1;
    *out_pixels = NULL;
    if (!r->surface_ready || r->last_pipeline == VK_NULL_HANDLE)
        return -1;
    if (type < FS_SNAPSHOT_TYPE_ORIGIN || type > FS_SNAPSHOT_TYPE_EFFECT_SUBTITLE_ORIGIN)
        return -1;

    free(r->snapshot_pixels);
    r->snapshot_pixels = NULL;
    r->snapshot_ready = 0;
    r->snapshot_type = type;      /* 等渲染线程下一帧处理 */

    int waited = 0;
    while (r->snapshot_ready == 0 && waited < 5000) {   /* 最多 5s */
        usleep(2000);
        waited += 2;
    }

    if (r->snapshot_ready != 1 || !r->snapshot_pixels) {
        r->snapshot_type = -1;
        return -1;
    }

    *out_w = r->snapshot_w;
    *out_h = r->snapshot_h;
    *out_pixels = r->snapshot_pixels;   /* 所有权交给调用方 */
    r->snapshot_pixels = NULL;
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
    if (res == VK_ERROR_OUT_OF_DATE_KHR) {
        /* 交换链确实过时：本次没有拿到可用图像，标记下一帧安全点重建 */
        r->swapchain_dirty = 1;
        return -1;
    }
    if (res == VK_SUBOPTIMAL_KHR) {
        /*
         * 注意：SUBOPTIMAL 是「成功码」——图像已经成功 acquire，可以照常画。
         * 以前把它当失败直接 return -1，会白白丢掉这一帧、并且把已经发出的
         * image_available 信号量留在 signaled 状态（下一次 acquire 复用同一信号量
         * 属于未定义行为）。这里正常渲染，只是画完把交换链标记为待重建。
         */
        r->swapchain_dirty = 1;
    } else if (res != VK_SUCCESS) {
        return -1;
    }

    /* 字幕纹理换了 -> 重写描述符；先等上一帧画完，避免描述符被在飞的命令缓冲引用 */
    if (r->sub_desc_pending && r->sub_desc_set) {
        vkDeviceWaitIdle(r->device);
        update_sub_descriptor(r);
    }

    vkResetCommandBuffer(r->command_buffer, 0);
    VkCommandBufferBeginInfo bi = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
                                    .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
    vkBeginCommandBuffer(r->command_buffer, &bi);

    /* 背景图/模糊参数变了就在这里上传并重跑高斯（要在主 pass 之前） */
    background_prepare(r);

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

    /* 无视频区域（黑边）的颜色：iOS 那边是 -setBackgroundColor:g:b: 设的 clearColor */
    VkClearValue clear = { .color = {{r->bg_color[0], r->bg_color[1], r->bg_color[2], 1.0f}} };
    VkRenderPassBeginInfo rpi = {
        .sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
        .renderPass = r->render_pass,
        .framebuffer = r->framebuffers[image_index],
        .renderArea = {{0, 0}, r->swapchain_extent},
        .clearValueCount = 1,
        .pClearValues = &clear,
    };
    vkCmdBeginRenderPass(r->command_buffer, &rpi, VK_SUBPASS_CONTENTS_INLINE);

    /* 视口改成动态状态了（快照要画到别的分辨率的离屏图上），主 pass 自己显式设一次 */
    {
        VkViewport vp = { 0, 0, (float)r->swapchain_extent.width,
                                (float)r->swapchain_extent.height, 0.0f, 1.0f };
        VkRect2D sc = { {0, 0}, r->swapchain_extent };
        vkCmdSetViewport(r->command_buffer, 0, 1, &vp);
        vkCmdSetScissor(r->command_buffer, 0, 1, &sc);
    }

    /*
     * 先铺高斯模糊背景：只有 AspectFit 会留黑边才需要；没有视频帧时也用它替掉纯色背景
     * （和 iOS FSMetalView 的判断一致）。
     */
    if (r->bg_ready && (pipeline == VK_NULL_HANDLE || r->scaling_mode == FS_SCALING_MODE_ASPECT_FIT))
        draw_background(r);

    /* 记住这一帧用的管线，快照要把同样的内容再画一次 */
    if (pipeline != VK_NULL_HANDLE) {
        r->last_pipeline = pipeline;
        r->last_layout   = layout;
        r->last_desc_set = desc_set;
    }

    /* 视频与字幕共用同一套变换：rect + uvmat + posmat（缩放/letterbox/三轴旋转） */
    float pc[12];
    memcpy(pc,     r->video_rect,   sizeof(r->video_rect));
    memcpy(pc + 4, r->video_uvmat,  sizeof(r->video_uvmat));
    memcpy(pc + 8, r->video_posmat, sizeof(r->video_posmat));

    /* 片元侧的色彩调整（亮度/饱和度/对比度/开关），和 iOS 的 rgb_adjust 同参 */
    /* 片元侧：色彩调整 + HDR 参数（hdrContent, hdrDisplay, transferFunc, bits）*/
    float color_pc[8] = { r->color_brightness, r->color_saturation,
                          r->color_contrast, r->color_adjust_on ? 1.0f : 0.0f,
                          r->hdr_content ? 1.0f : 0.0f,
                          r->hdr_display ? 1.0f : 0.0f,
                          (float)r->hdr_transfer,
                          (float)((r->tex10bit ? 1 : 0) | (r->hdr_full_range ? 2 : 0)) };

    /* pipeline 为空 = 只有字幕（例如音频轨在放、视频帧已被清掉） */
    if (pipeline != VK_NULL_HANDLE) {
        vkCmdBindPipeline(r->command_buffer, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
        vkCmdBindDescriptorSets(r->command_buffer, VK_PIPELINE_BIND_POINT_GRAPHICS,
                                layout, 0, 1, &desc_set, 0, NULL);
        VkDeviceSize offsets = 0;
        vkCmdBindVertexBuffers(r->command_buffer, 0, 1, &r->vertex_buffer, &offsets);
        vkCmdPushConstants(r->command_buffer, layout, VK_SHADER_STAGE_VERTEX_BIT,
                           0, sizeof(pc), pc);
        vkCmdPushConstants(r->command_buffer, layout, VK_SHADER_STAGE_FRAGMENT_BIT,
                           sizeof(pc), sizeof(color_pc), color_pc);
        vkCmdDraw(r->command_buffer, 6, 1, 0, 0);
    }

    /* 视频之上叠字幕（预乘 alpha，跟随视频的缩放/letterbox/旋转） */
    if (r->sub_overlay && r->sub_pipeline && !r->sub_desc_pending) {
        FSVulkanSubTexture *tex = r->sub_overlay->getTexture(r->sub_overlay);
        if (tex && tex->view) {
            vkCmdBindPipeline(r->command_buffer, VK_PIPELINE_BIND_POINT_GRAPHICS,
                              r->sub_pipeline);
            vkCmdBindDescriptorSets(r->command_buffer, VK_PIPELINE_BIND_POINT_GRAPHICS,
                                    r->sub_pipeline_layout, 0, 1, &r->sub_desc_set, 0, NULL);
            VkDeviceSize sub_offset = 0;
            vkCmdBindVertexBuffers(r->command_buffer, 0, 1, &r->sub_quad_buffer, &sub_offset);
            vkCmdPushConstants(r->command_buffer, r->sub_pipeline_layout,
                               VK_SHADER_STAGE_VERTEX_BIT, 0, sizeof(pc), pc);
            vkCmdDraw(r->command_buffer, 6, 1, 0, 0);
        }
    }

    vkCmdEndRenderPass(r->command_buffer);

    /* 有快照请求：在主 pass 之后、同一个 command buffer 里把当前帧再画到离屏图像并回读 */
    if (r->snapshot_type >= 0 && r->last_pipeline != VK_NULL_HANDLE)
        record_snapshot_pass(r);

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
    VkResult preset = vkQueuePresentKHR(r->present_queue, &pi);
    if (preset == VK_ERROR_OUT_OF_DATE_KHR || preset == VK_SUBOPTIMAL_KHR) {
        /* 显示引擎要求重建交换链：下一帧安全点重建 */
        r->swapchain_dirty = 1;
    }

    if (r->snap_recorded)
        finish_snapshot_readback(r);

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

    /* 硬解通路用的是同一个 yuv.vert（要 rect/uvmat/posmat 做缩放/旋转/letterbox），
       所以布局里必须有顶点段；片元段给 external.frag 的色彩调整用。
       这两段以前漏了 —— 顶点着色器读不到的 push constant 是未定义值。 */
    VkPushConstantRange mcpcr[2] = {
        {
            .stageFlags = VK_SHADER_STAGE_VERTEX_BIT,
            .offset = 0,
            .size = sizeof(float) * 12,
        },
        {
            .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT,
            .offset = sizeof(float) * 12,
            .size = sizeof(float) * 8,   /* 色彩调整 + HDR 参数 */
        },
    };
    VkPipelineLayoutCreateInfo pli = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = 1, .pSetLayouts = &r->mc_desc_layout,
        .pushConstantRangeCount = 2, .pPushConstantRanges = mcpcr,
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

    /*
     * 依规约：pNext 里带 VkExternalFormatANDROID 时，必须同时带
     * VkExternalMemoryImageCreateInfo（handleTypes 含 ANDROID_HARDWARE_BUFFER_BIT_ANDROID），
     * 否则这个 image 不会被驱动当成「外部显存导入」的 image —— 表现是可以创建、可以绑内存，
     * 但采样恒读到 0（绿屏），而不是报错。
     */
    VkExternalFormatANDROID ext_fmt = {
        .sType = VK_STRUCTURE_TYPE_EXTERNAL_FORMAT_ANDROID,
        .externalFormat = r->mc_external_format,
    };
    VkExternalMemoryImageCreateInfo ext_mem = {
        .sType = VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO,
        .pNext = &ext_fmt,
        .handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_ANDROID_HARDWARE_BUFFER_BIT_ANDROID,
    };
    VkImageCreateInfo ici = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .pNext = &ext_mem,
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
 * 销毁 surface/swapchain 及其依赖的 view / framebuffer。
 * 调用前必须保证没有在飞的帧（见 rebuild_swapchain 里的 vkDeviceWaitIdle）。
 * surface 也一起销毁：它的尺寸来自 window，重建成新尺寸必须重建。
 */
static void destroy_surface_swapchain(FSVulkanRenderer *r)
{
    if (!r->device)
        return;

    /* framebuffer 引用 swapchain view，先销毁 */
    if (r->framebuffers) {
        for (uint32_t i = 0; i < r->image_count; i++)
            if (r->framebuffers[i]) vkDestroyFramebuffer(r->device, r->framebuffers[i], NULL);
        free(r->framebuffers);
        r->framebuffers = NULL;
    }
    if (r->swapchain_views) {
        for (uint32_t i = 0; i < r->image_count; i++)
            if (r->swapchain_views[i]) vkDestroyImageView(r->device, r->swapchain_views[i], NULL);
        free(r->swapchain_views);
        r->swapchain_views = NULL;
    }
    if (r->swapchain_images) {
        free(r->swapchain_images);
        r->swapchain_images = NULL;
    }
    if (r->swapchain) {
        vkDestroySwapchainKHR(r->device, r->swapchain, NULL);
        r->swapchain = VK_NULL_HANDLE;
    }
    if (r->surface) {
        vkDestroySurfaceKHR(r->instance, r->surface, NULL);
        r->surface = VK_NULL_HANDLE;
    }
    r->image_count = 0;
}

/* Android surface（window）的当前尺寸是否已经和交换链不再一致 */
static int swapchain_needs_rebuild(FSVulkanRenderer *r)
{
    if (r->swapchain_dirty)
        return 1;
    if (!r->window)
        return 0;
    int w = ANativeWindow_getWidth(r->window);
    int h = ANativeWindow_getHeight(r->window);
    if (w <= 0 || h <= 0)
        return 0;
    return (uint32_t)w != r->swapchain_extent.width ||
           (uint32_t)h != r->swapchain_extent.height;
}

/*
 * 在当前帧开始前的安全点重建 surface + swapchain + framebuffers。
 * render pass / pipeline 只依赖 swapchain 的 format（与尺寸无关，viewport/scissor 是动态状态），
 * 所以正常情况下只重建上表对象；仅当 surface format 真的变了才连带重建 render pass 与管线。
 */
static int rebuild_swapchain(FSVulkanRenderer *r)
{
    if (!r->device || !r->window)
        return -1;

    /* 确保没有在飞的帧：重建前必须 GPU 排空，否则会销毁仍被引用的对象 */
    vkDeviceWaitIdle(r->device);

    VkFormat old_format = r->swapchain_format;

    destroy_surface_swapchain(r);

    if (create_surface_swapchain(r) != VK_SUCCESS) {
        ALOGE("FSVulkanRenderer: swapchain recreate failed\n");
        return -1;
    }

    if (r->swapchain_format != old_format) {
        ALOGW("FSVulkanRenderer: surface format changed 0x%x -> 0x%x, rebuilding pass/pipelines\n",
              (unsigned)old_format, (unsigned)r->swapchain_format);
        destroy_sub_resources(r);
        destroy_mc_resources(r);
        if (r->pipeline)        { vkDestroyPipeline(r->device, r->pipeline, NULL);              r->pipeline = VK_NULL_HANDLE; }
        if (r->pipeline_layout) { vkDestroyPipelineLayout(r->device, r->pipeline_layout, NULL); r->pipeline_layout = VK_NULL_HANDLE; }
        if (r->render_pass)     { vkDestroyRenderPass(r->device, r->render_pass, NULL);         r->render_pass = VK_NULL_HANDLE; }
        if (create_render_pass(r) != VK_SUCCESS ||
            create_pipeline(r) != VK_SUCCESS) {
            ALOGE("FSVulkanRenderer: pass/pipeline rebuild failed\n");
            r->surface_ready = 0;
            return -1;
        }
        if (create_sub_resources(r) != 0)
            ALOGW("FSVulkanRenderer: subtitle disabled after format change\n");
    }

    if (create_framebuffers(r) != VK_SUCCESS) {
        ALOGE("FSVulkanRenderer: framebuffer recreate failed\n");
        return -1;
    }

    ALOGI("FSVulkanRenderer: swapchain recreated, %ux%u\n",
          r->swapchain_extent.width, r->swapchain_extent.height);
    return 0;
}

/* 每帧渲染前调用：需要时在安全点重建，保证后面用的 swapchain_extent 是最新的。
 * 返回 0 表示可继续渲染；-1 表示本帧不要渲染（重建失败，下一帧再试）。 */
static int fs_vulkan_renderer_sync_surface(FSVulkanRenderer *r)
{
    if (!r || !r->surface_ready)
        return 0;
    if (!swapchain_needs_rebuild(r))
        return 0;
    if (rebuild_swapchain(r) == 0) {
        r->swapchain_dirty = 0;
        return 0;
    }
    ALOGW("FSVulkanRenderer: swapchain rebuild failed, retry next frame\n");
    return -1;
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

/*
 * 由显示尺寸/SAR/旋转/缩放模式算出画面的目标 NDC 矩形与位置矩阵。
 * 语义对齐 iOS FSMetalView -computeNormalizedVerticesRatio:drawableSize: +
 * FSMetalRenderer -updateVertexIfNeed 的 quaternion -> viewMatrix：
 *   1) SAR 先并进宽度；
 *   2) 总 Z 旋转 = 手动 z（属性）+ 自动 z（元数据）。若它是 90 的奇数倍，交换画布宽高
 *      （等价 iOS 交换 drawableSize）后再算等比缩放，得到未旋转的目标矩形 rect；
 *   3) 三轴旋转（含自动 Z）走位置矩阵 posmat：iOS 用的是 quaternion_from_euler(rx,ry,rz)
 *      生成四元数再 matrix4x4_from_quaternion，然后用自动 Z 旋转左乘；这里取等价的正交
 *      投影 2x2（Metal 的 Y 向上，Vulkan NDC 的 Y 向下，所以做 F*M*F 的坐标变换），
 *      对 rect 的四个角做同一个三轴旋转，视觉效果与 iOS 一致。
 * 三轴都是 0、且自动 Z 为 0 时，posmat = 单位阵、rect 与旧实现完全相同。
 * 结果同时给视频和字幕用，字幕才不会和画面脱节。
 */
static void compute_video_transform(FSVulkanRenderer *r, int frame_w, int frame_h,
                                    int disp_w, int disp_h,
                                    int auto_z_degrees, int sar_num, int sar_den)
{
    float rect[4] = { -1.0f, -1.0f, 1.0f, 1.0f };
    float uvmat[4] = { 1.0f, 0.0f, 0.0f, 1.0f };   /* 恒为单位阵：旋转改由 posmat 执行 */
    float posmat[4] = { 1.0f, 0.0f, 0.0f, 1.0f };  /* 单位阵 */

    int drawable_w = (int)r->swapchain_extent.width;
    int drawable_h = (int)r->swapchain_extent.height;

    r->video_w = frame_w;
    r->video_h = frame_h;

    /* 总 Z 旋转（度）：手动 + 自动。和 iOS FSMetalView 的 zDegrees 同义 */
    float total_z = r->z_rotate_degrees + (float)auto_z_degrees;
    int total_z_deg = (int)total_z;
    r->last_rot = ((total_z_deg % 360) + 360) % 360;
    int swap_wh = (((total_z_deg >= 0 ? total_z_deg : -total_z_deg) / 90) % 2) == 1;

    int fw = disp_w > 0 ? disp_w : frame_w;
    int fh = disp_h > 0 ? disp_h : frame_h;
    if (sar_num > 0 && sar_den > 0)   /* 保持视频自己的像素宽高比 */
        fw = (int)(1.0f * sar_num / sar_den * fw + 0.5f);

    if (fw > 0 && fh > 0 && drawable_w > 0 && drawable_h > 0) {
        int dw = drawable_w, dh = drawable_h;
        if (swap_wh) { int t = dw; dw = dh; dh = t; }   /* 对齐 iOS：交换 drawable 宽高 */
        if (r->scaling_mode != FS_SCALING_MODE_FILL) {
            float wr = 1.0f * dw / fw;
            float hr = 1.0f * dh / fh;
            float ratio;
            if (r->scaling_mode == FS_SCALING_MODE_ASPECT_FILL)
                ratio = wr > hr ? wr : hr;
            else
                ratio = wr < hr ? wr : hr;
            float nw = fw * ratio / dw;
            float nh = fh * ratio / dh;
            rect[0] = -nw; rect[1] = -nh; rect[2] = nw; rect[3] = nh;
        }
        /* FS_SCALING_MODE_FILL：非等比拉伸，就用整块显示区 */
    }

    /* 手动三轴旋转（正交投影），与 iOS FSMetalRenderer 的 viewMatrix 等价 */
    {
        const float DEG2RAD = (float)M_PI / 180.0f;
        float rx = r->x_rotate_degrees * DEG2RAD;
        float ry = r->y_rotate_degrees * DEG2RAD;
        float rz = r->z_rotate_degrees * DEG2RAD;

        /* iOS quaternion_from_euler：q = qx*qy*qz 顺序的 XYZ 欧拉角四元数 */
        float cx = cosf(rx * 0.5f), sx = sinf(rx * 0.5f);
        float cy = cosf(ry * 0.5f), sy = sinf(ry * 0.5f);
        float cz = cosf(rz * 0.5f), sz = sinf(rz * 0.5f);
        float qw = cx * cy * cz + sx * sy * sz;
        float qx = sx * cy * cz - cx * sy * sz;
        float qy = cx * sy * cz + sx * cy * sz;
        float qz = cx * cy * sz - sx * sy * cz;

        /* matrix4x4_from_quaternion 的左上 2x2（Metal，Y 向上）。
           记 out.x = m00*vx + m10*vy，out.y = m01*vx + m11*vy */
        float m00 = 1.0f - 2.0f * (qy * qy + qz * qz);
        float m10 = 2.0f * (qx * qy - qz * qw);
        float m01 = 2.0f * (qx * qy + qz * qw);
        float m11 = 1.0f - 2.0f * (qx * qx + qz * qz);

        /* Metal(Y 向上) -> Vulkan NDC(Y 向下)：R' = F * R * F，F = diag(1,-1) */
        float a00 = m00, a01 = -m10;
        float a10 = -m01, a11 = m11;

        /* 自动 Z 旋转在 iOS 里左乘（最外层）；同样做坐标变换 */
        float auto_rad = (float)auto_z_degrees * DEG2RAD;
        float c = cosf(auto_rad), s = sinf(auto_rad);
        /* Rz_vk = [[c, s], [-s, c]]；M = Rz_vk * A2 */
        float M00 = c * a00 + s * a10;
        float M01 = c * a01 + s * a11;
        float M10 = -s * a00 + c * a10;
        float M11 = -s * a01 + c * a11;

        /* shader 里 mat2(x,y,z,w) 是列主序：col0=(x,y)=(M00,M10)，col1=(z,w)=(M01,M11) */
        posmat[0] = M00; posmat[1] = M10;
        posmat[2] = M01; posmat[3] = M11;
    }

    memcpy(r->video_rect, rect, sizeof(rect));
    memcpy(r->video_uvmat, uvmat, sizeof(uvmat));
    memcpy(r->video_posmat, posmat, sizeof(posmat));
}

void fs_vulkan_renderer_set_rotate_degrees(FSVulkanRenderer *r, float x, float y, float z)
{
    if (!r)
        return;
    r->x_rotate_degrees = x;
    r->y_rotate_degrees = y;
    r->z_rotate_degrees = z;   /* 下一帧 compute_video_transform 生效 */
}

void fs_vulkan_renderer_set_scaling_mode(FSVulkanRenderer *r, int mode)
{
    if (!r)
        return;
    if (mode != FS_SCALING_MODE_ASPECT_FIT &&
        mode != FS_SCALING_MODE_ASPECT_FILL &&
        mode != FS_SCALING_MODE_FILL)
        return;
    r->scaling_mode = mode;   /* 下一帧 compute_video_transform 生效 */
}

int fs_vulkan_renderer_get_scaling_mode(FSVulkanRenderer *r)
{
    return r ? r->scaling_mode : FS_SCALING_MODE_ASPECT_FIT;
}

int fs_vulkan_renderer_display(FSVulkanRenderer *r, const AVFrame *frame,
                               int disp_w, int disp_h,
                               int rotate_degrees, int sar_num, int sar_den)
{
    if (!r || !r->surface_ready || !frame)
        return -1;

    /* surface 可能被 resize：先在建帧变换之前重建，确保后面用的是最新的 drawable 尺寸 */
    if (fs_vulkan_renderer_sync_surface(r) != 0 || !r->surface_ready)
        return -1;

    compute_video_transform(r, frame->width, frame->height, disp_w, disp_h,
                            rotate_degrees, sar_num, sar_den);

    /* MediaCodec 硬解：零拷贝外部显存通路 */
    if (frame->format == AV_PIX_FMT_MEDIACODEC)
        return display_mc_frame(r, frame);

    /*
     * HDR 判定对齐 iOS FSMetalPipelineMeta：YCbCr 矩阵是 BT.2020 就算 HDR，
     * 传输函数取 PQ / HLG / 线性，色域范围取帧的 color_range。
     * 屏能直出（display_hdr_support）且允许时才不做色调映射。
     */
    r->hdr_content = (frame->colorspace == AVCOL_SPC_BT2020_NCL ||
                      frame->colorspace == AVCOL_SPC_BT2020_CL) ? 1 : 0;
    r->hdr_full_range = (frame->color_range == AVCOL_RANGE_JPEG) ? 1 : 0;
    if (frame->color_trc == AVCOL_TRC_SMPTE2084) {
        r->hdr_transfer = 1;                 /* PQ */
    } else if (frame->color_trc == AVCOL_TRC_ARIB_STD_B67) {
        r->hdr_transfer = 2;                 /* HLG */
    } else {
        r->hdr_transfer = 0;                 /* 线性 */
    }
    r->hdr_display = (r->hdr_content && r->allow_hdr_display && r->display_hdr_support) ? 1 : 0;

    const uint8_t *y, *u, *v;
    int y_stride, u_stride, v_stride, w, h, is10bit = 0;
    if (ensure_yuv420p(r, frame, &y, &y_stride, &u, &u_stride, &v, &v_stride, &w, &h, &is10bit) != 0)
        return -1;

    if (ensure_yuv_textures(r, w, h, is10bit) != VK_SUCCESS)
        return -1;

    if (upload_yuv420p(r, y, y_stride, u, u_stride, v, v_stride, w, h, is10bit ? 2 : 1) != VK_SUCCESS)
        return -1;

    return draw_and_present(r, r->pipeline, r->pipeline_layout, r->descriptor_set,
                            VK_NULL_HANDLE);
}

/*
 * 只有字幕、没有视频帧（例如视频帧被清掉、只留音频在放）时调用：
 * 清屏 + 画字幕四边形。
 */
int fs_vulkan_renderer_display_sub_overlay(FSVulkanRenderer *r)
{
    if (!r || !r->surface_ready || !r->sub_overlay)
        return -1;

    if (fs_vulkan_renderer_sync_surface(r) != 0 || !r->surface_ready)
        return -1;

    return draw_and_present(r, VK_NULL_HANDLE, VK_NULL_HANDLE, VK_NULL_HANDLE, VK_NULL_HANDLE);
}

void fs_vulkan_renderer_destroy(FSVulkanRenderer *r)
{
    if (!r)
        return;

    if (r->device) {
        vkDeviceWaitIdle(r->device);

        destroy_mc_resources(r);
        destroy_sub_resources(r);   /* 依赖 render_pass，必须在其之前销毁 */
        destroy_snapshot_target(r);
        destroy_background_resources(r);
        if (r->bg_blur_pipeline)   vkDestroyPipeline(r->device, r->bg_blur_pipeline, NULL);
        if (r->bg_blur_layout)     vkDestroyPipelineLayout(r->device, r->bg_blur_layout, NULL);
        if (r->bg_draw_pipeline)   vkDestroyPipeline(r->device, r->bg_draw_pipeline, NULL);
        if (r->bg_draw_layout)     vkDestroyPipelineLayout(r->device, r->bg_draw_layout, NULL);
        if (r->bg_quad_buffer)     vkDestroyBuffer(r->device, r->bg_quad_buffer, NULL);
        if (r->bg_quad_mem)        vkFreeMemory(r->device, r->bg_quad_mem, NULL);
        if (r->bg_desc_pool)       vkDestroyDescriptorPool(r->device, r->bg_desc_pool, NULL);
        if (r->bg_desc_layout)     vkDestroyDescriptorSetLayout(r->device, r->bg_desc_layout, NULL);
        if (r->bg_sampler)         vkDestroySampler(r->device, r->bg_sampler, NULL);
        if (r->bg_pass)            vkDestroyRenderPass(r->device, r->bg_pass, NULL);
        pthread_mutex_destroy(&r->bg_mutex);
        free(r->bg_pending_pixels);
        r->bg_pending_pixels = NULL;
        if (r->snap_pass) { vkDestroyRenderPass(r->device, r->snap_pass, NULL); r->snap_pass = VK_NULL_HANDLE; }

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
