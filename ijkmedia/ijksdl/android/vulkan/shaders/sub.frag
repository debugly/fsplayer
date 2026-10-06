#version 310 es

// 字幕纹理（RGBA/BGRA）采样：字库位图已经带 alpha，
// 直接输出并交给管线的 alpha 混合（SRC_ALPHA / ONE_MINUS_SRC_ALPHA）。
// 顶点位置由顶点缓冲给出（子画面矩形），因此不需要 push constant。

precision mediump float;

layout(binding = 1) uniform sampler2D tex;

layout(location = 0) in vec2 vUV;
layout(location = 0) out vec4 outColor;

void main()
{
    outColor = texture(tex, vUV);
}
