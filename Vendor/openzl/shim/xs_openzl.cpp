#include "xs_openzl.h"

#include "custom_parsers/csv/csv_profile.h"
#include "openzl/zl_compress.h"
#include "openzl/zl_compressor.h"
#include "openzl/zl_decompress.h"

extern "C" size_t xs_ozl_bound(size_t n) { return ZL_compressBound(n); }

extern "C" size_t xs_ozl_csv_compress(const void *src, size_t n, void *dst, size_t cap, char separator, int header, int level)
{
    if (n == 0) return 0;
    ZL_Compressor *compressor = ZL_Compressor_create();
    ZL_CCtx *cctx = ZL_CCtx_create();
    size_t out = 0;
    if (compressor && cctx) {
        ZL_GraphID g = openzl::custom_parsers::ZL_createGraph_genericCSVCompressorWithOptions(
            compressor, openzl::custom_parsers::kDefaultChunkSize, header != 0, separator, false);
        bool ok = !ZL_isError(ZL_Compressor_selectStartingGraphID(compressor, g))
               && !ZL_isError(ZL_CCtx_setParameter(cctx, ZL_CParam_formatVersion, XS_OZL_FORMAT_VERSION))
               && !ZL_isError(ZL_CCtx_setParameter(cctx, ZL_CParam_compressionLevel, level))
               && !ZL_isError(ZL_CCtx_setParameter(cctx, ZL_CParam_contentChecksum, ZL_TernaryParam_enable))
               && !ZL_isError(ZL_CCtx_refCompressor(cctx, compressor));
        if (ok) {
            ZL_Report r = ZL_CCtx_compress(cctx, dst, cap, src, n);
            if (!ZL_isError(r)) out = ZL_validResult(r);
        }
    }
    ZL_CCtx_free(cctx);
    ZL_Compressor_free(compressor);
    return out;
}

extern "C" size_t xs_ozl_decompressed_size(const void *src, size_t n)
{
    ZL_Report r = ZL_getDecompressedSize(src, n);
    return ZL_isError(r) ? (size_t)-1 : ZL_validResult(r);
}

extern "C" size_t xs_ozl_decompress(void *dst, size_t cap, const void *src, size_t n)
{
    ZL_DCtx *dctx = ZL_DCtx_create();
    if (!dctx) return (size_t)-1;
    ZL_DCtx_setParameter(dctx, ZL_DParam_checkContentChecksum, ZL_TernaryParam_enable);
    ZL_Report r = ZL_DCtx_decompress(dctx, dst, cap, src, n);
    ZL_DCtx_free(dctx);
    return ZL_isError(r) ? (size_t)-1 : ZL_validResult(r);
}
