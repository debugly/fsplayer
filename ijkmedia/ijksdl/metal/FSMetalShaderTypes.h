//
//  FSMetalShaderTypes.h
//  FFmpegTutorial-macOS
//
//  Created by debugly on 2022/11/23.
//  Copyright © 2022 debugly's Awesome FFmpeg Tutotial. All rights reserved.
//

#import <simd/simd.h>

typedef enum FSYUV2RGBColorMatrixType
{
    FSYUV2RGBColorMatrixNone,
    FSYUV2RGBColorMatrixBT601,
    FSYUV2RGBColorMatrixBT709,
    FSYUV2RGBColorMatrixBT2020
} FSYUV2RGBColorMatrixType;

typedef enum FSColorTransferFunc
{
    FSColorTransferFuncLINEAR,
    FSColorTransferFuncPQ,
    FSColorTransferFuncHLG,
} FSColorTransferFunc;

// Buffer index values shared between shader and C code to ensure Metal shader buffer inputs
// match Metal API buffer set calls.
typedef enum FSVertexInputIndex
{
    FSVertexInputIndexVertices  = 0,
} FSVertexInputIndex;

//  This structure defines the layout of vertices sent to the vertex
//  shader. This header is shared between the .metal shader and C code, to guarantee that
//  the layout of the vertex array in the C code matches the layout that the .metal
//  vertex shader expects.

typedef struct
{
    vector_float2 position;
    vector_float2 textureCoordinate;
} FSVertex;

typedef struct
{
    FSVertex vertexes[4];
    matrix_float4x4 modelMatrix;
} FSVertexData;

typedef struct {
    matrix_float3x3 colorMatrix;
    vector_float3 offset;
    vector_float4 adjustment;
    FSColorTransferFunc transferFun;
    float hdrPercentage;
    bool hdr;
} FSConvertMatrix;

typedef enum FSFragmentBufferArguments
{
    FSFragmentTextureIndexTextureY,
    FSFragmentTextureIndexTextureU,
    FSFragmentTextureIndexTextureV,
    FSFragmentMatrixIndexConvert
} FSFragmentBufferArguments;

typedef enum FSFragmentBufferLocation
{
    FSFragmentBufferLocation0,
} FSFragmentBufferLocation;

struct SubtitlePaletteFragmentData
{
    uint32_t w;
    uint32_t h;
    uint32_t colors[256];
};

typedef struct mp_format {
    uint32_t cvpixfmt;
    int planes;
    uint32_t formats[3];
} mp_format;

FSConvertMatrix ijk_metal_create_color_matrix(FSYUV2RGBColorMatrixType matrixType, int fullRange);
