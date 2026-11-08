/* SPDX-License-Identifier: LGPL-2.1-or-later */
#include "fs_vulkan_loader.h"
#include <dlfcn.h>
#include <pthread.h>
#include "ijksdl/ijksdl_log.h"
/* Keep the loader resident; all renderers and subtitle contexts share it. */
static void *loader;
static int ready;
static pthread_once_t once = PTHREAD_ONCE_INIT;
PFN_vkAcquireNextImageKHR fs_vkAcquireNextImageKHR;
PFN_vkAllocateCommandBuffers fs_vkAllocateCommandBuffers;
PFN_vkAllocateDescriptorSets fs_vkAllocateDescriptorSets;
PFN_vkAllocateMemory fs_vkAllocateMemory;
PFN_vkBeginCommandBuffer fs_vkBeginCommandBuffer;
PFN_vkBindBufferMemory fs_vkBindBufferMemory;
PFN_vkBindImageMemory fs_vkBindImageMemory;
PFN_vkCmdBeginRenderPass fs_vkCmdBeginRenderPass;
PFN_vkCmdBindDescriptorSets fs_vkCmdBindDescriptorSets;
PFN_vkCmdBindPipeline fs_vkCmdBindPipeline;
PFN_vkCmdBindVertexBuffers fs_vkCmdBindVertexBuffers;
PFN_vkCmdCopyBufferToImage fs_vkCmdCopyBufferToImage;
PFN_vkCmdCopyImageToBuffer fs_vkCmdCopyImageToBuffer;
PFN_vkCmdDraw fs_vkCmdDraw;
PFN_vkCmdEndRenderPass fs_vkCmdEndRenderPass;
PFN_vkCmdPipelineBarrier fs_vkCmdPipelineBarrier;
PFN_vkCmdPushConstants fs_vkCmdPushConstants;
PFN_vkCmdSetScissor fs_vkCmdSetScissor;
PFN_vkCmdSetViewport fs_vkCmdSetViewport;
PFN_vkCreateAndroidSurfaceKHR fs_vkCreateAndroidSurfaceKHR;
PFN_vkCreateBuffer fs_vkCreateBuffer;
PFN_vkCreateCommandPool fs_vkCreateCommandPool;
PFN_vkCreateDescriptorPool fs_vkCreateDescriptorPool;
PFN_vkCreateDescriptorSetLayout fs_vkCreateDescriptorSetLayout;
PFN_vkCreateDevice fs_vkCreateDevice;
PFN_vkCreateFence fs_vkCreateFence;
PFN_vkCreateFramebuffer fs_vkCreateFramebuffer;
PFN_vkCreateGraphicsPipelines fs_vkCreateGraphicsPipelines;
PFN_vkCreateImage fs_vkCreateImage;
PFN_vkCreateImageView fs_vkCreateImageView;
PFN_vkCreateInstance fs_vkCreateInstance;
PFN_vkCreatePipelineLayout fs_vkCreatePipelineLayout;
PFN_vkCreateRenderPass fs_vkCreateRenderPass;
PFN_vkCreateSampler fs_vkCreateSampler;
PFN_vkCreateSemaphore fs_vkCreateSemaphore;
PFN_vkCreateShaderModule fs_vkCreateShaderModule;
PFN_vkCreateSwapchainKHR fs_vkCreateSwapchainKHR;
PFN_vkDestroyBuffer fs_vkDestroyBuffer;
PFN_vkDestroyCommandPool fs_vkDestroyCommandPool;
PFN_vkDestroyDescriptorPool fs_vkDestroyDescriptorPool;
PFN_vkDestroyDescriptorSetLayout fs_vkDestroyDescriptorSetLayout;
PFN_vkDestroyDevice fs_vkDestroyDevice;
PFN_vkDestroyFence fs_vkDestroyFence;
PFN_vkDestroyFramebuffer fs_vkDestroyFramebuffer;
PFN_vkDestroyImage fs_vkDestroyImage;
PFN_vkDestroyImageView fs_vkDestroyImageView;
PFN_vkDestroyInstance fs_vkDestroyInstance;
PFN_vkDestroyPipeline fs_vkDestroyPipeline;
PFN_vkDestroyPipelineLayout fs_vkDestroyPipelineLayout;
PFN_vkDestroyRenderPass fs_vkDestroyRenderPass;
PFN_vkDestroySampler fs_vkDestroySampler;
PFN_vkDestroySemaphore fs_vkDestroySemaphore;
PFN_vkDestroyShaderModule fs_vkDestroyShaderModule;
PFN_vkDestroySurfaceKHR fs_vkDestroySurfaceKHR;
PFN_vkDestroySwapchainKHR fs_vkDestroySwapchainKHR;
PFN_vkDeviceWaitIdle fs_vkDeviceWaitIdle;
PFN_vkEndCommandBuffer fs_vkEndCommandBuffer;
PFN_vkEnumerateDeviceExtensionProperties fs_vkEnumerateDeviceExtensionProperties;
PFN_vkEnumeratePhysicalDevices fs_vkEnumeratePhysicalDevices;
PFN_vkFreeDescriptorSets fs_vkFreeDescriptorSets;
PFN_vkFreeMemory fs_vkFreeMemory;
PFN_vkGetBufferMemoryRequirements fs_vkGetBufferMemoryRequirements;
PFN_vkGetDeviceProcAddr fs_vkGetDeviceProcAddr;
PFN_vkGetDeviceQueue fs_vkGetDeviceQueue;
PFN_vkGetImageMemoryRequirements fs_vkGetImageMemoryRequirements;
PFN_vkGetPhysicalDeviceMemoryProperties fs_vkGetPhysicalDeviceMemoryProperties;
PFN_vkGetPhysicalDeviceProperties fs_vkGetPhysicalDeviceProperties;
PFN_vkGetPhysicalDeviceQueueFamilyProperties fs_vkGetPhysicalDeviceQueueFamilyProperties;
PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR fs_vkGetPhysicalDeviceSurfaceCapabilitiesKHR;
PFN_vkGetPhysicalDeviceSurfaceFormatsKHR fs_vkGetPhysicalDeviceSurfaceFormatsKHR;
PFN_vkGetSwapchainImagesKHR fs_vkGetSwapchainImagesKHR;
PFN_vkMapMemory fs_vkMapMemory;
PFN_vkQueuePresentKHR fs_vkQueuePresentKHR;
PFN_vkQueueSubmit fs_vkQueueSubmit;
PFN_vkQueueWaitIdle fs_vkQueueWaitIdle;
PFN_vkResetCommandBuffer fs_vkResetCommandBuffer;
PFN_vkResetDescriptorPool fs_vkResetDescriptorPool;
PFN_vkResetFences fs_vkResetFences;
PFN_vkUnmapMemory fs_vkUnmapMemory;
PFN_vkUpdateDescriptorSets fs_vkUpdateDescriptorSets;
PFN_vkWaitForFences fs_vkWaitForFences;
static void load_vulkan(void)
{
    loader = dlopen("libvulkan.so", RTLD_NOW | RTLD_LOCAL);
    if (!loader) {
        ALOGI("FSVulkan: loader unavailable; use OpenGL ES 3\n");
        return;
    }
    fs_vkAcquireNextImageKHR = (PFN_vkAcquireNextImageKHR)dlsym(loader, "vkAcquireNextImageKHR");
    if (!fs_vkAcquireNextImageKHR) { ALOGW("FSVulkan: missing vkAcquireNextImageKHR\n"); return; }
    fs_vkAllocateCommandBuffers = (PFN_vkAllocateCommandBuffers)dlsym(loader, "vkAllocateCommandBuffers");
    if (!fs_vkAllocateCommandBuffers) { ALOGW("FSVulkan: missing vkAllocateCommandBuffers\n"); return; }
    fs_vkAllocateDescriptorSets = (PFN_vkAllocateDescriptorSets)dlsym(loader, "vkAllocateDescriptorSets");
    if (!fs_vkAllocateDescriptorSets) { ALOGW("FSVulkan: missing vkAllocateDescriptorSets\n"); return; }
    fs_vkAllocateMemory = (PFN_vkAllocateMemory)dlsym(loader, "vkAllocateMemory");
    if (!fs_vkAllocateMemory) { ALOGW("FSVulkan: missing vkAllocateMemory\n"); return; }
    fs_vkBeginCommandBuffer = (PFN_vkBeginCommandBuffer)dlsym(loader, "vkBeginCommandBuffer");
    if (!fs_vkBeginCommandBuffer) { ALOGW("FSVulkan: missing vkBeginCommandBuffer\n"); return; }
    fs_vkBindBufferMemory = (PFN_vkBindBufferMemory)dlsym(loader, "vkBindBufferMemory");
    if (!fs_vkBindBufferMemory) { ALOGW("FSVulkan: missing vkBindBufferMemory\n"); return; }
    fs_vkBindImageMemory = (PFN_vkBindImageMemory)dlsym(loader, "vkBindImageMemory");
    if (!fs_vkBindImageMemory) { ALOGW("FSVulkan: missing vkBindImageMemory\n"); return; }
    fs_vkCmdBeginRenderPass = (PFN_vkCmdBeginRenderPass)dlsym(loader, "vkCmdBeginRenderPass");
    if (!fs_vkCmdBeginRenderPass) { ALOGW("FSVulkan: missing vkCmdBeginRenderPass\n"); return; }
    fs_vkCmdBindDescriptorSets = (PFN_vkCmdBindDescriptorSets)dlsym(loader, "vkCmdBindDescriptorSets");
    if (!fs_vkCmdBindDescriptorSets) { ALOGW("FSVulkan: missing vkCmdBindDescriptorSets\n"); return; }
    fs_vkCmdBindPipeline = (PFN_vkCmdBindPipeline)dlsym(loader, "vkCmdBindPipeline");
    if (!fs_vkCmdBindPipeline) { ALOGW("FSVulkan: missing vkCmdBindPipeline\n"); return; }
    fs_vkCmdBindVertexBuffers = (PFN_vkCmdBindVertexBuffers)dlsym(loader, "vkCmdBindVertexBuffers");
    if (!fs_vkCmdBindVertexBuffers) { ALOGW("FSVulkan: missing vkCmdBindVertexBuffers\n"); return; }
    fs_vkCmdCopyBufferToImage = (PFN_vkCmdCopyBufferToImage)dlsym(loader, "vkCmdCopyBufferToImage");
    if (!fs_vkCmdCopyBufferToImage) { ALOGW("FSVulkan: missing vkCmdCopyBufferToImage\n"); return; }
    fs_vkCmdCopyImageToBuffer = (PFN_vkCmdCopyImageToBuffer)dlsym(loader, "vkCmdCopyImageToBuffer");
    if (!fs_vkCmdCopyImageToBuffer) { ALOGW("FSVulkan: missing vkCmdCopyImageToBuffer\n"); return; }
    fs_vkCmdDraw = (PFN_vkCmdDraw)dlsym(loader, "vkCmdDraw");
    if (!fs_vkCmdDraw) { ALOGW("FSVulkan: missing vkCmdDraw\n"); return; }
    fs_vkCmdEndRenderPass = (PFN_vkCmdEndRenderPass)dlsym(loader, "vkCmdEndRenderPass");
    if (!fs_vkCmdEndRenderPass) { ALOGW("FSVulkan: missing vkCmdEndRenderPass\n"); return; }
    fs_vkCmdPipelineBarrier = (PFN_vkCmdPipelineBarrier)dlsym(loader, "vkCmdPipelineBarrier");
    if (!fs_vkCmdPipelineBarrier) { ALOGW("FSVulkan: missing vkCmdPipelineBarrier\n"); return; }
    fs_vkCmdPushConstants = (PFN_vkCmdPushConstants)dlsym(loader, "vkCmdPushConstants");
    if (!fs_vkCmdPushConstants) { ALOGW("FSVulkan: missing vkCmdPushConstants\n"); return; }
    fs_vkCmdSetScissor = (PFN_vkCmdSetScissor)dlsym(loader, "vkCmdSetScissor");
    if (!fs_vkCmdSetScissor) { ALOGW("FSVulkan: missing vkCmdSetScissor\n"); return; }
    fs_vkCmdSetViewport = (PFN_vkCmdSetViewport)dlsym(loader, "vkCmdSetViewport");
    if (!fs_vkCmdSetViewport) { ALOGW("FSVulkan: missing vkCmdSetViewport\n"); return; }
    fs_vkCreateAndroidSurfaceKHR = (PFN_vkCreateAndroidSurfaceKHR)dlsym(loader, "vkCreateAndroidSurfaceKHR");
    if (!fs_vkCreateAndroidSurfaceKHR) { ALOGW("FSVulkan: missing vkCreateAndroidSurfaceKHR\n"); return; }
    fs_vkCreateBuffer = (PFN_vkCreateBuffer)dlsym(loader, "vkCreateBuffer");
    if (!fs_vkCreateBuffer) { ALOGW("FSVulkan: missing vkCreateBuffer\n"); return; }
    fs_vkCreateCommandPool = (PFN_vkCreateCommandPool)dlsym(loader, "vkCreateCommandPool");
    if (!fs_vkCreateCommandPool) { ALOGW("FSVulkan: missing vkCreateCommandPool\n"); return; }
    fs_vkCreateDescriptorPool = (PFN_vkCreateDescriptorPool)dlsym(loader, "vkCreateDescriptorPool");
    if (!fs_vkCreateDescriptorPool) { ALOGW("FSVulkan: missing vkCreateDescriptorPool\n"); return; }
    fs_vkCreateDescriptorSetLayout = (PFN_vkCreateDescriptorSetLayout)dlsym(loader, "vkCreateDescriptorSetLayout");
    if (!fs_vkCreateDescriptorSetLayout) { ALOGW("FSVulkan: missing vkCreateDescriptorSetLayout\n"); return; }
    fs_vkCreateDevice = (PFN_vkCreateDevice)dlsym(loader, "vkCreateDevice");
    if (!fs_vkCreateDevice) { ALOGW("FSVulkan: missing vkCreateDevice\n"); return; }
    fs_vkCreateFence = (PFN_vkCreateFence)dlsym(loader, "vkCreateFence");
    if (!fs_vkCreateFence) { ALOGW("FSVulkan: missing vkCreateFence\n"); return; }
    fs_vkCreateFramebuffer = (PFN_vkCreateFramebuffer)dlsym(loader, "vkCreateFramebuffer");
    if (!fs_vkCreateFramebuffer) { ALOGW("FSVulkan: missing vkCreateFramebuffer\n"); return; }
    fs_vkCreateGraphicsPipelines = (PFN_vkCreateGraphicsPipelines)dlsym(loader, "vkCreateGraphicsPipelines");
    if (!fs_vkCreateGraphicsPipelines) { ALOGW("FSVulkan: missing vkCreateGraphicsPipelines\n"); return; }
    fs_vkCreateImage = (PFN_vkCreateImage)dlsym(loader, "vkCreateImage");
    if (!fs_vkCreateImage) { ALOGW("FSVulkan: missing vkCreateImage\n"); return; }
    fs_vkCreateImageView = (PFN_vkCreateImageView)dlsym(loader, "vkCreateImageView");
    if (!fs_vkCreateImageView) { ALOGW("FSVulkan: missing vkCreateImageView\n"); return; }
    fs_vkCreateInstance = (PFN_vkCreateInstance)dlsym(loader, "vkCreateInstance");
    if (!fs_vkCreateInstance) { ALOGW("FSVulkan: missing vkCreateInstance\n"); return; }
    fs_vkCreatePipelineLayout = (PFN_vkCreatePipelineLayout)dlsym(loader, "vkCreatePipelineLayout");
    if (!fs_vkCreatePipelineLayout) { ALOGW("FSVulkan: missing vkCreatePipelineLayout\n"); return; }
    fs_vkCreateRenderPass = (PFN_vkCreateRenderPass)dlsym(loader, "vkCreateRenderPass");
    if (!fs_vkCreateRenderPass) { ALOGW("FSVulkan: missing vkCreateRenderPass\n"); return; }
    fs_vkCreateSampler = (PFN_vkCreateSampler)dlsym(loader, "vkCreateSampler");
    if (!fs_vkCreateSampler) { ALOGW("FSVulkan: missing vkCreateSampler\n"); return; }
    fs_vkCreateSemaphore = (PFN_vkCreateSemaphore)dlsym(loader, "vkCreateSemaphore");
    if (!fs_vkCreateSemaphore) { ALOGW("FSVulkan: missing vkCreateSemaphore\n"); return; }
    fs_vkCreateShaderModule = (PFN_vkCreateShaderModule)dlsym(loader, "vkCreateShaderModule");
    if (!fs_vkCreateShaderModule) { ALOGW("FSVulkan: missing vkCreateShaderModule\n"); return; }
    fs_vkCreateSwapchainKHR = (PFN_vkCreateSwapchainKHR)dlsym(loader, "vkCreateSwapchainKHR");
    if (!fs_vkCreateSwapchainKHR) { ALOGW("FSVulkan: missing vkCreateSwapchainKHR\n"); return; }
    fs_vkDestroyBuffer = (PFN_vkDestroyBuffer)dlsym(loader, "vkDestroyBuffer");
    if (!fs_vkDestroyBuffer) { ALOGW("FSVulkan: missing vkDestroyBuffer\n"); return; }
    fs_vkDestroyCommandPool = (PFN_vkDestroyCommandPool)dlsym(loader, "vkDestroyCommandPool");
    if (!fs_vkDestroyCommandPool) { ALOGW("FSVulkan: missing vkDestroyCommandPool\n"); return; }
    fs_vkDestroyDescriptorPool = (PFN_vkDestroyDescriptorPool)dlsym(loader, "vkDestroyDescriptorPool");
    if (!fs_vkDestroyDescriptorPool) { ALOGW("FSVulkan: missing vkDestroyDescriptorPool\n"); return; }
    fs_vkDestroyDescriptorSetLayout = (PFN_vkDestroyDescriptorSetLayout)dlsym(loader, "vkDestroyDescriptorSetLayout");
    if (!fs_vkDestroyDescriptorSetLayout) { ALOGW("FSVulkan: missing vkDestroyDescriptorSetLayout\n"); return; }
    fs_vkDestroyDevice = (PFN_vkDestroyDevice)dlsym(loader, "vkDestroyDevice");
    if (!fs_vkDestroyDevice) { ALOGW("FSVulkan: missing vkDestroyDevice\n"); return; }
    fs_vkDestroyFence = (PFN_vkDestroyFence)dlsym(loader, "vkDestroyFence");
    if (!fs_vkDestroyFence) { ALOGW("FSVulkan: missing vkDestroyFence\n"); return; }
    fs_vkDestroyFramebuffer = (PFN_vkDestroyFramebuffer)dlsym(loader, "vkDestroyFramebuffer");
    if (!fs_vkDestroyFramebuffer) { ALOGW("FSVulkan: missing vkDestroyFramebuffer\n"); return; }
    fs_vkDestroyImage = (PFN_vkDestroyImage)dlsym(loader, "vkDestroyImage");
    if (!fs_vkDestroyImage) { ALOGW("FSVulkan: missing vkDestroyImage\n"); return; }
    fs_vkDestroyImageView = (PFN_vkDestroyImageView)dlsym(loader, "vkDestroyImageView");
    if (!fs_vkDestroyImageView) { ALOGW("FSVulkan: missing vkDestroyImageView\n"); return; }
    fs_vkDestroyInstance = (PFN_vkDestroyInstance)dlsym(loader, "vkDestroyInstance");
    if (!fs_vkDestroyInstance) { ALOGW("FSVulkan: missing vkDestroyInstance\n"); return; }
    fs_vkDestroyPipeline = (PFN_vkDestroyPipeline)dlsym(loader, "vkDestroyPipeline");
    if (!fs_vkDestroyPipeline) { ALOGW("FSVulkan: missing vkDestroyPipeline\n"); return; }
    fs_vkDestroyPipelineLayout = (PFN_vkDestroyPipelineLayout)dlsym(loader, "vkDestroyPipelineLayout");
    if (!fs_vkDestroyPipelineLayout) { ALOGW("FSVulkan: missing vkDestroyPipelineLayout\n"); return; }
    fs_vkDestroyRenderPass = (PFN_vkDestroyRenderPass)dlsym(loader, "vkDestroyRenderPass");
    if (!fs_vkDestroyRenderPass) { ALOGW("FSVulkan: missing vkDestroyRenderPass\n"); return; }
    fs_vkDestroySampler = (PFN_vkDestroySampler)dlsym(loader, "vkDestroySampler");
    if (!fs_vkDestroySampler) { ALOGW("FSVulkan: missing vkDestroySampler\n"); return; }
    fs_vkDestroySemaphore = (PFN_vkDestroySemaphore)dlsym(loader, "vkDestroySemaphore");
    if (!fs_vkDestroySemaphore) { ALOGW("FSVulkan: missing vkDestroySemaphore\n"); return; }
    fs_vkDestroyShaderModule = (PFN_vkDestroyShaderModule)dlsym(loader, "vkDestroyShaderModule");
    if (!fs_vkDestroyShaderModule) { ALOGW("FSVulkan: missing vkDestroyShaderModule\n"); return; }
    fs_vkDestroySurfaceKHR = (PFN_vkDestroySurfaceKHR)dlsym(loader, "vkDestroySurfaceKHR");
    if (!fs_vkDestroySurfaceKHR) { ALOGW("FSVulkan: missing vkDestroySurfaceKHR\n"); return; }
    fs_vkDestroySwapchainKHR = (PFN_vkDestroySwapchainKHR)dlsym(loader, "vkDestroySwapchainKHR");
    if (!fs_vkDestroySwapchainKHR) { ALOGW("FSVulkan: missing vkDestroySwapchainKHR\n"); return; }
    fs_vkDeviceWaitIdle = (PFN_vkDeviceWaitIdle)dlsym(loader, "vkDeviceWaitIdle");
    if (!fs_vkDeviceWaitIdle) { ALOGW("FSVulkan: missing vkDeviceWaitIdle\n"); return; }
    fs_vkEndCommandBuffer = (PFN_vkEndCommandBuffer)dlsym(loader, "vkEndCommandBuffer");
    if (!fs_vkEndCommandBuffer) { ALOGW("FSVulkan: missing vkEndCommandBuffer\n"); return; }
    fs_vkEnumerateDeviceExtensionProperties = (PFN_vkEnumerateDeviceExtensionProperties)dlsym(loader, "vkEnumerateDeviceExtensionProperties");
    if (!fs_vkEnumerateDeviceExtensionProperties) { ALOGW("FSVulkan: missing vkEnumerateDeviceExtensionProperties\n"); return; }
    fs_vkEnumeratePhysicalDevices = (PFN_vkEnumeratePhysicalDevices)dlsym(loader, "vkEnumeratePhysicalDevices");
    if (!fs_vkEnumeratePhysicalDevices) { ALOGW("FSVulkan: missing vkEnumeratePhysicalDevices\n"); return; }
    fs_vkFreeDescriptorSets = (PFN_vkFreeDescriptorSets)dlsym(loader, "vkFreeDescriptorSets");
    if (!fs_vkFreeDescriptorSets) { ALOGW("FSVulkan: missing vkFreeDescriptorSets\n"); return; }
    fs_vkFreeMemory = (PFN_vkFreeMemory)dlsym(loader, "vkFreeMemory");
    if (!fs_vkFreeMemory) { ALOGW("FSVulkan: missing vkFreeMemory\n"); return; }
    fs_vkGetBufferMemoryRequirements = (PFN_vkGetBufferMemoryRequirements)dlsym(loader, "vkGetBufferMemoryRequirements");
    if (!fs_vkGetBufferMemoryRequirements) { ALOGW("FSVulkan: missing vkGetBufferMemoryRequirements\n"); return; }
    fs_vkGetDeviceProcAddr = (PFN_vkGetDeviceProcAddr)dlsym(loader, "vkGetDeviceProcAddr");
    if (!fs_vkGetDeviceProcAddr) { ALOGW("FSVulkan: missing vkGetDeviceProcAddr\n"); return; }
    fs_vkGetDeviceQueue = (PFN_vkGetDeviceQueue)dlsym(loader, "vkGetDeviceQueue");
    if (!fs_vkGetDeviceQueue) { ALOGW("FSVulkan: missing vkGetDeviceQueue\n"); return; }
    fs_vkGetImageMemoryRequirements = (PFN_vkGetImageMemoryRequirements)dlsym(loader, "vkGetImageMemoryRequirements");
    if (!fs_vkGetImageMemoryRequirements) { ALOGW("FSVulkan: missing vkGetImageMemoryRequirements\n"); return; }
    fs_vkGetPhysicalDeviceMemoryProperties = (PFN_vkGetPhysicalDeviceMemoryProperties)dlsym(loader, "vkGetPhysicalDeviceMemoryProperties");
    if (!fs_vkGetPhysicalDeviceMemoryProperties) { ALOGW("FSVulkan: missing vkGetPhysicalDeviceMemoryProperties\n"); return; }
    fs_vkGetPhysicalDeviceProperties = (PFN_vkGetPhysicalDeviceProperties)dlsym(loader, "vkGetPhysicalDeviceProperties");
    if (!fs_vkGetPhysicalDeviceProperties) { ALOGW("FSVulkan: missing vkGetPhysicalDeviceProperties\n"); return; }
    fs_vkGetPhysicalDeviceQueueFamilyProperties = (PFN_vkGetPhysicalDeviceQueueFamilyProperties)dlsym(loader, "vkGetPhysicalDeviceQueueFamilyProperties");
    if (!fs_vkGetPhysicalDeviceQueueFamilyProperties) { ALOGW("FSVulkan: missing vkGetPhysicalDeviceQueueFamilyProperties\n"); return; }
    fs_vkGetPhysicalDeviceSurfaceCapabilitiesKHR = (PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR)dlsym(loader, "vkGetPhysicalDeviceSurfaceCapabilitiesKHR");
    if (!fs_vkGetPhysicalDeviceSurfaceCapabilitiesKHR) { ALOGW("FSVulkan: missing vkGetPhysicalDeviceSurfaceCapabilitiesKHR\n"); return; }
    fs_vkGetPhysicalDeviceSurfaceFormatsKHR = (PFN_vkGetPhysicalDeviceSurfaceFormatsKHR)dlsym(loader, "vkGetPhysicalDeviceSurfaceFormatsKHR");
    if (!fs_vkGetPhysicalDeviceSurfaceFormatsKHR) { ALOGW("FSVulkan: missing vkGetPhysicalDeviceSurfaceFormatsKHR\n"); return; }
    fs_vkGetSwapchainImagesKHR = (PFN_vkGetSwapchainImagesKHR)dlsym(loader, "vkGetSwapchainImagesKHR");
    if (!fs_vkGetSwapchainImagesKHR) { ALOGW("FSVulkan: missing vkGetSwapchainImagesKHR\n"); return; }
    fs_vkMapMemory = (PFN_vkMapMemory)dlsym(loader, "vkMapMemory");
    if (!fs_vkMapMemory) { ALOGW("FSVulkan: missing vkMapMemory\n"); return; }
    fs_vkQueuePresentKHR = (PFN_vkQueuePresentKHR)dlsym(loader, "vkQueuePresentKHR");
    if (!fs_vkQueuePresentKHR) { ALOGW("FSVulkan: missing vkQueuePresentKHR\n"); return; }
    fs_vkQueueSubmit = (PFN_vkQueueSubmit)dlsym(loader, "vkQueueSubmit");
    if (!fs_vkQueueSubmit) { ALOGW("FSVulkan: missing vkQueueSubmit\n"); return; }
    fs_vkQueueWaitIdle = (PFN_vkQueueWaitIdle)dlsym(loader, "vkQueueWaitIdle");
    if (!fs_vkQueueWaitIdle) { ALOGW("FSVulkan: missing vkQueueWaitIdle\n"); return; }
    fs_vkResetCommandBuffer = (PFN_vkResetCommandBuffer)dlsym(loader, "vkResetCommandBuffer");
    if (!fs_vkResetCommandBuffer) { ALOGW("FSVulkan: missing vkResetCommandBuffer\n"); return; }
    fs_vkResetDescriptorPool = (PFN_vkResetDescriptorPool)dlsym(loader, "vkResetDescriptorPool");
    if (!fs_vkResetDescriptorPool) { ALOGW("FSVulkan: missing vkResetDescriptorPool\n"); return; }
    fs_vkResetFences = (PFN_vkResetFences)dlsym(loader, "vkResetFences");
    if (!fs_vkResetFences) { ALOGW("FSVulkan: missing vkResetFences\n"); return; }
    fs_vkUnmapMemory = (PFN_vkUnmapMemory)dlsym(loader, "vkUnmapMemory");
    if (!fs_vkUnmapMemory) { ALOGW("FSVulkan: missing vkUnmapMemory\n"); return; }
    fs_vkUpdateDescriptorSets = (PFN_vkUpdateDescriptorSets)dlsym(loader, "vkUpdateDescriptorSets");
    if (!fs_vkUpdateDescriptorSets) { ALOGW("FSVulkan: missing vkUpdateDescriptorSets\n"); return; }
    fs_vkWaitForFences = (PFN_vkWaitForFences)dlsym(loader, "vkWaitForFences");
    if (!fs_vkWaitForFences) { ALOGW("FSVulkan: missing vkWaitForFences\n"); return; }
    ready = 1;
}
int fs_vulkan_loader_init(void)
{
    pthread_once(&once, load_vulkan);
    return ready ? 0 : -1;
}
