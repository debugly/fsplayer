#version 310 es

// 一维高斯模糊（可分离：水平/垂直各来一次）。
// 权重由 CPU 算好（对称高斯，taps 个 tap，中心是 weights[0]），step 已经把方向
// 和采样间距（单位：纹理坐标）一起折进去了，所以同一个着色器既能做横向也能做纵向。
//
// 采样间距可以大于 1 个纹素：σ 大的时候按纹素逐个采样要几十个 tap 才盖得住，
// 这里把 tap 摊到 step 上（最多摊到 σ/3，覆盖到 ±5σ），一次 pass 的方差仍然是 σ²，
// 和 iOS 那边每个 iteration 都做一次 σ 高斯的意义一致。

precision mediump float;

layout(binding = 1) uniform sampler2D tex;

layout(location = 0) in vec2 vUV;
layout(location = 0) out vec4 outColor;

layout(push_constant) uniform PushConstant {
    vec2  step;              // 采样步长（含方向），单位纹理坐标
    int   taps;              // 实际 tap 数（1..16）
    float pad;               // 保持 weights 的偏移是 16 字节对齐
    float weights[16];       // 对称权重，weights[0] 为中心
} pc;

void main()
{
    vec4 sum = texture(tex, vUV) * pc.weights[0];
    float wsum = pc.weights[0];

    for (int i = 1; i < pc.taps; i++) {
        vec2 off = pc.step * float(i);
        float w = pc.weights[i];
        sum += texture(tex, vUV + off) * w;
        sum += texture(tex, vUV - off) * w;
        wsum += 2.0 * w;
    }

    outColor = sum / wsum;
}
