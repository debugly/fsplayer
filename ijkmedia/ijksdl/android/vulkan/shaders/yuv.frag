#version 310 es

// YUV420P (3 平面 R8 纹理) -> RGB 转换
// BT.601 full-range

precision mediump float;

layout(binding = 1) uniform sampler2D yTex;
layout(binding = 2) uniform sampler2D uTex;
layout(binding = 3) uniform sampler2D vTex;

// 色彩调整（亮度/饱和度/对比度），对齐 iOS FSMetalShaders.metal 的 rgb_adjust。
// 片元侧这一段 push constant 独立于顶点侧那段（VkPushConstantRange 只要不重叠即可）。
// (1,1,1,0) 表示不调整，走原样输出。
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
    float y = texture(yTex, vUV).r;
    float u = texture(uTex, vUV).r;
    float v = texture(vTex, vUV).r;

    // R8_UNORM 采样值在 [0,1]，full-range YUV 中心偏移 0.5
    float r = y + 1.402   * (v - 0.5);
    float g = y - 0.344136 * (u - 0.5) - 0.714136 * (v - 0.5);
    float b = y + 1.772   * (u - 0.5);

    outColor = vec4(rgb_adjust(vec3(r, g, b), cp.adjust), 1.0);
}
