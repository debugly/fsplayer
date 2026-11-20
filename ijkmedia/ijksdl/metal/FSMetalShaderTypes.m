//
//  FSMetalPixelTypes.h
//  FFmpegTutorial-macOS
//
//  Created by debugly on 2022/11/23.
//  Copyright © 2022 debugly's Awesome FFmpeg Tutorial. All rights reserved.
//

#import "FSMetalShaderTypes.h"
#import <CoreVideo/CVPixelBuffer.h>
#import <Metal/MTLPixelFormat.h>

static mp_format mp_formats[] = {
    {
        .cvpixfmt = kCVPixelFormatType_32BGRA,
        .planes = 1,
        .formats = {MTLPixelFormatBGRA8Unorm}
    },
    {
        .cvpixfmt = kCVPixelFormatType_32ARGB,
        .planes = 1,
        .formats = {MTLPixelFormatBGRA8Unorm}
    },
    {
        .cvpixfmt = kCVPixelFormatType_4444AYpCbCr16,
        .planes = 1,
        .formats = {MTLPixelFormatRGBA16Unorm}
    },
#if TARGET_OS_OSX
    {
        .cvpixfmt = kCVPixelFormatType_422YpCbCr8,
        .planes = 1,
        .formats = {MTLPixelFormatBGRG422}
    },
    {
        .cvpixfmt = kCVPixelFormatType_422YpCbCr8_yuvs,
        .planes = 1,
        .formats = {MTLPixelFormatGBGR422}
    },
    {
        .cvpixfmt = kCVPixelFormatType_422YpCbCr8FullRange,
        .planes = 1,
        .formats = {MTLPixelFormatGBGR422}
    },
#endif
    {
        .cvpixfmt = kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange,
        .planes = 2,
        .formats = {MTLPixelFormatR8Unorm,MTLPixelFormatRG8Unorm}
    },
    {
        .cvpixfmt = kCVPixelFormatType_444YpCbCr8BiPlanarFullRange,
        .planes = 2,
        .formats = {MTLPixelFormatR8Unorm,MTLPixelFormatRG8Unorm}
    },
    {
        .cvpixfmt = kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange,
        .planes = 2,
        .formats = {MTLPixelFormatR8Unorm,MTLPixelFormatRG8Unorm}
    },
    {
        .cvpixfmt = kCVPixelFormatType_422YpCbCr8BiPlanarFullRange,
        .planes = 2,
        .formats = {MTLPixelFormatR8Unorm,MTLPixelFormatRG8Unorm}
    },
    {
        .cvpixfmt = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        .planes = 2,
        .formats = {MTLPixelFormatR8Unorm,MTLPixelFormatRG8Unorm}
    },
    {
        .cvpixfmt = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        .planes = 2,
        .formats = {MTLPixelFormatR8Unorm,MTLPixelFormatRG8Unorm}
    },
    {
        .cvpixfmt = kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange,
        .planes = 2,
        .formats = {MTLPixelFormatR16Unorm,MTLPixelFormatRG16Unorm}
    },
    {
        .cvpixfmt = kCVPixelFormatType_444YpCbCr10BiPlanarFullRange,
        .planes = 2,
        .formats = {MTLPixelFormatR16Unorm,MTLPixelFormatRG16Unorm}
    },
    {
        .cvpixfmt = kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
        .planes = 2,
        .formats = {MTLPixelFormatR16Unorm,MTLPixelFormatRG16Unorm}
    },
    {
        .cvpixfmt = kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
        .planes = 2,
        .formats = {MTLPixelFormatR16Unorm,MTLPixelFormatRG16Unorm}
    },
    {
        .cvpixfmt = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
        .planes = 2,
        .formats = {MTLPixelFormatR16Unorm,MTLPixelFormatRG16Unorm}
    },
    {
        .cvpixfmt = kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
        .planes = 2,
        .formats = {MTLPixelFormatR16Unorm,MTLPixelFormatRG16Unorm}
    },
    {
        .cvpixfmt = kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange,
        .planes = 2,
        .formats = {MTLPixelFormatR16Unorm,MTLPixelFormatRG16Unorm}
    },
    {
        .cvpixfmt = kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange,
        .planes = 2,
        .formats = {MTLPixelFormatR16Unorm,MTLPixelFormatRG16Unorm}
    },
    {
        .cvpixfmt = kCVPixelFormatType_420YpCbCr8Planar,
        .planes = 3,
        .formats = {MTLPixelFormatR8Unorm,MTLPixelFormatR8Unorm,MTLPixelFormatR8Unorm}
    },
    {
        .cvpixfmt = kCVPixelFormatType_420YpCbCr8PlanarFullRange,
        .planes = 3,
        .formats = {MTLPixelFormatR8Unorm,MTLPixelFormatR8Unorm,MTLPixelFormatR8Unorm}
    }
};

#define MP_ARRAY_SIZE(s) (sizeof(s) / sizeof((s)[0]))

mp_format * mp_get_metal_format(uint32_t cvpixfmt)
{
    for (int i = 0; i < MP_ARRAY_SIZE(mp_formats); i++) {
        if (mp_formats[i].cvpixfmt == cvpixfmt)
            return &mp_formats[i];
    }
    return NULL;
}

FSConvertMatrix ijk_metal_create_color_matrix(FSYUV2RGBColorMatrixType matrixType, int fullRange, uint32_t pixelFormat)
{
    FSConvertMatrix matrix = {0};
    float kr, kb;
    switch (matrixType) {
        case FSYUV2RGBColorMatrixBT601:  kr = 0.299f;  kb = 0.114f;  break;
        case FSYUV2RGBColorMatrixBT709:  kr = 0.2126f; kb = 0.0722f; break;
        case FSYUV2RGBColorMatrixBT2020: kr = 0.2627f; kb = 0.0593f; break;
        case FSYUV2RGBColorMatrixNone:   return matrix;
    }

    const mp_format *format = mp_get_metal_format(pixelFormat);
    const bool wide = format && (format->formats[0] == MTLPixelFormatR16Unorm ||
                                 format->formats[0] == MTLPixelFormatRGBA16Unorm);
    // 10-bit bi-planar samples occupy the high bits of a 16-bit UNORM texture.
    const float textureMax = wide ? 65535.0f : 255.0f;
    const float codeStep = wide ? 256.0f : 1.0f;
    const float fullRangeMax = wide ? 1023.0f * 64.0f : 255.0f;
    const float yScale = textureMax / (fullRange ? fullRangeMax : 219.0f * codeStep);
    const float cScale = textureMax / (fullRange ? fullRangeMax : 224.0f * codeStep);
    const float kg = 1.0f - kr - kb;
    const float cb = 2.0f * (1.0f - kb) * cScale;
    const float cr = 2.0f * (1.0f - kr) * cScale;
    const float yOffset = fullRange ? 0.0f : -16.0f * codeStep / textureMax;
    const float cOffset = -128.0f * codeStep / textureMax;

    matrix.colorMatrix = (matrix_float3x3){
        (simd_float3){yScale, yScale, yScale},
        (simd_float3){0.0f, -kb / kg * cb, cb},
        (simd_float3){cr, -kr / kg * cr, 0.0f},
    };
    matrix.offset = (vector_float3){yOffset, cOffset, cOffset};
    return matrix;
}
