#version 310 es

// 字幕四边形：单位四边形(0..1) 经 push constant 映射到目标 NDC 矩形。
// 目标矩形由 CPU 侧算好（像素 -> NDC），所以着色器不需要知道视口尺寸。
// Vulkan NDC：(-1,-1) 是画面左上角，和渲染器现有约定一致。

layout(location = 0) in vec2 aPos;   // 0..1
layout(location = 1) in vec2 aUV;

layout(location = 0) out vec2 vUV;

layout(push_constant) uniform PushConstant {
    vec4 rect;   // x0, y0, x1, y1 (NDC)
} pc;

void main()
{
    vec2 p = mix(pc.rect.xy, pc.rect.zw, aPos);
    gl_Position = vec4(p, 0.0, 1.0);
    vUV = aUV;
}
