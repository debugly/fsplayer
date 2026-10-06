// HDR 相关函数与常量：逐字移植自 iOS ijkmedia/ijksdl/metal/FSMetalShaders.metal
// 供 yuv.frag（软解）与 external.frag（MediaCodec 零拷贝）共用。
// 注意：这里约定传进来的 rgb_2020 是 BT.2020 的**非线性**电信号（未做 EOTF）。

// 传输函数，取值和 iOS 的 FSColorTransferFunc 一致
#define FS_TRANSFER_LINEAR 0
#define FS_TRANSFER_PQ     1
#define FS_TRANSFER_HLG    2

// BT.2020 -> BT.709（线性光）。iOS 的 RGB2020_TO_XYZ * XYZ_TO_RGB709 展开后的结果，
// 白点保持不变（(1,1,1) -> (1.0001,1.0001,1.0000)）。
// 这里按 GLSL 的列主序写，等价于数学上的行主序矩阵。
const mat3 RGB2020_TO_RGB709 = mat3(
    1.660642, -0.124555, -0.018174,
   -0.587719,  1.132951, -0.100571,
   -0.072778, -0.008313,  1.118771);

// ---- ARIB STD-B67 (HLG) ----
float arib_b67_inverse_oetf(float x)
{
    const float A = 0.17883277;
    const float B = 0.28466892;
    const float C = 0.55991073;
    x = max(x, 0.0);
    if (x <= 0.5) {
        return (x * x) * (1.0 / 3.0);
    }
    return (exp((x - C) / A) + B) / 12.0;
}

float ootf_1_2(float x)
{
    return x < 0.0 ? x : pow(x, 1.2);
}

vec3 arib_b67_eotf_vec(vec3 v)
{
    return vec3(ootf_1_2(arib_b67_inverse_oetf(v.r)),
                ootf_1_2(arib_b67_inverse_oetf(v.g)),
                ootf_1_2(arib_b67_inverse_oetf(v.b)));
}

// ---- SMPTE ST 2084 (PQ) ----
float st_2084_eotf(float x)
{
    const float M1 = 0.1593017578125;
    const float M2 = 78.84375;
    const float C1 = 0.8359375;
    const float C2 = 18.8515625;
    const float C3 = 18.6875;
    float xpow = pow(x, 1.0 / M2);
    float num = max(xpow - C1, 0.0);
    float den = max(C2 - C3 * xpow, 1e-30);
    return pow(num / den, 1.0 / M1);
}

vec3 st_2084_eotf_vec(vec3 v)
{
    return vec3(st_2084_eotf(v.r), st_2084_eotf(v.g), st_2084_eotf(v.b));
}

// ---- BT.1886（HDR 内容里标成线性/未知传输时用）----
float rec_1886_eotf(float x)
{
    return x < 0.0 ? 0.0 : pow(x, 2.2);
}

vec3 rec_1886_eotf_vec(vec3 v)
{
    return vec3(rec_1886_eotf(v.r), rec_1886_eotf(v.g), rec_1886_eotf(v.b));
}

// ---- 色调映射 ----
float tonemap_ACES(float x)
{
    const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
    return (x * (a * x + b)) / (x * (c * x + d) + e);
}

// Hable 2010 "Filmic Tonemapping Operators"，iOS 用的是这一条
float tonemap_Uncharted2(float x)
{
    const float A = 0.15, B = 0.50, C = 0.10, D = 0.20, E = 0.02, F = 0.30;
    return ((x * (A * x + C * B) + D * E) / (x * (A * x + B) + D * F)) - E / F;
}

// 三通道整体缩放（按最亮通道），保持色相
vec3 tonemap(vec3 x)
{
    float sig = max(max(max(x.r, x.g), x.b), 1e-6);
    float sig_orig = sig;
    const float peak = 20.0;
    sig = tonemap_Uncharted2(sig) / tonemap_Uncharted2(peak);
    return x * sig / sig_orig;
}

// 直显模式（HDR 屏）：只做 EOTF + 色域转换，不压缩动态范围，
// 归一化到 203 nits 为 1.0，>1.0 的部分交给 EDR/HDR 层。
vec3 hdr_direct(vec3 rgb_2020, int tf)
{
    vec3 linear;
    if (tf == FS_TRANSFER_PQ) {
        linear = st_2084_eotf_vec(rgb_2020) * (10000.0 / 203.0);
    } else if (tf == FS_TRANSFER_HLG) {
        linear = arib_b67_eotf_vec(rgb_2020) * (1000.0 / 203.0);
    } else {
        linear = rec_1886_eotf_vec(rgb_2020);
    }
    return RGB2020_TO_RGB709 * linear;
}

// SDR 屏：EOTF -> 色域转到 BT.709 -> 色调映射（peak_luminance = 50，和 iOS 一致）
vec3 hdr2sdr(vec3 rgb_2020, int tf)
{
    vec3 linear;
    const float peak_luminance = 50.0;
    if (tf == FS_TRANSFER_PQ) {
        linear = (10000.0 / peak_luminance) * st_2084_eotf_vec(rgb_2020);
    } else if (tf == FS_TRANSFER_HLG) {
        linear = (1000.0 / peak_luminance) * arib_b67_eotf_vec(rgb_2020);
    } else {
        linear = rec_1886_eotf_vec(rgb_2020);
    }
    return tonemap(RGB2020_TO_RGB709 * linear);
}
