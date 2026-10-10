/*
 * Copyright (c) 2019 debugly <qianlongxu@gmail.com>
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "UIImage+FSImageEffects.h"
#import <Accelerate/Accelerate.h>
#import <float.h>

@implementation UIImage (FSImageEffects)

- (UIImage *)fs_applyDarkEffect {
    UIColor *tintColor = [UIColor colorWithWhite:0.11 alpha:0.63];
    return [self fs_applyBlurWithRadius:25
                              tintColor:tintColor
                  saturationDeltaFactor:0.9];
}

- (UIImage *)fs_applyBlurWithRadius:(CGFloat)blurRadius
                          tintColor:(UIColor *)tintColor
              saturationDeltaFactor:(CGFloat)saturationDeltaFactor {
    if (self.size.width < 1 || self.size.height < 1) {
        return nil;
    }
    if (!self.CGImage) {
        return nil;
    }

    BOOL hasBlur = blurRadius > __FLT_EPSILON__;
    BOOL hasSaturationChange = fabs(saturationDeltaFactor - 1.) > __FLT_EPSILON__;

    if (!hasBlur && !hasSaturationChange) {
        return self;
    }

    CGImageRef inputCGImage = self.CGImage;
    CGFloat inputImageScale = self.scale;
    CGBitmapInfo inputImageBitmapInfo = CGImageGetBitmapInfo(inputCGImage);
    CGImageAlphaInfo inputImageAlphaInfo = (inputImageBitmapInfo & kCGBitmapAlphaInfoMask);

    CGSize outputImageSizeInPoints = self.size;
    CGRect outputImageRectInPoints = { CGPointZero, outputImageSizeInPoints };

    BOOL useOpaqueContext;
    if (inputImageAlphaInfo == kCGImageAlphaNone ||
        inputImageAlphaInfo == kCGImageAlphaNoneSkipLast ||
        inputImageAlphaInfo == kCGImageAlphaNoneSkipFirst) {
        useOpaqueContext = YES;
    } else {
        useOpaqueContext = NO;
    }

    UIGraphicsBeginImageContextWithOptions(outputImageRectInPoints.size, useOpaqueContext, inputImageScale);
    CGContextRef outputContext = UIGraphicsGetCurrentContext();
    CGContextScaleCTM(outputContext, 1.0, -1.0);
    CGContextTranslateCTM(outputContext, 0, -outputImageRectInPoints.size.height);

    vImage_Buffer effectInBuffer;
    vImage_Buffer scratchBuffer1;
    vImage_Buffer *inputBuffer;
    vImage_Buffer *outputBuffer;

    // BGRA layout, which is what the box convolve and matrix calls want here.
    vImage_CGImageFormat format = {
        .bitsPerComponent = 8,
        .bitsPerPixel = 32,
        .colorSpace = NULL,
        .bitmapInfo = kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little,
        .version = 0,
        .decode = NULL,
        .renderingIntent = kCGRenderingIntentDefault
    };

    vImage_Error error = vImageBuffer_InitWithCGImage(&effectInBuffer, &format, NULL,
                                                     self.CGImage, kvImageNoFlags);
    if (error != kvImageNoError) {
        UIGraphicsEndImageContext();
        return nil;
    }

    vImageBuffer_Init(&scratchBuffer1, effectInBuffer.height, effectInBuffer.width,
                      format.bitsPerPixel, kvImageNoFlags);
    inputBuffer = &effectInBuffer;
    outputBuffer = &scratchBuffer1;

    if (hasBlur) {
        // Three box blurs of width d approximate a Gaussian of standard
        // deviation `blurRadius` to within ~3%, per the SVG filter spec:
        // d = floor(s * 3*sqrt(2*pi)/4 + 0.5), forced odd.
        CGFloat inputRadius = blurRadius * inputImageScale;
        if (inputRadius - 2. < __FLT_EPSILON__) {
            inputRadius = 2.;
        }
        uint32_t radius = floor((inputRadius * 3. * sqrt(2 * M_PI) / 4 + 0.5) / 2);
        radius |= 1; // must be odd for the three-pass method

        NSInteger tempBufferSize = vImageBoxConvolve_ARGB8888(inputBuffer, outputBuffer,
                                                             NULL, 0, 0, radius, radius,
                                                             NULL, kvImageGetTempBufferSize | kvImageEdgeExtend);
        void *tempBuffer = malloc(tempBufferSize);

        vImageBoxConvolve_ARGB8888(inputBuffer, outputBuffer, tempBuffer, 0, 0, radius, radius,
                                   NULL, kvImageEdgeExtend);
        vImageBoxConvolve_ARGB8888(outputBuffer, inputBuffer, tempBuffer, 0, 0, radius, radius,
                                   NULL, kvImageEdgeExtend);
        vImageBoxConvolve_ARGB8888(inputBuffer, outputBuffer, tempBuffer, 0, 0, radius, radius,
                                   NULL, kvImageEdgeExtend);

        free(tempBuffer);

        vImage_Buffer *temp = inputBuffer;
        inputBuffer = outputBuffer;
        outputBuffer = temp;
    }

    if (hasSaturationChange) {
        // Saturation matrix from the W3C Filter Effects spec:
        // https://dvcs.w3.org/hg/FXTF/raw-file/default/filters/index.html#grayscaleEquivalent
        CGFloat s = saturationDeltaFactor;
        CGFloat floatingPointSaturationMatrix[] = {
            0.0722 + 0.9278 * s,  0.0722 - 0.0722 * s,  0.0722 - 0.0722 * s,  0,
            0.7152 - 0.7152 * s,  0.7152 + 0.2848 * s,  0.7152 - 0.7152 * s,  0,
            0.2126 - 0.2126 * s,  0.2126 - 0.2126 * s,  0.2126 + 0.7873 * s,  0,
            0,                    0,                    0,                    1,
        };
        const int32_t divisor = 256;
        NSUInteger matrixSize = sizeof(floatingPointSaturationMatrix) / sizeof(floatingPointSaturationMatrix[0]);
        int16_t saturationMatrix[matrixSize];
        for (NSUInteger i = 0; i < matrixSize; ++i) {
            saturationMatrix[i] = (int16_t)roundf(floatingPointSaturationMatrix[i] * divisor);
        }
        vImageMatrixMultiply_ARGB8888(inputBuffer, outputBuffer, saturationMatrix,
                                      divisor, NULL, NULL, kvImageNoFlags);

        vImage_Buffer *temp = inputBuffer;
        inputBuffer = outputBuffer;
        outputBuffer = temp;
    }

    CGImageRef effectCGImage = vImageCreateCGImageFromBuffer(inputBuffer, &format, NULL,
                                                             NULL, kvImageNoFlags, NULL);
    if (effectCGImage == NULL) {
        free(inputBuffer->data);
        free(outputBuffer->data);
        UIGraphicsEndImageContext();
        return nil;
    }

    CGContextDrawImage(outputContext, outputImageRectInPoints, effectCGImage);

    CGImageRelease(effectCGImage);
    free(inputBuffer->data);
    free(outputBuffer->data);

    if (tintColor) {
        CGContextSaveGState(outputContext);
        CGContextSetFillColorWithColor(outputContext, tintColor.CGColor);
        CGContextFillRect(outputContext, outputImageRectInPoints);
        CGContextRestoreGState(outputContext);
    }

    UIImage *outputImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    return outputImage;
}

@end