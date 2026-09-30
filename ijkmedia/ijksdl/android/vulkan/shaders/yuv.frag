#version 310 es

// YUV420P (3 平面 R8 纹理) -> RGB 转换
// BT.601 full-range

precision mediump float;

layout(binding = 1) uniform sampler2D yTex;
layout(binding = 2) uniform sampler2D uTex;
layout(binding = 3) uniform sampler2D vTex;

layout(location = 0) in vec2 vUV;
layout(location = 0) out vec4 outColor;

void main()
{
    float y = texture(yTex, vUV).r;
    float u = texture(uTex, vUV).r;
    float v = texture(vTex, vUV).r;

    // R8_UNORM 采样值在 [0,1]，full-range YUV 中心偏移 0.5
    float r = y + 1.402   * (v - 0.5);
    float g = y - 0.344136 * (u - 0.5) - 0.714136 * (v - 0.5);
    float b = y + 1.772   * (u - 0.5);

    outColor = vec4(r, g, b, 1.0);
}
