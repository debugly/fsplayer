#version 310 es

// MediaCodec 硬解外部纹理（VK_ANDROID_external_memory_android_hardware_buffer）
// YUV -> RGB 由采样器上的 VkSamplerYcbcrConversion 完成，这里只是取回 RGB。

precision mediump float;

layout(binding = 0) uniform sampler2D extTex;

layout(location = 0) in vec2 vUV;
layout(location = 0) out vec4 outColor;

void main()
{
    outColor = vec4(texture(extTex, vUV).rgb, 1.0);
}
