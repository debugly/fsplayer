#version 310 es

// YUV420P（3 平面纹理，8bit 用 R8_UNORM / 10bit 用 R16_UNORM）-> RGB
// SDR 走原来的 BT.601 full-range；HDR(BT.2020) 走 iOS 的色调映射/直显通路。

precision highp float;

layout(binding = 1) uniform sampler2D yTex;
layout(binding = 2) uniform sampler2D uTex;
layout(binding = 3) uniform sampler2D vTex;

#include "hdr_common.glsl"

// 片元侧 push constant，块内偏移必须显式写成绝对偏移：
// VkPushConstantRange 的 offset 只声明这一段归哪个 stage 用，不写就会从 0 读（读到顶点段的 rect）。
layout(push_constant) uniform PicturePush {
    layout(offset = 32) vec4 adjust;   // (brightness, saturation, contrast, on)
    layout(offset = 48) vec4 hdr;      // (hdrContent, hdrDisplay, transferFunc, bits)
                                       // bits: 1 = 10bit 输入，2 = full range（iOS 的 offset 规则）
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
    float y = texture(yTex, vUV).r;
    float u = texture(uTex, vUV).r;
    float v = texture(vTex, vUV).r;

    int bits = int(cp.hdr.w + 0.5);      // bit0 = 10bit 输入，bit1 = full range
    bool is10bit   = (bits & 1) != 0;
    bool fullRange = (bits & 2) != 0;

    vec3 rgb;
    if (cp.hdr.x > 0.5) {
        // HDR：矩阵和偏移都对齐 iOS（8bit 归一化的 16/255 偏移，10bit 也一样，差异 <0.2%）
        float oy = fullRange ? 0.0 : (-16.0 / 255.0);
        vec3 t = vec3(y + oy, u - 0.5, v - 0.5);
        rgb = vec3(1.164384 * t.x + 0.0      * t.y + 1.67867 * t.z,
                   1.164384 * t.x - 0.187326 * t.y - 0.65042 * t.z,
                   1.164384 * t.x + 2.14177  * t.y + 0.0     * t.z);
        int tf = int(cp.hdr.z + 0.5);
        rgb = (cp.hdr.y > 0.5) ? hdr_direct(rgb, tf) : hdr2sdr(rgb, tf);
    } else {
        // SDR：沿用原来的 full-range BT.601 近似；10bit 输入先按范围归一化到 8bit 口径
        if (is10bit && !fullRange) {
            y = clamp((y * 1023.0 - 64.0) / 876.0, 0.0, 1.0);
            u = clamp((u * 1023.0 - 512.0) / 896.0 + 0.5, 0.0, 1.0);
            v = clamp((v * 1023.0 - 512.0) / 896.0 + 0.5, 0.0, 1.0);
        }
        rgb = vec3(y + 1.402   * (v - 0.5),
                   y - 0.344136 * (u - 0.5) - 0.714136 * (v - 0.5),
                   y + 1.772   * (u - 0.5));
    }

    outColor = vec4(rgb_adjust(rgb, cp.adjust), 1.0);
}
