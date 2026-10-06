#version 310 es

// MediaCodec 硬解外部纹理（VK_ANDROID_external_memory_android_hardware_buffer）
// YUV -> RGB 由采样器上的 VkSamplerYcbcrConversion 完成，这里只是取回 RGB。

precision mediump float;

layout(binding = 0) uniform sampler2D extTex;

// 色彩调整，和 yuv.frag 完全一致（硬解通路也要能调色）
// 块内偏移必须显式写成 32：VkPushConstantRange 的 offset 只声明这一段归谁用，
// 着色器里的成员偏移是 push constant 空间里的绝对偏移，不写就默认 0（会读到顶点段的数据）。
layout(push_constant) uniform ColorPush {
    layout(offset = 32) vec4 adjust;   // (brightness, saturation, contrast, on)
} cp;

layout(location = 0) in vec2 vUV;
layout(location = 0) out vec4 outColor;

// 和 iOS 逐字对应的调整：先对比度（绕 0.5），再亮度偏移，最后按 luma 拉饱和度
vec3 rgb_adjust(vec3 rgb, vec4 a)
{
    float B = a.x;
    float S = a.y;
    float C = a.z;
    if (a.w > 0.99) {
        rgb = (rgb - 0.5) * C + 0.5;
        rgb = rgb + (0.75 * B - 0.5) / 2.5 - 0.1;
        vec3 intensity = rgb * vec3(0.299, 0.587, 0.114);
        return intensity + S * (rgb - intensity);
    }
    return rgb;
}

void main()
{
    outColor = vec4(rgb_adjust(texture(extTex, vUV).rgb, cp.adjust), 1.0);
}
