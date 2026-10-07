#version 310 es

// 字幕四边形：单位四边形(0..1) 经 push constant 映射到目标 NDC 矩形。
// 目标矩形由 CPU 侧算好（像素 -> NDC），所以着色器不需要知道视口尺寸。
// Vulkan NDC：(-1,-1) 是画面左上角，和渲染器现有约定一致。

layout(location = 0) in vec2 aPos;   // 0..1
layout(location = 1) in vec2 aUV;

layout(location = 0) out vec2 vUV;

layout(push_constant) uniform PushConstant {
    vec4 rect;    // x0, y0, x1, y1 (NDC)
    vec4 uvmat;   // 2x2，列主序；uv' = uvmat * (uv - 0.5) + 0.5
} pc;

void main()
{
    vec2 p = mix(pc.rect.xy, pc.rect.zw, aPos);
    gl_Position = vec4(p, 0.0, 1.0);
    mat2 m = mat2(pc.uvmat.x, pc.uvmat.y, pc.uvmat.z, pc.uvmat.w);
    vUV = m * (aUV - vec2(0.5)) + vec2(0.5);
}
