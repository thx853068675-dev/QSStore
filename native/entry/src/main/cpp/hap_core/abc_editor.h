#pragma once

#include <algorithm>
#include <cstring>
#include <map>
#include <set>
#include <stdexcept>
#include <string>
#include <vector>
#include <zlib.h>

namespace qingqi::hap {
// Dynamic Ark ABC uses absolute string IDs, not byte offsets in instructions.
// Append strings and redirect only typed references, preserving instruction,
// method, exception and debug offsets. Never replace arbitrary binary bytes.
// Format: OpenHarmony arkcompiler_runtime_core/libpandafile/{file.h,
// file-inl.h,literal_data_accessor-inl.h}. Unsupported references fail closed.
class AbcBundleEditor {
 public:
  explicit AbcBundleEditor(const std::vector<uint8_t>& bytes) : bytes_(bytes) {}
  std::vector<uint8_t> Rename(const std::string& previous, const std::string& next) {
    for (const auto* name : {&previous, &next})
      if (name->size() < 7 || name->size() > 128 || name->find_first_not_of("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.") != std::string::npos)
        throw std::runtime_error("包名格式无效");
    if (bytes_.size() < 60 || bytes_.size() > 64 * 1024 * 1024 ||
        std::memcmp(bytes_.data(), "PANDA\0\0\0", 8) || U32(16) != bytes_.size() ||
        bytes_[12] < 9 || bytes_[12] > 24 || bytes_[15] != 0 ||
        U32(8) != adler32(1, bytes_.data() + 12, bytes_.size() - 12))
      throw std::runtime_error("不支持或已损坏的 Ark 字节码，无法安全修改包名");
    const auto classes = Table(U32(32), U32(28));
    for (auto position : classes) {
      const auto name = String(U32(position));
      if (name.find(previous) != std::string::npos)
        throw std::runtime_error("该安装包的字节码模块名绑定原包名，暂不支持修改；名称和图标仍可编辑");
    }
    const auto count = U32(52), section = U32(56);
    if (!count || count > 65536 || section > bytes_.size() || count > (bytes_.size() - section) / 40)
      throw std::runtime_error("Ark 字节码索引无效");
    std::set<uint32_t> roots;
    std::vector<uint32_t> index_ends;
    for (uint32_t i = 0; i < count; ++i) {
      const auto header = section + i * 40;
      if (U32(header) > U32(header + 4) || U32(header + 4) > bytes_.size())
        throw std::runtime_error("Ark 字节码索引范围无效");
      if (U32(header + 4) == bytes_.size()) index_ends.push_back(header + 4);
      for (auto position : Table(U32(header + 20), U32(header + 16))) {
        refs_[position] = U32(position);
        roots.insert(U32(position));
      }
    }
    // Older dynamic files also keep literal roots in the header.
    if (U32(44) != UINT32_MAX && U32(48) != UINT32_MAX)
      for (auto position : Table(U32(48), U32(44))) roots.insert(U32(position));
    for (auto root : roots) Literal(root);
    std::map<uint32_t, std::string> targets;
    for (const auto& ref : refs_) {
      std::string text;
      try { text = String(ref.second); } catch (const std::exception&) { continue; }
      if (text == previous || text.compare(0, previous.size() + 1, previous + "/") == 0 ||
          text.compare(0, previous.size() + 1, previous + ".") == 0)
        targets[ref.second] = next + text.substr(previous.size());
      for (const std::string prefix : {"@bundle:", "@app:"}) {
        const auto old = prefix + previous + "/";
        if (text.compare(0, old.size(), old) == 0)
          targets[ref.second] = prefix + next + text.substr(prefix.size() + previous.size());
      }
    }
    // Literal-only strings may be absent from the instruction index. Detect
    // self strings we could not classify, rather than silently leaving them.
    for (size_t at = 0; at + previous.size() <= bytes_.size(); ++at) {
      if (std::memcmp(bytes_.data() + at, previous.data(), previous.size())) continue;
      for (size_t back = 1; back <= 5 && back <= at; ++back) {
        const auto id = uint32_t(at - back); std::string text;
        try { text = String(id); } catch (const std::exception&) { continue; }
        if ((text == previous || text.compare(0, previous.size() + 1, previous + "/") == 0 ||
             text.compare(0, previous.size() + 1, previous + ".") == 0) && !targets.count(id))
          throw std::runtime_error("包名存在暂不支持的字节码字符串，无法安全修改；名称和图标仍可编辑");
      }
    }
    // An unclassified pointer must not be rewritten as if it were a string.
    // This also rejects coincidental integer values instead of corrupting code.
    for (uint32_t at = 0; at + 4 <= bytes_.size(); ++at) {
      const auto id = U32(at);
      if (targets.count(id) && (!refs_.count(at) || refs_.at(at) != id))
        throw std::runtime_error("包名存在暂不支持的字节码引用，无法安全修改；名称和图标仍可编辑");
    }
    auto output = bytes_;
    std::map<uint32_t, uint32_t> moved;
    for (const auto& target : targets) {
      moved[target.first] = output.size();
      uint32_t length = (target.second.size() << 1) | 1;
      do { output.push_back(uint8_t(length & 127) | (length > 127 ? 128 : 0)); length >>= 7; } while (length);
      output.insert(output.end(), target.second.begin(), target.second.end()); output.push_back(0);
    }
    if (moved.empty()) return output;
    for (const auto& ref : refs_) if (moved.count(ref.second)) Put(output, ref.first, moved.at(ref.second));
    Put(output, 16, output.size());
    for (auto at : index_ends) Put(output, at, output.size());
    Put(output, 8, adler32(1, output.data() + 12, output.size() - 12));
    return output;
  }
 private:
  const std::vector<uint8_t>& bytes_;
  std::map<uint32_t, uint32_t> refs_;
  std::set<uint32_t> visited_;
  uint32_t U32(uint32_t at) const {
    if (at > bytes_.size() || bytes_.size() - at < 4) throw std::runtime_error("Ark 字节码越界");
    return uint32_t(bytes_[at]) | uint32_t(bytes_[at + 1]) << 8 | uint32_t(bytes_[at + 2]) << 16 | uint32_t(bytes_[at + 3]) << 24;
  }
  static void Put(std::vector<uint8_t>& out, uint32_t at, uint32_t value) {
    for (unsigned i = 0; i < 4; ++i) out.at(at + i) = uint8_t(value >> (i * 8));
  }
  std::vector<uint32_t> Table(uint32_t start, uint32_t count) const {
    if (start > bytes_.size() || count > (bytes_.size() - start) / 4 || count > 1000000)
      throw std::runtime_error("Ark 字节码表越界");
    std::vector<uint32_t> positions; positions.reserve(count);
    for (uint32_t i = 0; i < count; ++i) positions.push_back(start + 4 * i);
    return positions;
  }
  std::string String(uint32_t id) const {
    uint32_t at = id, length = 0; bool ended = false;
    for (unsigned shift = 0; shift < 35; shift += 7) {
      if (at >= bytes_.size()) throw std::runtime_error("Ark 字符串越界");
      const auto b = bytes_[at++];
      if (shift == 28 && (b & 0xf0)) throw std::runtime_error("Ark 字符串长度无效");
      length |= uint32_t(b & 127) << shift;
      if (!(b & 128)) { ended = true; break; }
    }
    if (!ended || (length >> 1) > 1000000) throw std::runtime_error("Ark 字符串长度无效");
    uint32_t end = at;
    while (end < bytes_.size() && bytes_[end] && end - at <= 3000000) ++end;
    uint32_t units = 0;
    for (uint32_t p = at; p < end; ++p) if ((bytes_[p] & 0xc0) != 0x80) units += bytes_[p] >= 0xf0 ? 2 : 1;
    if (end >= bytes_.size() || end - at > 3000000 || units != (length >> 1) || ((length & 1) && end - at != units))
      throw std::runtime_error("Ark 字符串长度不匹配");
    return std::string(bytes_.begin() + at, bytes_.begin() + end);
  }
  void Literal(uint32_t id, unsigned depth = 0) {
    if (depth > 64) return;
    if (!visited_.insert(id).second) return;
    std::map<uint32_t, uint32_t> found; std::vector<uint32_t> children;
    try {
      const auto count = U32(id); uint32_t at = id + 4;
      if ((count & 1) || count > 1000000 || count > bytes_.size() - at) return;
      for (uint32_t i = 0; i < count; i += 2) {
        if (at >= bytes_.size()) return;
        const auto tag = bytes_[at++]; uint32_t size = 0;
        switch (tag) {
          case 0: case 1: case 8: case 25: case 255: size = 1; break;
          case 9: size = 2; break;
          case 4: size = 8; break;
          case 2: case 3: case 5: case 6: case 7: case 22: case 23: case 24: case 26: case 27: case 28: size = 4; break;
          default: return;  // Static arrays and unknown formats are not guessed.
        }
        if (size > bytes_.size() - at) return;
        if (tag == 5) { const auto target = U32(at); String(target); found[at] = target; }
        if (tag == 24) children.push_back(U32(at));
        at += size;
      }
    } catch (const std::exception&) { return; }
    refs_.insert(found.begin(), found.end());
    for (auto child : children) Literal(child, depth + 1);
  }
};
}  // namespace qingqi::hap
