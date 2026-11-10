// Xipper's C interface to preflate (not part of preflate), see include/xpf.h.
#include "xpf.h"

#include <cstdlib>
#include <cstring>
#include <new>
#include <vector>

#include "preflate_decoder.h"
#include "preflate_reencoder.h"
#include "support/stream.h"

namespace {

// Reads straight from the caller's buffer.
class SpanInput : public InputStream {
public:
  SpanInput(const uint8_t *p, size_t n) : p_(p), n_(n) {}
  bool eof() const override { return pos_ >= n_; }
  size_t read(unsigned char *buffer, const size_t size) override {
    size_t k = std::min(size, n_ - pos_);
    std::memcpy(buffer, p_ + pos_, k);
    pos_ += k;
    return k;
  }
private:
  const uint8_t *p_;
  size_t n_, pos_ = 0;
};

// Collects the output, refusing more than `limit` bytes (a write that is cut short stops preflate).
class BoundedOutput : public OutputStream {
public:
  explicit BoundedOutput(size_t limit) : limit_(limit) {}
  size_t write(const unsigned char *buffer, const size_t size) override {
    if (size > limit_ - data.size()) { overflow = true; return 0; }
    data.insert(data.end(), buffer, buffer + size);
    return size;
  }
  std::vector<uint8_t> data;
  bool overflow = false;
private:
  size_t limit_;
};

bool give(const std::vector<uint8_t> &v, xpf_buffer *out) {
  out->size = v.size();
  out->data = static_cast<uint8_t *>(std::malloc(v.empty() ? 1 : v.size()));
  if (!out->data) return false;
  if (!v.empty()) std::memcpy(out->data, v.data(), v.size());
  return true;
}

}  // namespace

extern "C" int xpf_decode(const uint8_t *in, size_t n, size_t max_unpacked, xpf_buffer *unpacked, xpf_buffer *diff, size_t *consumed) {
  try {
    SpanInput input(in, n);
    BoundedOutput out(max_unpacked);
    std::vector<unsigned char> d;
    uint64_t size = 0;
    // Meta-blocks of 1 MiB of output: preflate codes them on its thread pool, in each direction.
    if (!preflate_decode(out, d, size, input, [] {}, 0, 1 << 20) || out.overflow || size == 0 || size > n) return 0;
    if (!give(out.data, unpacked)) return 0;
    if (!give(d, diff)) { xpf_free(unpacked); return 0; }
    *consumed = static_cast<size_t>(size);
    return 1;
  } catch (...) {
    return 0;
  }
}

extern "C" int xpf_reencode(const uint8_t *diff, size_t diff_size, const uint8_t *unpacked, size_t unpacked_size, xpf_buffer *out) {
  try {
    std::vector<unsigned char> d(diff, diff + diff_size), u(unpacked, unpacked + unpacked_size), raw;
    if (!preflate_reencode(raw, d, u)) return 0;
    return give(raw, out) ? 1 : 0;
  } catch (...) {
    return 0;
  }
}

extern "C" void xpf_free(xpf_buffer *b) {
  if (b && b->data) std::free(b->data);
  if (b) { b->data = nullptr; b->size = 0; }
}
