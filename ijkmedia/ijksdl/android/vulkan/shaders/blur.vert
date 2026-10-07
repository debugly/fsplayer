#version 310 es

// 高斯模糊/背景合成用的全屏四边形。
// 顶点缓冲给的是 0..1 的单位四边形（和字幕共用），这里直接映射到整个 NDC。
// 和 sub.vert 不同：模糊 pass 不需要 push constant 的矩形变换，画面永远是满屏，
// 于是管线布局可以只留片元那一段 push constant。

layout(location = 0) in vec2 aPos;   // 0..1
layout(location = 1) in vec2 aUV;

layout(location = 0) out vec2 vUV;

void main()
{
    gl_Position = vec4(aPos * 2.0 - 1.0, 0.0, 1.0);
    vUV = aUV;
}
