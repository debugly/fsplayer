#version 310 es

// 全屏四边形顶点 + UV，YUV420P 采样渲染。
// push constant 把四边形映射到显示区（视频和字幕共用同一套变换，字幕才能跟着视频一起
// 缩放/旋转/letterbox）：
//   rect   = (x0, y0, x1, y1)，目标矩形，NDC；Vulkan 下 (-1,-1) 是左上角
//   uvmat  = 2x2 旋转/翻转矩阵，uv' = uvmat * (uv - 0.5) + 0.5（恒为单位阵，保留兼容）
//   posmat = 2x2 位置矩阵（列主序），pos' = posmat * pos；画面三轴旋转（含自动 Z）
//            就靠它做正交投影，和 iOS FSMetalRenderer 的 viewMatrix 等价。
// rect = (-1,-1,1,1)、uvmat = 单位阵、posmat = 单位阵时，与未做变换的旧行为完全一致。

layout(location = 0) in vec2 aPos;   // -1..1（NDC）
layout(location = 1) in vec2 aUV;    // 0..1

layout(location = 0) out vec2 vUV;

layout(push_constant) uniform Push {
    vec4 rect;
    vec4 uvmat;   // (m00, m01, m10, m11)，列主序
    vec4 posmat;  // 2x2，列主序；pos' = posmat * pos
} pc;

void main()
{
    vec2 p = aPos * 0.5 + 0.5;
    vec2 pos = mix(pc.rect.xy, pc.rect.zw, p);
    mat2 pm = mat2(pc.posmat.x, pc.posmat.y, pc.posmat.z, pc.posmat.w);
    pos = pm * pos;
    mat2 m = mat2(pc.uvmat.x, pc.uvmat.y, pc.uvmat.z, pc.uvmat.w);
    vUV = m * (aUV - vec2(0.5)) + vec2(0.5);
    gl_Position = vec4(pos, 0.0, 1.0);
}
