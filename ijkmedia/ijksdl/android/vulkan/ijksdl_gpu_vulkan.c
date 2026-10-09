/*****************************************************************************
 * ijksdl_gpu_vulkan.c
 *****************************************************************************
 *
 * Copyright (c) 2024 debugly <qianlongxu@gmail.com>
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

/*
 * Android 侧的 SDL_GPU（字幕渲染用），跑在 Vulkan 渲染器的 device 上。
 *
 * 移植自 iOS 的 ijksdl_gpu_metal.m，语义保持一致：
 *   - A8 纹理带 palette[256]（0xAARRGGBB）；安卓在“画进 FBO 之前”用 CPU
 *     展开成预乘 RGBA，所以着色器不需要 palette 查表（Metal 放在片元里做）。
 *   - BRGA 纹理是 libass 输出的预乘 BGRA 位图，直接以 B8G8R8A8 采样。
 *   - 两条 pass（画进 FBO、FBO 纹理叠到视频上）都是预乘 alpha 混合：
 *     ONE / ONE_MINUS_SRC_ALPHA。
 *   - 上传与 FBO 绘制各用一套自己的 command buffer + fence，提交后等完成
 *     （字幕更新频率低），绝不碰渲染线程正在记录的那个 command buffer。
 */

#include "ijksdl_gpu_vulkan.h"

#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#include "ijksdl/ijksdl_gpu.h"
#include "ijksdl/ijksdl_log.h"

#include "libavutil/mem.h"

#include "../../ijkplayer/ff_subtitle_def.h"

#include "shaders/sub.vert.spv.h"
#include "shaders/sub.frag.spv.h"

#define FSVK_MAX_SUB_TEX SUB_REF_MAX_LEN

typedef struct {
    float pos[2];
    float uv[2];
} FSVKVertex;

/* 单位四边形：0..1，uv(0,0) 是左上角；实际位置由 push constant 给出 */
static const FSVKVertex kUnitQuad[6] = {
    {{0.0f, 0.0f}, {0.0f, 0.0f}},
    {{1.0f, 0.0f}, {1.0f, 0.0f}},
    {{1.0f, 1.0f}, {1.0f, 1.0f}},
    {{0.0f, 0.0f}, {0.0f, 0.0f}},
    {{1.0f, 1.0f}, {1.0f, 1.0f}},
    {{0.0f, 1.0f}, {0.0f, 1.0f}},
};

typedef struct FSVulkanGpu FSVulkanGpu;
typedef struct FSVulkanTexture FSVulkanTexture;
typedef struct FSVulkanFbo FSVulkanFbo;

typedef struct {
    VkCommandBuffer cmd;
    VkFence         fence;
} FSVKSubmitter;

struct FSVulkanGpu {
    FSVulkanContext ctx;
    int vk_alive;             /* Vulkan 资源是否还没释放（device 可能先被渲染器销毁） */

    FSVKSubmitter uploader;   /* 纹理上传 / A8 展开 */
    FSVKSubmitter drawer;     /* FBO 离屏 pass */

    VkSampler             sampler;
    VkDescriptorSetLayout tex_layout;    /* binding 1: combined image sampler */
    VkDescriptorPool      desc_pool;
    VkPipelineLayout      fbo_layout;    /* tex_layout + push constant */
    VkPipeline            fbo_pipeline;
    VkRenderPass          fbo_render_pass;

    VkBuffer       quad_buffer;
    VkDeviceMemory quad_mem;
};

struct FSVulkanTexture {
    FSVulkanSubTexture handle;   /* 交给主 pass 采样 */
    FSVulkanGpu *g;
    VkImage        image;
    VkDeviceMemory mem;
    VkFormat       format;
    int            owns_image;   /* FBO 包出来的 overlay 不拥有 image */

    /* A8：先留原始索引（pitch = w），palette 填好后第一次绘制时展开 */
    uint8_t *a8;
    int      a8_w;
    int      a8_h;
    int      expanded;
};

struct FSVulkanFbo {
    FSVulkanGpu *g;
    int w;
    int h;
    VkImage        image;
    VkDeviceMemory mem;
    VkImageView    view;
    VkRenderPass   render_pass;
    VkFramebuffer  framebuffer;

    SDL_TextureOverlay *overlay;      /* 常驻壳，getTexture 返回它 */
    VkDescriptorSet    *desc_sets;
    int                 desc_count;

    int in_pass;
    int desc_index;
};

/* ------------------------------------------------------------------------- */
/* Vulkan 小工具                                                             */
/* ------------------------------------------------------------------------- */

static uint32_t fsvk_find_memory_type(const FSVulkanContext *c, uint32_t type_bits,
                                      VkMemoryPropertyFlags props)
{
    VkPhysicalDeviceMemoryProperties mp;
    vkGetPhysicalDeviceMemoryProperties(c->physical_device, &mp);
    for (uint32_t i = 0; i < mp.memoryTypeCount; i++) {
        if ((type_bits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & props) == props)
            return i;
    }
    return 0;
}

static VkResult fsvk_create_buffer(const FSVulkanContext *c, VkDeviceSize size,
                                   VkBufferUsageFlags usage, VkBuffer *out_buf,
                                   VkDeviceMemory *out_mem)
{
    VkBufferCreateInfo bci = {
        .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = size,
        .usage = usage,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
    };
    if (vkCreateBuffer(c->device, &bci, NULL, out_buf) != VK_SUCCESS)
        return VK_ERROR_OUT_OF_DEVICE_MEMORY;

    VkMemoryRequirements req;
    vkGetBufferMemoryRequirements(c->device, *out_buf, &req);
    VkMemoryAllocateInfo ai = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = req.size,
        .memoryTypeIndex = fsvk_find_memory_type(c, req.memoryTypeBits,
                                                 VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                                                 VK_MEMORY_PROPERTY_HOST_COHERENT_BIT),
    };
    VkResult res = vkAllocateMemory(c->device, &ai, NULL, out_mem);
    if (res != VK_SUCCESS) {
        vkDestroyBuffer(c->device, *out_buf, NULL);
        *out_buf = VK_NULL_HANDLE;
        return res;
    }
    vkBindBufferMemory(c->device, *out_buf, *out_mem, 0);
    return VK_SUCCESS;
}

static VkResult fsvk_create_image(const FSVulkanContext *c, int w, int h, VkFormat format,
                                  VkImageUsageFlags usage, VkImage *out_image,
                                  VkDeviceMemory *out_mem)
{
    VkImageCreateInfo ci = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .imageType = VK_IMAGE_TYPE_2D,
        .format = format,
        .extent = { (uint32_t)w, (uint32_t)h, 1 },
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = VK_SAMPLE_COUNT_1_BIT,
        .tiling = VK_IMAGE_TILING_OPTIMAL,
        .usage = usage,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
    };
    if (vkCreateImage(c->device, &ci, NULL, out_image) != VK_SUCCESS)
        return VK_ERROR_OUT_OF_DEVICE_MEMORY;

    VkMemoryRequirements req;
    vkGetImageMemoryRequirements(c->device, *out_image, &req);
    VkMemoryAllocateInfo ai = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = req.size,
        .memoryTypeIndex = fsvk_find_memory_type(c, req.memoryTypeBits,
                                                 VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT),
    };
    if (vkAllocateMemory(c->device, &ai, NULL, out_mem) != VK_SUCCESS) {
        vkDestroyImage(c->device, *out_image, NULL);
        *out_image = VK_NULL_HANDLE;
        return VK_ERROR_OUT_OF_DEVICE_MEMORY;
    }
    vkBindImageMemory(c->device, *out_image, *out_mem, 0);
    return VK_SUCCESS;
}

static VkImageView fsvk_create_view(const FSVulkanContext *c, VkImage image, VkFormat format)
{
    VkImageViewCreateInfo ci = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .image = image,
        .viewType = VK_IMAGE_VIEW_TYPE_2D,
        .format = format,
        .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 },
    };
    VkImageView view = VK_NULL_HANDLE;
    if (vkCreateImageView(c->device, &ci, NULL, &view) != VK_SUCCESS)
        return VK_NULL_HANDLE;
    return view;
}

static VkResult fsvk_begin(FSVulkanGpu *g, FSVKSubmitter *s)
{
    vkWaitForFences(g->ctx.device, 1, &s->fence, VK_TRUE, UINT64_MAX);
    vkResetFences(g->ctx.device, 1, &s->fence);
    vkResetCommandBuffer(s->cmd, 0);
    VkCommandBufferBeginInfo bi = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    };
    return vkBeginCommandBuffer(s->cmd, &bi);
}

static VkResult fsvk_submit(FSVulkanGpu *g, FSVKSubmitter *s)
{
    vkEndCommandBuffer(s->cmd);
    VkSubmitInfo si = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .commandBufferCount = 1,
        .pCommandBuffers = &s->cmd,
    };
    VkResult res = vkQueueSubmit(g->ctx.queue, 1, &si, s->fence);
    if (res != VK_SUCCESS)
        return res;
    return vkWaitForFences(g->ctx.device, 1, &s->fence, VK_TRUE, UINT64_MAX);
}

/*
 * 把 pixels（pitch = stride）传到 image 的 (x,y,w,h) 子区域。
 * 走 TRANSIER_DST -> SHADER_READ_ONLY，传完即可被片元着色器采样。
 */
static int fsvk_upload_region(FSVulkanGpu *g, VkImage image, int x, int y, int w, int h,
                              int stride, const void *pixels, int bytes_per_pixel)
{
    if (w <= 0 || h <= 0 || !pixels || stride <= 0)
        return -1;

    FSVulkanContext *c = &g->ctx;
    FSVKSubmitter *s = &g->uploader;
    VkDeviceSize size = (VkDeviceSize)stride * h;

    VkBuffer stage = VK_NULL_HANDLE;
    VkDeviceMemory stage_mem = VK_NULL_HANDLE;
    if (fsvk_create_buffer(c, size, VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                           &stage, &stage_mem) != VK_SUCCESS)
        return -1;

    void *data = NULL;
    vkMapMemory(c->device, stage_mem, 0, size, 0, &data);
    memcpy(data, pixels, (size_t)size);
    vkUnmapMemory(c->device, stage_mem);

    if (fsvk_begin(g, s) != VK_SUCCESS) {
        vkDestroyBuffer(c->device, stage, NULL);
        vkFreeMemory(c->device, stage_mem, NULL);
        return -1;
    }

    VkImageMemoryBarrier to_dst = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
        .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 },
        .srcAccessMask = 0,
        .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
    };
    vkCmdPipelineBarrier(s->cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                         VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &to_dst);

    VkBufferImageCopy copy = {
        .imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 },
        .imageOffset = { x, y, 0 },
        .imageExtent = { (uint32_t)w, (uint32_t)h, 1 },
    };
    if (stride == w * bytes_per_pixel) {
        copy.bufferRowLength = (uint32_t)w;
        copy.bufferImageHeight = (uint32_t)h;
        vkCmdCopyBufferToImage(s->cmd, stage, image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                               1, &copy);
    } else {
        /* staging 是 stride 间距的行，按行拆开拷贝 */
        for (int row = 0; row < h; row++) {
            copy.bufferOffset = (VkDeviceSize)stride * row;
            copy.bufferRowLength = 0;
            copy.bufferImageHeight = 1;
            copy.imageOffset.y = y + row;
            copy.imageExtent.height = 1;
            vkCmdCopyBufferToImage(s->cmd, stage, image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                                   1, &copy);
        }
    }

    VkImageMemoryBarrier to_read = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        .newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 },
        .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
        .dstAccessMask = VK_ACCESS_SHADER_READ_BIT,
    };
    vkCmdPipelineBarrier(s->cmd, VK_PIPELINE_STAGE_TRANSFER_BIT,
                         VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, NULL, 0, NULL, 1, &to_read);

    int ret = (fsvk_submit(g, s) == VK_SUCCESS) ? 0 : -1;

    vkDestroyBuffer(c->device, stage, NULL);
    vkFreeMemory(c->device, stage_mem, NULL);
    return ret;
}

/* ------------------------------------------------------------------------- */
/* SDL_TextureOverlay                                                        */
/* ------------------------------------------------------------------------- */

static void fsvk_texture_dealloc(SDL_TextureOverlay *overlay)
{
    if (!overlay || !overlay->opaque)
        return;

    FSVulkanTexture *t = overlay->opaque;
    /* device 可能已随渲染器销毁（vk_alive == 0），此时绝不能再碰任何 Vulkan 资源 */
    if (t->g && t->owns_image && t->g->vk_alive) {
        vkDeviceWaitIdle(t->g->ctx.device);
        if (t->handle.view) vkDestroyImageView(t->g->ctx.device, t->handle.view, NULL);
        if (t->image)       vkDestroyImage(t->g->ctx.device, t->image, NULL);
        if (t->mem)         vkFreeMemory(t->g->ctx.device, t->mem, NULL);
    }
    av_freep(&t->a8);
    free(t);
    overlay->opaque = NULL;
}

static void *fsvk_texture_get(SDL_TextureOverlay *overlay)
{
    if (!overlay || !overlay->opaque)
        return NULL;
    FSVulkanTexture *t = overlay->opaque;
    return &t->handle;
}

static void fsvk_texture_replace_region(SDL_TextureOverlay *overlay, SDL_Rectangle rect, void *pixels)
{
    if (!overlay || !overlay->opaque || !pixels)
        return;

    FSVulkanTexture *t = overlay->opaque;
    /* 和 Metal 实现一致的越界回退：整行/整列当作全宽/全高 */
    if (rect.x + rect.w > overlay->w) {
        rect.x = 0;
        rect.w = overlay->w;
    }
    if (rect.y + rect.h > overlay->h) {
        rect.y = 0;
        rect.h = overlay->h;
    }
    overlay->dirtyRect = SDL_union_rectangle(overlay->dirtyRect, rect);

    int bpp = (t->format == VK_FORMAT_R8G8B8A8_UNORM ||
               t->format == VK_FORMAT_B8G8R8A8_UNORM) ? 4 : 1;
    fsvk_upload_region(t->g, t->image, rect.x, rect.y, rect.w, rect.h,
                       rect.stride, pixels, bpp);
}

static void fsvk_texture_clear_dirty(SDL_TextureOverlay *overlay)
{
    if (!overlay || !overlay->opaque)
        return;
    if (isZeroRectangle(overlay->dirtyRect))
        return;

    FSVulkanTexture *t = overlay->opaque;
    int h = overlay->dirtyRect.h;
    int stride = overlay->dirtyRect.stride > 0 ? overlay->dirtyRect.stride
                                               : overlay->dirtyRect.w * 4;
    /* 上一帧的字幕区域擦成全透明，否则残影 */
    void *zeros = av_mallocz((size_t)stride * h);
    if (zeros) {
        fsvk_upload_region(t->g, t->image, overlay->dirtyRect.x, overlay->dirtyRect.y,
                           overlay->dirtyRect.w, h, stride, zeros, 4);
        av_free(zeros);
    }
    overlay->dirtyRect = SDL_Zero_Rectangle;
}

static SDL_TextureOverlay *fsvk_new_overlay(FSVulkanGpu *g, VkImageView view, VkFormat format,
                                            int w, int h, SDL_TEXTURE_FMT fmt, int owns_image)
{
    FSVulkanTexture *t = calloc(1, sizeof(FSVulkanTexture));
    if (!t)
        return NULL;
    t->g = g;
    t->format = format;
    t->owns_image = owns_image;
    t->handle.view = view;
    t->handle.width = w;
    t->handle.height = h;
    t->handle.is_a8 = (fmt == SDL_TEXTURE_FMT_A8);

    SDL_TextureOverlay *overlay = calloc(1, sizeof(SDL_TextureOverlay));
    if (!overlay) {
        free(t);
        return NULL;
    }
    overlay->opaque = t;
    overlay->w = w;
    overlay->h = h;
    overlay->fmt = fmt;
    overlay->scale = 1.0f;
    overlay->refCount = 1;
    overlay->getTexture = fsvk_texture_get;
    overlay->replaceRegion = fsvk_texture_replace_region;
    overlay->clearDirtyRect = fsvk_texture_clear_dirty;
    overlay->dealloc = fsvk_texture_dealloc;
    return overlay;
}

/*
 * A8 + palette -> 预乘 RGBA。
 * palette 是 0xAARRGGBB（同 ffmpeg PAL8 / Metal palette 着色器），
 * 并做 straight -> premultiplied：rgb = rgb * a / 255。
 */
static void fsvk_expand_a8(FSVulkanTexture *t, SDL_TextureOverlay *overlay)
{
    if (t->expanded || !t->a8)
        return;

    int w = t->a8_w;
    int h = t->a8_h;
    uint8_t *rgba = av_mallocz((size_t)w * h * 4);
    if (!rgba)
        return;

    for (int y = 0; y < h; y++) {
        const uint8_t *src = t->a8 + (size_t)y * w;
        uint8_t *dst = rgba + (size_t)y * w * 4;
        for (int x = 0; x < w; x++) {
            uint32_t c = overlay->palette[src[x]];
            uint32_t b = c & 0xFF;
            uint32_t g = (c >> 8) & 0xFF;
            uint32_t r = (c >> 16) & 0xFF;
            uint32_t a = (c >> 24) & 0xFF;
            dst[0] = (uint8_t)((r * a + 127) / 255);
            dst[1] = (uint8_t)((g * a + 127) / 255);
            dst[2] = (uint8_t)((b * a + 127) / 255);
            dst[3] = (uint8_t)a;
            dst += 4;
        }
    }

    if (fsvk_upload_region(t->g, t->image, 0, 0, w, h, w * 4, rgba, 4) == 0) {
        av_freep(&t->a8);
        t->expanded = 1;
    }
    av_free(rgba);
}

/* ------------------------------------------------------------------------- */
/* SDL_FBOOverlay                                                            */
/* ------------------------------------------------------------------------- */

static void fsvk_fbo_write_descriptor(FSVulkanFbo *f, int index, FSVulkanSubTexture *tex)
{
    VkDescriptorImageInfo ii = {
        .imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        .imageView = tex->view,
        .sampler = f->g->sampler,
    };
    VkWriteDescriptorSet wr = {
        .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
        .dstSet = f->desc_sets[index],
        .dstBinding = 1,
        .descriptorCount = 1,
        .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .pImageInfo = &ii,
    };
    vkUpdateDescriptorSets(f->g->ctx.device, 1, &wr, 0, NULL);
}

static void fsvk_fbo_clear(SDL_FBOOverlay *overlay)
{
    /* 清屏由 beginDraw 的 loadOp = CLEAR（透明黑）完成 */
    (void)overlay;
}

static void fsvk_fbo_begin_draw(SDL_GPU *gpu, SDL_FBOOverlay *overlay, int ass)
{
    (void)ass;
    if (!gpu || !gpu->opaque || !overlay || !overlay->opaque)
        return;

    FSVulkanFbo *f = overlay->opaque;
    FSVulkanGpu *g = f->g;
    FSVKSubmitter *s = &g->drawer;

    if (fsvk_begin(g, s) != VK_SUCCESS)
        return;

    VkClearValue clear = { .color = {{0.0f, 0.0f, 0.0f, 0.0f}} };
    VkRenderPassBeginInfo rpi = {
        .sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
        .renderPass = f->render_pass,
        .framebuffer = f->framebuffer,
        .renderArea = {{0, 0}, {(uint32_t)f->w, (uint32_t)f->h}},
        .clearValueCount = 1,
        .pClearValues = &clear,
    };
    vkCmdBeginRenderPass(s->cmd, &rpi, VK_SUBPASS_CONTENTS_INLINE);
    vkCmdBindPipeline(s->cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, g->fbo_pipeline);

    VkViewport vp = { 0, 0, (float)f->w, (float)f->h, 0.0f, 1.0f };
    VkRect2D sc = { {0, 0}, {(uint32_t)f->w, (uint32_t)f->h} };
    vkCmdSetViewport(s->cmd, 0, 1, &vp);
    vkCmdSetScissor(s->cmd, 0, 1, &sc);

    VkDeviceSize offset = 0;
    vkCmdBindVertexBuffers(s->cmd, 0, 1, &g->quad_buffer, &offset);

    f->in_pass = 1;
    f->desc_index = 0;
}

static void fsvk_fbo_draw_texture(SDL_GPU *gpu, SDL_FBOOverlay *overlay,
                                  SDL_TextureOverlay *toverlay, SDL_Rectangle frame)
{
    if (!gpu || !overlay || !overlay->opaque || !toverlay)
        return;

    FSVulkanFbo *f = overlay->opaque;
    FSVulkanGpu *g = f->g;
    FSVulkanTexture *t = toverlay->opaque;
    if (!f->in_pass || !t)
        return;

    /* A8 在这里才展开：palette 是 createTexture 之后才填进来的 */
    if (toverlay->fmt == SDL_TEXTURE_FMT_A8)
        fsvk_expand_a8(t, toverlay);

    if (f->desc_index >= f->desc_count)
        return;
    int index = f->desc_index++;
    fsvk_fbo_write_descriptor(f, index, &t->handle);

    VkDescriptorSet set = f->desc_sets[index];
    vkCmdBindDescriptorSets(g->drawer.cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, g->fbo_layout,
                            0, 1, &set, 0, NULL);

    /* 像素矩形 -> NDC（Vulkan：(-1,-1) 是左上角） */
    float x0 = 2.0f * frame.x / f->w - 1.0f;
    float y0 = 2.0f * frame.y / f->h - 1.0f;
    float x1 = 2.0f * (frame.x + frame.w) / f->w - 1.0f;
    float y1 = 2.0f * (frame.y + frame.h) / f->h - 1.0f;
    float rect[4] = { x0, y0, x1, y1 };
    vkCmdPushConstants(g->drawer.cmd, g->fbo_layout, VK_SHADER_STAGE_VERTEX_BIT,
                       0, sizeof(rect), rect);
    vkCmdDraw(g->drawer.cmd, 6, 1, 0, 0);
}

static void fsvk_fbo_end_draw(SDL_GPU *gpu, SDL_FBOOverlay *overlay)
{
    if (!gpu || !overlay || !overlay->opaque)
        return;

    FSVulkanFbo *f = overlay->opaque;
    if (!f->in_pass)
        return;

    vkCmdEndRenderPass(f->g->drawer.cmd);
    fsvk_submit(f->g, &f->g->drawer);
    f->in_pass = 0;
}

static SDL_TextureOverlay *fsvk_fbo_get_texture(SDL_FBOOverlay *overlay)
{
    if (!overlay || !overlay->opaque)
        return NULL;
    FSVulkanFbo *f = overlay->opaque;
    /* +1 交给调用方（ff_subtitle.c 约定：getTexture 返回的是 retained 引用） */
    return SDL_TextureOverlay_Retain(f->overlay);
}

static void fsvk_fbo_dealloc(SDL_FBOOverlay *overlay)
{
    if (!overlay || !overlay->opaque)
        return;

    FSVulkanFbo *f = overlay->opaque;
    FSVulkanGpu *g = f->g;
    /* device 可能已随渲染器销毁（vk_alive == 0），此时绝不能再碰任何 Vulkan 资源 */
    if (g && !g->vk_alive)
        g = NULL;
    if (g) {
        vkDeviceWaitIdle(g->ctx.device);
        if (f->overlay) {
            SDL_TextureOverlay *o = f->overlay;
            f->overlay = NULL;
            SDL_TextureOverlay_Release(&o);   /* shell 的 dealloc 不碰 FBO 资源 */
        }
        if (f->desc_sets) {
            vkFreeDescriptorSets(g->ctx.device, g->desc_pool, f->desc_count, f->desc_sets);
            free(f->desc_sets);
        }
        if (f->framebuffer) vkDestroyFramebuffer(g->ctx.device, f->framebuffer, NULL);
        if (f->render_pass) vkDestroyRenderPass(g->ctx.device, f->render_pass, NULL);
        if (f->view)        vkDestroyImageView(g->ctx.device, f->view, NULL);
        if (f->image)       vkDestroyImage(g->ctx.device, f->image, NULL);
        if (f->mem)         vkFreeMemory(g->ctx.device, f->mem, NULL);
    }
    free(f);
    overlay->opaque = NULL;
}

/* ------------------------------------------------------------------------- */
/* SDL_GPU                                                                   */
/* ------------------------------------------------------------------------- */

static SDL_TextureOverlay *fsvk_create_texture(SDL_GPU *gpu, int w, int h,
                                               SDL_TEXTURE_FMT fmt, const void *pixels)
{
    if (!gpu || !gpu->opaque || w <= 0 || h <= 0)
        return NULL;

    FSVulkanGpu *g = gpu->opaque;
    /* A8 最终展开成预乘 RGBA，所以 image 直接按 4 字节/像素开 */
    VkFormat format = (fmt == SDL_TEXTURE_FMT_A8) ? VK_FORMAT_R8G8B8A8_UNORM
                                                  : VK_FORMAT_B8G8R8A8_UNORM;

    VkImage image = VK_NULL_HANDLE;
    VkDeviceMemory mem = VK_NULL_HANDLE;
    if (fsvk_create_image(&g->ctx, w, h, format,
                          VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT,
                          &image, &mem) != VK_SUCCESS) {
        ALOGE("SDL_GPU(vulkan): create texture %dx%d failed\n", w, h);
        return NULL;
    }

    VkImageView view = fsvk_create_view(&g->ctx, image, format);
    if (!view) {
        vkDestroyImage(g->ctx.device, image, NULL);
        vkFreeMemory(g->ctx.device, mem, NULL);
        return NULL;
    }

    SDL_TextureOverlay *overlay = fsvk_new_overlay(g, view, format, w, h, fmt, 1);
    if (!overlay) {
        vkDestroyImageView(g->ctx.device, view, NULL);
        vkDestroyImage(g->ctx.device, image, NULL);
        vkFreeMemory(g->ctx.device, mem, NULL);
        return NULL;
    }
    FSVulkanTexture *t = overlay->opaque;
    t->image = image;
    t->mem = mem;

    if (fmt == SDL_TEXTURE_FMT_A8) {
        if (pixels) {
            t->a8 = av_mallocz((size_t)w * h);
            if (t->a8) {
                memcpy(t->a8, pixels, (size_t)w * h);   /* 约定：pitch = w */
                t->a8_w = w;
                t->a8_h = h;
            }
        }
    } else if (pixels) {
        fsvk_upload_region(g, image, 0, 0, w, h, w * 4, pixels, 4);
    }

    ALOGD("SDL_GPU(vulkan): texture %dx%d fmt=%s\n", w, h,
          fmt == SDL_TEXTURE_FMT_A8 ? "A8" : "BRGA");
    return overlay;
}

static SDL_FBOOverlay *fsvk_create_fbo(SDL_GPU *gpu, int w, int h)
{
    if (!gpu || !gpu->opaque || w <= 0 || h <= 0)
        return NULL;

    FSVulkanGpu *g = gpu->opaque;
    FSVulkanContext *c = &g->ctx;

    FSVulkanFbo *f = calloc(1, sizeof(FSVulkanFbo));
    if (!f)
        return NULL;
    f->g = g;
    f->w = w;
    f->h = h;

    if (fsvk_create_image(c, w, h, VK_FORMAT_B8G8R8A8_UNORM,
                          VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_SAMPLED_BIT,
                          &f->image, &f->mem) != VK_SUCCESS)
        goto fail;
    f->view = fsvk_create_view(c, f->image, VK_FORMAT_B8G8R8A8_UNORM);
    if (!f->view)
        goto fail;

    {
        VkAttachmentDescription att = {
            .format = VK_FORMAT_B8G8R8A8_UNORM,
            .samples = VK_SAMPLE_COUNT_1_BIT,
            .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
            .stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
            .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
            .finalLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };
        VkAttachmentReference ref = { 0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
        VkSubpassDescription sub = {
            .pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS,
            .colorAttachmentCount = 1,
            .pColorAttachments = &ref,
        };
        VkSubpassDependency deps[2] = {
            { .srcSubpass = VK_SUBPASS_EXTERNAL, .dstSubpass = 0,
              .srcStageMask = VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT | VK_PIPELINE_STAGE_TRANSFER_BIT,
              .dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
              .srcAccessMask = VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_TRANSFER_WRITE_BIT,
              .dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT },
            { .srcSubpass = 0, .dstSubpass = VK_SUBPASS_EXTERNAL,
              .srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
              .dstStageMask = VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
              .srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
              .dstAccessMask = VK_ACCESS_SHADER_READ_BIT },
        };
        VkRenderPassCreateInfo rpci = {
            .sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
            .attachmentCount = 1, .pAttachments = &att,
            .subpassCount = 1, .pSubpasses = &sub,
            .dependencyCount = 2, .pDependencies = deps,
        };
        if (vkCreateRenderPass(c->device, &rpci, NULL, &f->render_pass) != VK_SUCCESS)
            goto fail;
    }

    {
        VkFramebufferCreateInfo fci = {
            .sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
            .renderPass = f->render_pass,
            .attachmentCount = 1,
            .pAttachments = &f->view,
            .width = (uint32_t)w,
            .height = (uint32_t)h,
            .layers = 1,
        };
        if (vkCreateFramebuffer(c->device, &fci, NULL, &f->framebuffer) != VK_SUCCESS)
            goto fail;
    }

    /* 每次 drawTexture 用独立的 descriptor set：descriptor 是执行期读取的 */
    f->desc_count = FSVK_MAX_SUB_TEX;
    f->desc_sets = calloc(f->desc_count, sizeof(VkDescriptorSet));
    if (!f->desc_sets)
        goto fail;
    {
        VkDescriptorSetLayout layouts[FSVK_MAX_SUB_TEX];
        for (int i = 0; i < f->desc_count; i++)
            layouts[i] = g->tex_layout;
        VkDescriptorSetAllocateInfo dai = {
            .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .descriptorPool = g->desc_pool,
            .descriptorSetCount = (uint32_t)f->desc_count,
            .pSetLayouts = layouts,
        };
        if (vkAllocateDescriptorSets(c->device, &dai, f->desc_sets) != VK_SUCCESS)
            goto fail;
    }

    /* FBO 自己包一层 overlay 给主 pass 采样（不拥有 image） */
    f->overlay = fsvk_new_overlay(g, f->view, VK_FORMAT_B8G8R8A8_UNORM,
                                  w, h, SDL_TEXTURE_FMT_BRGA, 0);
    if (!f->overlay)
        goto fail;

    SDL_FBOOverlay *overlay = calloc(1, sizeof(SDL_FBOOverlay));
    if (!overlay)
        goto fail;
    overlay->opaque = f;
    overlay->w = w;
    overlay->h = h;
    overlay->clear = fsvk_fbo_clear;
    overlay->beginDraw = fsvk_fbo_begin_draw;
    overlay->drawTexture = fsvk_fbo_draw_texture;
    overlay->endDraw = fsvk_fbo_end_draw;
    overlay->getTexture = fsvk_fbo_get_texture;
    overlay->dealloc = fsvk_fbo_dealloc;

    ALOGD("SDL_GPU(vulkan): fbo %dx%d\n", w, h);
    return overlay;

fail:
    ALOGE("SDL_GPU(vulkan): fbo %dx%d failed\n", w, h);
    {
        SDL_FBOOverlay tmp = {0};
        tmp.opaque = f;
        fsvk_fbo_dealloc(&tmp);
    }
    return NULL;
}

/* 建 FBO pass 的管线：单纹理 + 预乘 alpha 混合 + 动态视口 */
static int fsvk_build_fbo_pipeline(FSVulkanGpu *g)
{
    FSVulkanContext *c = &g->ctx;
    VkDevice dev = c->device;

    VkShaderModule vs = VK_NULL_HANDLE, fs = VK_NULL_HANDLE;
    VkShaderModuleCreateInfo smci = {
        .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
    };
    smci.codeSize = sub_vert_spv_len;
    smci.pCode = (const uint32_t *)sub_vert_spv;
    if (vkCreateShaderModule(dev, &smci, NULL, &vs) != VK_SUCCESS)
        return -1;
    smci.codeSize = sub_frag_spv_len;
    smci.pCode = (const uint32_t *)sub_frag_spv;
    if (vkCreateShaderModule(dev, &smci, NULL, &fs) != VK_SUCCESS) {
        vkDestroyShaderModule(dev, vs, NULL);
        return -1;
    }

    VkPipelineShaderStageCreateInfo stages[2] = {
        { .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
          .stage = VK_SHADER_STAGE_VERTEX_BIT, .module = vs, .pName = "main" },
        { .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
          .stage = VK_SHADER_STAGE_FRAGMENT_BIT, .module = fs, .pName = "main" },
    };
    VkVertexInputBindingDescription binding = {
        .binding = 0, .stride = sizeof(FSVKVertex), .inputRate = VK_VERTEX_INPUT_RATE_VERTEX,
    };
    VkVertexInputAttributeDescription attrs[2] = {
        { .location = 0, .binding = 0, .format = VK_FORMAT_R32G32_SFLOAT,
          .offset = offsetof(FSVKVertex, pos) },
        { .location = 1, .binding = 0, .format = VK_FORMAT_R32G32_SFLOAT,
          .offset = offsetof(FSVKVertex, uv) },
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
    VkPipelineViewportStateCreateInfo vps = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        .viewportCount = 1, .scissorCount = 1,
    };
    VkPipelineRasterizationStateCreateInfo rs = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        .polygonMode = VK_POLYGON_MODE_FILL, .cullMode = VK_CULL_MODE_NONE, .lineWidth = 1.0f,
    };
    VkPipelineMultisampleStateCreateInfo ms = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        .rasterizationSamples = VK_SAMPLE_COUNT_1_BIT,
    };
    /* 位图已预乘，源因子用 ONE（对齐 Metal 的 MTLBlendFactorOne） */
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
    VkDynamicState dyn[2] = { VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR };
    VkPipelineDynamicStateCreateInfo dss = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        .dynamicStateCount = 2, .pDynamicStates = dyn,
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
        .pDynamicState = &dss,
        .layout = g->fbo_layout,
        .renderPass = g->fbo_render_pass,
        .subpass = 0,
    };
    VkResult res = vkCreateGraphicsPipelines(dev, VK_NULL_HANDLE, 1, &gpi, NULL, &g->fbo_pipeline);
    vkDestroyShaderModule(dev, vs, NULL);
    vkDestroyShaderModule(dev, fs, NULL);
    return res == VK_SUCCESS ? 0 : -1;
}

static int fsvk_create_fbo_render_pass(FSVulkanGpu *g)
{
    FSVulkanContext *c = &g->ctx;
    VkAttachmentDescription att = {
        .format = VK_FORMAT_B8G8R8A8_UNORM,
        .samples = VK_SAMPLE_COUNT_1_BIT,
        .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
        .stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
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
    return vkCreateRenderPass(c->device, &rpci, NULL, &g->fbo_render_pass) == VK_SUCCESS ? 0 : -1;
}

static void fsvk_gpu_release_vulkan(FSVulkanGpu *g)
{
    if (!g || !g->vk_alive)
        return;

    VkDevice dev = g->ctx.device;
    vkDeviceWaitIdle(dev);

    if (g->quad_buffer)     vkDestroyBuffer(dev, g->quad_buffer, NULL);
    if (g->quad_mem)        vkFreeMemory(dev, g->quad_mem, NULL);
    if (g->fbo_pipeline)    vkDestroyPipeline(dev, g->fbo_pipeline, NULL);
    if (g->fbo_layout)      vkDestroyPipelineLayout(dev, g->fbo_layout, NULL);
    if (g->fbo_render_pass) vkDestroyRenderPass(dev, g->fbo_render_pass, NULL);
    if (g->desc_pool)       vkDestroyDescriptorPool(dev, g->desc_pool, NULL);
    if (g->tex_layout)      vkDestroyDescriptorSetLayout(dev, g->tex_layout, NULL);
    if (g->sampler)         vkDestroySampler(dev, g->sampler, NULL);
    if (g->uploader.fence)  vkDestroyFence(dev, g->uploader.fence, NULL);
    if (g->drawer.fence)    vkDestroyFence(dev, g->drawer.fence, NULL);

    g->quad_buffer = VK_NULL_HANDLE;
    g->quad_mem = VK_NULL_HANDLE;
    g->fbo_pipeline = VK_NULL_HANDLE;
    g->fbo_layout = VK_NULL_HANDLE;
    g->fbo_render_pass = VK_NULL_HANDLE;
    g->desc_pool = VK_NULL_HANDLE;
    g->tex_layout = VK_NULL_HANDLE;
    g->sampler = VK_NULL_HANDLE;
    g->uploader.fence = VK_NULL_HANDLE;
    g->drawer.fence = VK_NULL_HANDLE;
    g->vk_alive = 0;
}

/*
 * 释放 Vulkan 资源；必须在 device 还活着的时候调用。
 *
 * ffp_destroy 的顺序是 SDL_VoutFreeP(vout) 先、SDL_GPUFreeP(gpu) 后
 * （见 ff_ffplay.c），也就是 device 会先被渲染器销毁。所以 vout 销毁时显式
 * 调这个函数释放资源并置位，之后 SDL_GPUFreeP 只回收壳，不再碰 device。
 */
void SDL_VulkanGPU_DetachDevice(SDL_GPU *gpu)
{
    if (!gpu || !gpu->opaque)
        return;
    /*
     * 正常只会被 vout_free_l 调一次（fsfp_destroy 里 SDL_GPUFreeP 之后再调就是
     * 在已 free 的 opaque 上操作）。ffp_destroy 的顺序是
     * SDL_VoutFreeP(vout) -> SDL_GPUFreeP(gpu)，vout 先 detach 并把 gpu->opaque
     * 置空，之后 SDL_GPUFreeP 只回收壳。这里再兜一层：detach 后清空 opaque，
     * 让后续任何一次 DetachDevice 都直接返回，不会二次碰 device。
     */
    FSVulkanGpu *g = gpu->opaque;
    gpu->opaque = NULL;
    fsvk_gpu_release_vulkan(g);
    free(g);
}

static void fsvk_gpu_dealloc(SDL_GPU *gpu)
{
    if (!gpu || !gpu->opaque)
        return;

    /* 设备还在就顺手释放（正常情况下 vout 已经 detach 过了） */
    FSVulkanGpu *g = gpu->opaque;
    gpu->opaque = NULL;
    fsvk_gpu_release_vulkan(g);
    free(g);
}

SDL_GPU *SDL_VulkanGPU_Create(const FSVulkanContext *ctx)
{
    if (!ctx || ctx->device == VK_NULL_HANDLE || ctx->command_pool == VK_NULL_HANDLE)
        return NULL;

    FSVulkanGpu *g = calloc(1, sizeof(FSVulkanGpu));
    if (!g)
        return NULL;
    g->ctx = *ctx;
    g->vk_alive = 1;

    VkDevice dev = ctx->device;

    VkSamplerCreateInfo sci = {
        .sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
        .magFilter = VK_FILTER_NEAREST,
        .minFilter = VK_FILTER_NEAREST,
        .mipmapMode = VK_SAMPLER_MIPMAP_MODE_NEAREST,
        .addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .maxLod = 1.0f,
    };
    if (vkCreateSampler(dev, &sci, NULL, &g->sampler) != VK_SUCCESS)
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
        if (vkCreateDescriptorSetLayout(dev, &dli, NULL, &g->tex_layout) != VK_SUCCESS)
            goto fail;

        VkDescriptorPoolSize ps = {
            .type = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = FSVK_MAX_SUB_TEX * 4,
        };
        VkDescriptorPoolCreateInfo pci = {
            .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .maxSets = FSVK_MAX_SUB_TEX * 4,
            .poolSizeCount = 1, .pPoolSizes = &ps,
        };
        if (vkCreateDescriptorPool(dev, &pci, NULL, &g->desc_pool) != VK_SUCCESS)
            goto fail;

        VkPushConstantRange pcr = {
            .stageFlags = VK_SHADER_STAGE_VERTEX_BIT,
            .offset = 0,
            .size = sizeof(float) * 4,
        };
        VkPipelineLayoutCreateInfo pli = {
            .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .setLayoutCount = 1, .pSetLayouts = &g->tex_layout,
            .pushConstantRangeCount = 1, .pPushConstantRanges = &pcr,
        };
        if (vkCreatePipelineLayout(dev, &pli, NULL, &g->fbo_layout) != VK_SUCCESS)
            goto fail;
    }

    if (fsvk_create_fbo_render_pass(g) != 0)
        goto fail;
    if (fsvk_build_fbo_pipeline(g) != 0)
        goto fail;

    if (fsvk_create_buffer(&g->ctx, sizeof(kUnitQuad), VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
                           &g->quad_buffer, &g->quad_mem) != VK_SUCCESS)
        goto fail;
    {
        void *data = NULL;
        vkMapMemory(dev, g->quad_mem, 0, sizeof(kUnitQuad), 0, &data);
        memcpy(data, kUnitQuad, sizeof(kUnitQuad));
        vkUnmapMemory(dev, g->quad_mem);
    }

    {
        FSVKSubmitter *subs[2] = { &g->uploader, &g->drawer };
        for (int i = 0; i < 2; i++) {
            VkCommandBufferAllocateInfo cai = {
                .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
                .commandPool = ctx->command_pool,
                .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
                .commandBufferCount = 1,
            };
            if (vkAllocateCommandBuffers(dev, &cai, &subs[i]->cmd) != VK_SUCCESS)
                goto fail;
            VkFenceCreateInfo fci = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
                                      .flags = VK_FENCE_CREATE_SIGNALED_BIT };
            if (vkCreateFence(dev, &fci, NULL, &subs[i]->fence) != VK_SUCCESS)
                goto fail;
        }
    }

    SDL_GPU *gpu = calloc(1, sizeof(SDL_GPU));
    if (!gpu)
        goto fail;
    gpu->opaque = g;
    gpu->createTexture = fsvk_create_texture;
    gpu->createFBO = fsvk_create_fbo;
    gpu->dealloc = fsvk_gpu_dealloc;

    ALOGI("SDL_GPU(vulkan): ready\n");
    return gpu;

fail:
    ALOGE("SDL_GPU(vulkan): create failed\n");
    {
        SDL_GPU tmp = {0};
        tmp.opaque = g;
        fsvk_gpu_dealloc(&tmp);
    }
    return NULL;
}

/* ------------------------------------------------------------------------- */
/* 公共生命周期函数（apple 版在 ijksdl_gpu_metal.m）                          */
/* ------------------------------------------------------------------------- */

SDL_TextureOverlay *SDL_TextureOverlay_Retain(SDL_TextureOverlay *t)
{
    if (t)
        t->refCount++;
    return t;
}

void SDL_TextureOverlay_Release(SDL_TextureOverlay **tp)
{
    if (!tp || !*tp)
        return;

    SDL_TextureOverlay *t = *tp;
    if (--t->refCount <= 0) {
        if (t->dealloc)
            t->dealloc(t);
        free(t);
    }
    *tp = NULL;
}

void SDL_FBOOverlayFreeP(SDL_FBOOverlay **poverlay)
{
    if (!poverlay || !*poverlay)
        return;

    SDL_FBOOverlay *o = *poverlay;
    if (o->dealloc)
        o->dealloc(o);
    free(o);
    *poverlay = NULL;
}

void SDL_GPUFreeP(SDL_GPU **pgpu)
{
    if (!pgpu || !*pgpu)
        return;

    SDL_GPU *g = *pgpu;
    if (g->dealloc)
        g->dealloc(g);
    free(g);
    *pgpu = NULL;
}
