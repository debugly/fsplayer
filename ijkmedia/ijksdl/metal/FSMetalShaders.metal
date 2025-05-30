//
//  FSMetalShaders.metal
//  FFmpegTutorial-macOS
//
//  Created by debugly on 2022/11/23.
//  Copyright © 2022 debugly's Awesome FFmpeg Tutotial. All rights reserved.
//

#include <metal_stdlib>

using namespace metal;

// Include header shared between this Metal shader code and C code executing Metal API commands.
#include "FSMetalShaderTypes.h"

// Vertex shader outputs and fragment shader inputs
struct RasterizerData
{
    // The [[position]] attribute of this member indicates that this value
    // is the clip space position of the vertex when this structure is
    // returned from the vertex function.
    float4 clipSpacePosition [[position]];
    
    //    // Since this member does not have a special attribute, the rasterizer
    //    // interpolates its value with the values of the other triangle vertices
    //    // and then passes the interpolated value to the fragment shader for each
    //    // fragment in the triangle.
    //    float4 color;
    
    float2 textureCoordinate; // 纹理坐标，会做插值处理
};

//float4 subtitle(float4 rgba,float2 texCoord,texture2d<float> subTexture,FSSubtitleArguments subRect)
//{
//    if (!subRect.on) {
//        return rgba;
//    }
//
//    //翻转画面坐标系，这个会影响字幕在画面上的位置；翻转后从底部往上布局
//    texCoord.y = 1 - texCoord.y;
//
//    float sx = subRect.x;
//    float sy = subRect.y;
//    //限定字幕纹理区域
//    if (texCoord.x >= sx && texCoord.x <= (sx + subRect.w) && texCoord.y >= sy && texCoord.y <= (sy + subRect.h)) {
//        //在该区域内，将坐标缩放到 [0,1]
//        texCoord.x = (texCoord.x - sx) / subRect.w;
//        texCoord.y = (texCoord.y - sy) / subRect.h;
//        //flip the y
//        texCoord.y = 1 - texCoord.y;
//        constexpr sampler textureSampler (mag_filter::linear,
//                                          min_filter::linear);
//        // Sample the encoded texture in the argument buffer.
//        float4 textureSample = subTexture.sample(textureSampler, texCoord);
//        // Add the subtitle and color values together and return the result.
//        return float4((1.0 - textureSample.a) * rgba + textureSample);
//    }  else {
//        return rgba;
//    }
//}

/// @brief subtitle direct output fragment shader
/// @param stage_in表示这个数据来自光栅化。（光栅化是顶点处理之后的步骤，业务层无法修改）
/// @param texture表明是纹理数据，FSFragmentTextureIndexTextureY 是索引
fragment float4 subtileDIRECTFragment(RasterizerData input [[stage_in]],
                                      texture2d<float> textureY [[ texture(FSFragmentTextureIndexTextureY) ]])
{
    // sampler是采样器
    constexpr sampler textureSampler (mag_filter::linear,
                                      min_filter::linear);
    return textureY.sample(textureSampler, input.textureCoordinate);
}

fragment float4 subtilePaletteA8Fragment(RasterizerData input [[stage_in]],
                                      texture2d<float, access::read> textureY [[ texture(FSFragmentTextureIndexTextureY) ]],
                                        constant SubtitlePaletteFragmentData &data [[buffer(1)]])
{
    uint2 position = uint2(input.textureCoordinate * float2(data.w, data.h));
    
    int loc = int(textureY.read(position, 0).a * 255);
    uint c = data.colors[loc];
    uint mask = uint(0xFFu);
    uint b = c & mask;
    uint g = (c >> 8) & mask;
    uint r = (c >> 16) & mask;
    uint a = (c >> 24) & mask;

    // from straight to pre-multiplied alpha
    return float4(r, g, b, 255.0) * a / 65025.0;
}

/// @brief subtitle swap r g fragment shader
/// @param stage_in表示这个数据来自光栅化。（光栅化是顶点处理之后的步骤，业务层无法修改）
/// @param texture表明是纹理数据，FSFragmentTextureIndexTextureY 是索引
fragment float4 subtileSWAPRGFragment(RasterizerData input [[stage_in]],
                                      texture2d<float> textureY [[ texture(FSFragmentTextureIndexTextureY) ]])
{
    // sampler是采样器
    constexpr sampler textureSampler (mag_filter::linear,
                                      min_filter::linear);
    return textureY.sample(textureSampler, input.textureCoordinate).bgra;
}


#if __METAL_VERSION__ >= 200

struct FSFragmentShaderArguments {
    texture2d<float> textureY [[ id(FSFragmentTextureIndexTextureY) ]];
    texture2d<float> textureU [[ id(FSFragmentTextureIndexTextureU) ]];
    texture2d<float> textureV [[ id(FSFragmentTextureIndexTextureV) ]];
    device FSConvertMatrix * convertMatrix [[ id(FSFragmentMatrixIndexConvert) ]];
};

vertex RasterizerData subVertexShader(uint vertexID [[vertex_id]],
                                      constant FSVertex *vertices [[buffer(FSVertexInputIndexVertices)]])
{
    RasterizerData out;
    out.clipSpacePosition = float4(vertices[vertexID].position, 0.0, 1.0);
    out.textureCoordinate = vertices[vertexID].textureCoordinate;
    return out;
}

//支持mvp矩阵
vertex RasterizerData mvpShader(uint vertexID [[vertex_id]],
                                constant FSVertexData & data [[buffer(FSVertexInputIndexVertices)]])
{
    RasterizerData out;
    FSVertex _vertex = data.vertexes[vertexID];
    float4 position = float4(_vertex.position, 0.0, 1.0);
    out.clipSpacePosition = data.modelMatrix * position;
    out.textureCoordinate = _vertex.textureCoordinate;
    return out;
}

float3 rgb_adjust(float3 rgb,float4 rgbAdjustment) {
    //C 是对比度值，B 是亮度值，S 是饱和度
    float B = rgbAdjustment.x;
    float S = rgbAdjustment.y;
    float C = rgbAdjustment.z;
    float on= rgbAdjustment.w;
    if (on > 0.99) {
        rgb = (rgb - 0.5) * C + 0.5;
        rgb = rgb + (0.75 * B - 0.5) / 2.5 - 0.1;
        float3 intensity = float3(rgb * float3(0.299, 0.587, 0.114));
        return intensity + S * (rgb - intensity);
    } else {
        return rgb;
    }
}

// mark -hdr helps

constant matrix_float3x3 RGB2020_TO_XYZ = matrix_float3x3(
                                            0.6370, 0.1446, 0.1689,
                                            0.2627, 0.6780, 0.0593,
                                            0.0000, 0.0281, 1.0610);

constant matrix_float3x3 XYZ_TO_RGB709 = matrix_float3x3(
                                            3.2410, -1.5374, -0.4986,
                                            -0.9692, 1.8760, 0.0416,
                                            0.0556, -0.2040, 1.0570);

constant matrix_float3x3 RGB2020_TO_RGB709 = RGB2020_TO_XYZ * XYZ_TO_RGB709;


// [arib b67 eotf
float arib_b67_inverse_oetf(float x)
{
    constexpr float ARIB_B67_A = 0.17883277;
    constexpr float ARIB_B67_B = 0.28466892;
    constexpr float ARIB_B67_C = 0.55991073;
    
    // Prevent negative pixels expanding into positive values.
    x = max(x, 0.0);
    if (x <= 0.5)
        x = (x * x) * (1.0 / 3.0);
    else
        x = (exp((x - ARIB_B67_C) / ARIB_B67_A) + ARIB_B67_B) / 12.0;
    return x;
}

float3 arib_b67_inverse_oetf_vec(float3 v)
{
    float r = arib_b67_inverse_oetf(v.r);
    float g = arib_b67_inverse_oetf(v.g);
    float b = arib_b67_inverse_oetf(v.b);
    return float3(r, g, b);
}

float ootf_1_2(float x)
{
    return x < 0.0 ? x : pow(x, 1.2);
}

float arib_b67_eotf(float x)
{
    return ootf_1_2(arib_b67_inverse_oetf(x));
}

float3 arib_b67_eotf_vec(float3 v)
{
    float r = arib_b67_eotf(v.r);
    float g = arib_b67_eotf(v.g);
    float b = arib_b67_eotf(v.b);
    return float3(r, g, b);
}

// arib b67 eotf]

// [st 2084 eotf

float st_2084_eotf(float x)
{
    constexpr float ST2084_M1 = 0.1593017578125;
    constexpr float ST2084_M2 = 78.84375;
    constexpr float ST2084_C1 = 0.8359375;
    constexpr float ST2084_C2 = 18.8515625;
    constexpr float ST2084_C3 = 18.6875;
    
    float xpow = pow(x, float(1.0 / ST2084_M2));
    float num = max(xpow - ST2084_C1, 0.0);
    float den = max(ST2084_C2 - ST2084_C3 * xpow, FLT_MIN);
    return pow(num/den, 1.0 / ST2084_M1);
}

float3 st_2084_eotf_vec(float3 v)
{
    float r = st_2084_eotf(v.r);
    float g = st_2084_eotf(v.g);
    float b = st_2084_eotf(v.b);
    return float3(r, g, b);
}

// st 2084 eotf]

// Narkowicz 2015, "ACES Filmic Tone Mapping Curve"
float tonemap_ACES(float x)
{
    const float a = 2.51;
    const float b = 0.03;
    const float c = 2.43;
    const float d = 0.59;
    const float e = 0.14;
    return (x * (a * x + b)) / (x * (c * x + d) + e);
}

// Hable 2010, "Filmic Tonemapping Operators"
float tonemap_Uncharted2(float x)
{
    const float A = 0.15;
    const float B = 0.50;
    const float C = 0.10;
    const float D = 0.20;
    const float E = 0.02;
    const float F = 0.30;
    
    return ((x*(A*x+C*B)+D*E)/(x*(A*x+B)+D*F))-E/F;
}

#define current_tonemap_func tonemap_Uncharted2

float3 tonemap(float3 x)
{
#define FFMAX(a,b) ((a) > (b) ? (a) : (b))
#define FFMAX3(a,b,c) FFMAX(FFMAX(a,b),c)
    
    float sig = FFMAX(FFMAX3(x.r, x.g, x.b), 1e-6);
    float sig_orig = sig;
    float peak = 20.0;
    sig = current_tonemap_func(sig) / current_tonemap_func(peak);
    x = x * sig / sig_orig;
    return x;
}

float mobius(float in, float j, float peak)
{
    float a, b;
    
    if (in <= j)
        return in;
    
    a = -j * j * (peak - 1.0f) / (j * j - 2.0f * j + peak);
    b = (j * j - 2.0f * j * peak + peak) / max(peak - 1.0f, 1e-6);
    
    return (b * b + 2.0f * b * j + j * j) / (b - a) * (in + a) / (in + b);
}

// [bt709
float rec_1886_inverse_eotf(float x)
{
    return x < 0.0 ? 0.0 : pow(x, 1.0 / 2.2);
}

float3 rec_1886_inverse_eotf_vec(float3 v)
{
    float r = rec_1886_inverse_eotf(v.r);
    float g = rec_1886_inverse_eotf(v.g);
    float b = rec_1886_inverse_eotf(v.b);
    return float3(r, g, b);
}

float rec_1886_eotf(float x)
{
    return x < 0.0 ? 0.0 : pow(x, 2.2);
}

float3 rec_1886_eotf_vec(float3 v)
{
    float r = rec_1886_eotf(v.r);
    float g = rec_1886_eotf(v.g);
    float b = rec_1886_eotf(v.b);
    return float3(r, g, b);
}

// bt709]
// mark -hdr helps

float3 hdr2sdr(float3 rgb_2020,float x,float hdrPercentage,FSColorTransferFunc transferFun)
{
    //已经使用矩阵转为RGB了，这里的RGB是经过 伽马 校正的，因此是曲线的
    if (x > 0 && x <= hdrPercentage) {
        
        // 1、HDR 非线性电信号转为 HDR 线性光信号（EOTF）
        float3 myFragColor;
        float peak_luminance = 50.0;
        if (transferFun == FSColorTransferFuncPQ) {
            float to_linear_scale = 10000.0 / peak_luminance;
            myFragColor = to_linear_scale * st_2084_eotf_vec(rgb_2020);
        } else if (transferFun == FSColorTransferFuncHLG) {
            float to_linear_scale = 1000.0 / peak_luminance;
            myFragColor = to_linear_scale * arib_b67_eotf_vec(rgb_2020);
        } else {
            myFragColor = rec_1886_eotf_vec(rgb_2020);
        }
        
        // 2、HDR 线性光信号做颜色空间转换（Color Space Converting）
        
        // RGB → XYZ：将源 RGB 颜色转换到 CIE XYZ 中间颜色空间
        // XYZ → RGB：将 XYZ 颜色转换到目标 RGB 颜色空间
        // 这两个步骤可以合并为一个矩阵运算：RGB_target = M * RGB_source，其中 M 是组合变换矩阵。
        myFragColor = myFragColor * RGB2020_TO_RGB709;
    
        // 3、HDR 线性光信号色调映射为 SDR 线性光信号（Tone Mapping）
        myFragColor = tonemap(myFragColor);

        // 4、SDR 线性光信号转 SDR 非线性电信号（OETF）
        myFragColor = rec_1886_inverse_eotf_vec(myFragColor);
        return myFragColor;
    } else {
        return rgb_2020;
    }
}

float4 yuv2rgb(float3 yuv,device FSConvertMatrix* convertMatrix,float x)
{
    //先把 [0.0,1.0] 范围的YUV 处理为 [0.0,1.0] 范围的RGB
    float3 rgb = convertMatrix->colorMatrix * (yuv + convertMatrix->offset);
    //HDR 转 SDR
    float3 myFragColor;
    if (convertMatrix->hdr) {
        myFragColor = hdr2sdr(rgb,x,convertMatrix->hdrPercentage,convertMatrix->transferFun);
    } else {
        myFragColor = rgb;
    }
    //color adjustment
    return float4(rgb_adjust(myFragColor,convertMatrix->adjustment),1.0);
}

/// @brief hdr BiPlanar fragment shader
/// @param stage_in表示这个数据来自光栅化。（光栅化是顶点处理之后的步骤，业务层无法修改）
/// @param texture表明是纹理数据，FSFragmentTextureIndexTextureY/UV 是索引
/// @param buffer表明是缓存数据，FSFragmentBufferIndexMatrix是索引
fragment float4 nv12FragmentShader(RasterizerData input [[stage_in]],
                                   device FSFragmentShaderArguments & fragmentShaderArgs [[ buffer(FSFragmentBufferLocation0) ]])
{
    // sampler是采样器
    constexpr sampler textureSampler (mag_filter::linear,
                                      min_filter::linear);
    texture2d<float> textureY = fragmentShaderArgs.textureY;
    texture2d<float> textureUV = fragmentShaderArgs.textureU;
    
    float3 yuv = float3(textureY.sample(textureSampler,  input.textureCoordinate).r,
                        textureUV.sample(textureSampler, input.textureCoordinate).rg);
    return yuv2rgb(yuv,fragmentShaderArgs.convertMatrix,input.textureCoordinate.x);
}

/// @brief yuv420p fragment shader
/// @param stage_in表示这个数据来自光栅化。（光栅化是顶点处理之后的步骤，业务层无法修改）
/// @param texture表明是纹理数据，FSFragmentTextureIndexTextureY/U/V 是索引
/// @param buffer表明是缓存数据，FSFragmentBufferIndexMatrix是索引
fragment float4 yuv420pFragmentShader(RasterizerData input [[stage_in]],
                                      device FSFragmentShaderArguments & fragmentShaderArgs [[ buffer(FSFragmentBufferLocation0) ]])
{
    // sampler是采样器
    constexpr sampler textureSampler (mag_filter::linear,
                                      min_filter::linear);
    texture2d<float> textureY = fragmentShaderArgs.textureY;
    texture2d<float> textureU = fragmentShaderArgs.textureU;
    texture2d<float> textureV = fragmentShaderArgs.textureV;
    
    float3 yuv = float3(textureY.sample(textureSampler, input.textureCoordinate).r,
                        textureU.sample(textureSampler, input.textureCoordinate).r,
                        textureV.sample(textureSampler, input.textureCoordinate).r);
    
    return yuv2rgb(yuv,fragmentShaderArgs.convertMatrix,input.textureCoordinate.x);
}

/// @brief uyvy422 fragment shader
/// @param stage_in表示这个数据来自光栅化。（光栅化是顶点处理之后的步骤，业务层无法修改）
/// @param texture表明是纹理数据，FSFragmentTextureIndexTextureY 是索引
/// @param buffer表明是缓存数据，FSFragmentBufferIndexMatrix是索引
fragment float4 uyvy422FragmentShader(RasterizerData input [[stage_in]],
                                      device FSFragmentShaderArguments & fragmentShaderArgs [[ buffer(FSFragmentBufferLocation0) ]])
{
    // sampler是采样器
    constexpr sampler textureSampler (mag_filter::linear,
                                      min_filter::linear);
    texture2d<float> textureY = fragmentShaderArgs.textureY;
    float3 tc = textureY.sample(textureSampler, input.textureCoordinate).rgb;
    float3 yuv = float3(tc.g, tc.b, tc.r);
    
    return yuv2rgb(yuv,fragmentShaderArgs.convertMatrix,input.textureCoordinate.x);
}

/// @brief ayuv fragment shader
/// @param stage_in表示这个数据来自光栅化。（光栅化是顶点处理之后的步骤，业务层无法修改）
/// @param texture表明是纹理数据，FSFragmentTextureIndexTextureY 是索引
/// @param buffer表明是缓存数据，FSFragmentBufferIndexMatrix是索引
fragment float4 ayuvFragmentShader(RasterizerData input [[stage_in]],
                                   device FSFragmentShaderArguments & fragmentShaderArgs [[ buffer(FSFragmentBufferLocation0) ]])
{
    // sampler是采样器
    constexpr sampler textureSampler (mag_filter::linear,
                                      min_filter::linear);
    texture2d<float> textureY = fragmentShaderArgs.textureY;
    float4 tc = textureY.sample(textureSampler, input.textureCoordinate).rgba;
    float3 yuv = float3(tc.g, tc.b, tc.a);
    
    return yuv2rgb(yuv,fragmentShaderArgs.convertMatrix,input.textureCoordinate.x);
}

/// @brief bgra fragment shader
/// @param stage_in表示这个数据来自光栅化。（光栅化是顶点处理之后的步骤，业务层无法修改）
/// @param texture表明是纹理数据，FSFragmentTextureIndexTextureY 是索引
fragment float4 bgraFragmentShader(RasterizerData input [[stage_in]],
                                   device FSFragmentShaderArguments & fragmentShaderArgs [[ buffer(FSFragmentBufferLocation0) ]])
{
    // sampler是采样器
    constexpr sampler textureSampler (mag_filter::linear,
                                      min_filter::linear);
    texture2d<float> textureY = fragmentShaderArgs.textureY;
    //auto converted bgra -> rgba
    float4 rgba = textureY.sample(textureSampler, input.textureCoordinate);
    //color adjustment
    device FSConvertMatrix* convertMatrix = fragmentShaderArgs.convertMatrix;
    return float4(rgb_adjust(rgba.rgb, convertMatrix->adjustment),rgba.a);
}

/// @brief argb fragment shader
/// @param stage_in表示这个数据来自光栅化。（光栅化是顶点处理之后的步骤，业务层无法修改）
/// @param texture表明是纹理数据，FSFragmentTextureIndexTextureY 是索引
fragment float4 argbFragmentShader(RasterizerData input [[stage_in]],
                                   device FSFragmentShaderArguments & fragmentShaderArgs [[ buffer(FSFragmentBufferLocation0) ]])
{
    // sampler是采样器
    constexpr sampler textureSampler (mag_filter::linear,
                                      min_filter::linear);
    texture2d<float> textureY = fragmentShaderArgs.textureY;
    //auto converted bgra -> rgba;but data is argb,so target is grab
    float4 grab = textureY.sample(textureSampler, input.textureCoordinate);
    //color adjustment
    device FSConvertMatrix* convertMatrix = fragmentShaderArgs.convertMatrix;
    return float4(rgb_adjust(grab.gra, convertMatrix->adjustment),grab.b);
}

#else

vertex RasterizerData subVertexShader(uint vertexID [[vertex_id]],
                                      constant FSVertex *vertices [[buffer(FSVertexInputIndexVertices)]])
{
    RasterizerData out;
    out.clipSpacePosition = float4(vertices[vertexID].position, 0.0, 1.0);
    out.textureCoordinate = vertices[vertexID].textureCoordinate;
    return out;
}

//支持mvp矩阵
vertex RasterizerData mvpShader(uint vertexID [[vertex_id]],
                                constant FSVertexData & data [[buffer(FSVertexInputIndexVertices)]])
{
    RasterizerData out;
    FSVertex _vertex = data.vertexes[vertexID];
    float4 position = float4(_vertex.position, 0.0, 1.0);
    out.clipSpacePosition = data.modelMatrix * position;
    out.textureCoordinate = _vertex.textureCoordinate;
    return out;
}

float3 rgb_adjust(float3 rgb,float4 rgbAdjustment) {
    //C 是对比度值，B 是亮度值，S 是饱和度
    float B = rgbAdjustment.x;
    float S = rgbAdjustment.y;
    float C = rgbAdjustment.z;
    float on= rgbAdjustment.w;
    if (on > 0.99) {
        rgb = (rgb - 0.5) * C + 0.5;
        rgb = rgb + (0.75 * B - 0.5) / 2.5 - 0.1;
        float3 intensity = float3(rgb * float3(0.299, 0.587, 0.114));
        return intensity + S * (rgb - intensity);
    } else {
        return rgb;
    }
}

/// @brief bgra fragment shader
/// @param stage_in表示这个数据来自光栅化。（光栅化是顶点处理之后的步骤，业务层无法修改）
/// @param texture表明是纹理数据，FSFragmentTextureIndexTextureY 是索引
fragment float4 bgraFragmentShader(RasterizerData input [[stage_in]],
                                   texture2d<float> textureY [[ texture(FSFragmentTextureIndexTextureY) ]],
                                   constant FSConvertMatrix &convertMatrix [[ buffer(FSFragmentMatrixIndexConvert) ]])
{
    // sampler是采样器
    constexpr sampler textureSampler (mag_filter::linear,
                                      min_filter::linear);
    //auto converted bgra -> rgba
    float4 rgba = textureY.sample(textureSampler, input.textureCoordinate);
    //color adjustment
    return float4(rgb_adjust(rgba.rgb, convertMatrix.adjustment),rgba.a);
}

/// @brief argb fragment shader
/// @param stage_in表示这个数据来自光栅化。（光栅化是顶点处理之后的步骤，业务层无法修改）
/// @param texture表明是纹理数据，FSFragmentTextureIndexTextureY 是索引
fragment float4 argbFragmentShader(RasterizerData input [[stage_in]],
                                   texture2d<float> textureY [[ texture(FSFragmentTextureIndexTextureY) ]],
                                   constant FSConvertMatrix &convertMatrix [[ buffer(FSFragmentMatrixIndexConvert) ]])
{
    // sampler是采样器
    constexpr sampler textureSampler (mag_filter::linear,
                                      min_filter::linear);
    //auto converted bgra -> rgba
    float4 grab = textureY.sample(textureSampler, input.textureCoordinate);
    //color adjustment
    return float4(rgb_adjust(grab.gra, convertMatrix.adjustment),grab.b);
}

/// @brief nv12 fragment shader
/// @param stage_in表示这个数据来自光栅化。（光栅化是顶点处理之后的步骤，业务层无法修改）
/// @param texture表明是纹理数据，FSFragmentTextureIndexTextureY/UV 是索引
/// @param buffer表明是缓存数据，FSFragmentBufferIndexMatrix是索引
fragment float4 nv12FragmentShader(RasterizerData input [[stage_in]],
                                   texture2d<float> textureY  [[ texture(FSFragmentTextureIndexTextureY)  ]],
                                   texture2d<float> textureUV [[ texture(FSFragmentTextureIndexTextureU) ]],
                                   constant FSConvertMatrix &convertMatrix [[ buffer(FSFragmentMatrixIndexConvert) ]])
{
    // sampler是采样器
    constexpr sampler textureSampler (mag_filter::linear,
                                      min_filter::linear);
    
    float3 yuv = float3(textureY.sample(textureSampler,  input.textureCoordinate).r,
                        textureUV.sample(textureSampler, input.textureCoordinate).rg);
    
    float3 rgb = convertMatrix.matrix * (yuv + convertMatrix.offset);
    //color adjustment
    return float4(rgb_adjust(rgb,convertMatrix.adjustment),1.0);
}

/// @brief yuv420p fragment shader
/// @param stage_in表示这个数据来自光栅化。（光栅化是顶点处理之后的步骤，业务层无法修改）
/// @param texture表明是纹理数据，FSFragmentTextureIndexTextureY/U/V 是索引
/// @param buffer表明是缓存数据，FSFragmentBufferIndexMatrix是索引
fragment float4 yuv420pFragmentShader(RasterizerData input [[stage_in]],
                                      texture2d<float> textureY [[ texture(FSFragmentTextureIndexTextureY) ]],
                                      texture2d<float> textureU [[ texture(FSFragmentTextureIndexTextureU) ]],
                                      texture2d<float> textureV [[ texture(FSFragmentTextureIndexTextureV) ]],
                                      constant FSConvertMatrix &convertMatrix [[ buffer(FSFragmentMatrixIndexConvert) ]])
{
    // sampler是采样器
    constexpr sampler textureSampler (mag_filter::linear,
                                      min_filter::linear);
    
    float3 yuv = float3(textureY.sample(textureSampler, input.textureCoordinate).r,
                        textureU.sample(textureSampler, input.textureCoordinate).r,
                        textureV.sample(textureSampler, input.textureCoordinate).r);
    
    float3 rgb = convertMatrix.matrix * (yuv + convertMatrix.offset);
    //color adjustment
    return float4(rgb_adjust(rgb,convertMatrix.adjustment),1.0);
}

/// @brief uyvy422 fragment shader
/// @param stage_in表示这个数据来自光栅化。（光栅化是顶点处理之后的步骤，业务层无法修改）
/// @param texture表明是纹理数据，FSFragmentTextureIndexTextureY 是索引
/// @param buffer表明是缓存数据，FSFragmentBufferIndexMatrix是索引
fragment float4 uyvy422FragmentShader(RasterizerData input [[stage_in]],
                                      texture2d<float> textureY [[ texture(FSFragmentTextureIndexTextureY) ]],
                                      constant FSConvertMatrix &convertMatrix [[ buffer(FSFragmentMatrixIndexConvert) ]])
{
    // sampler是采样器
    constexpr sampler textureSampler (mag_filter::linear,
                                      min_filter::linear);
    float3 tc = textureY.sample(textureSampler, input.textureCoordinate).rgb;
    float3 yuv = float3(tc.g, tc.b, tc.r);
    
    float3 rgb = convertMatrix.matrix * (yuv + convertMatrix.offset);
    //color adjustment
    return float4(rgb_adjust(rgb,convertMatrix.adjustment),1.0);
}
#endif
