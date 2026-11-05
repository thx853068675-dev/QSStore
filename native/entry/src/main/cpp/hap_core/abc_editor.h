#pragma once

#include <algorithm>
#include <cstring>
#include <iterator>
#include <map>
#include <set>
#include <stdexcept>
#include <string>
#include <vector>
#include <zlib.h>

namespace qingqi::hap {
// Dynamic Ark ABC uses absolute string IDs, not byte offsets in instructions.
// Append records/strings and redirect only typed references, preserving code
// and exception offsets. Never replace arbitrary binary bytes.
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
      const auto id = U32(position);
      const auto name = String(id);
      if (name.compare(0, previous.size() + 2, "L" + previous + "/") == 0) {
        bound_classes_.insert(id);
        const auto start = previous.size() + 2, end = name.find_first_of("/@", start);
        module_roots_.insert(name.substr(start, end - start));
      } else if (name.find(previous) != std::string::npos)
        throw std::runtime_error("该安装包的字节码模块名绑定原包名，暂不支持修改；名称和图标仍可编辑");
      refs_[position] = id;
    }
    Metadata(classes);
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
      for (const auto offset : {8U, 24U}) {
        const auto size = U32(header + offset), start = U32(header + offset + 4);
        if (!size || (size == UINT32_MAX && start == UINT32_MAX)) continue;
        for (auto position : Table(start, size)) refs_[position] = U32(position);
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
      const auto changed = SelfText(text, previous, next);
      if (changed != text) targets[ref.second] = changed;
    }
    for (const auto& ref : leb_strings_) {
      const auto text = String(ref.second.first), changed = SelfText(text, previous, next);
      if (changed != text) targets[ref.second.first] = changed;
    }
    // Older compilers leave unused qualified method names in the string pool.
    // Their text alone is not an unsupported reference. All LEB string fields
    // are parsed above; retain unused strings, but reject unclassified IDs
    // actually present in an absolute-reference field below.
    std::set<uint32_t> unclassified;
    for (size_t at = 0; at + previous.size() <= bytes_.size(); ++at) {
      if (std::memcmp(bytes_.data() + at, previous.data(), previous.size())) continue;
      for (size_t back = 1; back <= 5 && back <= at; ++back) {
        const auto id = uint32_t(at - back); std::string text;
        try { text = String(id); } catch (const std::exception&) { continue; }
        if (SelfText(text, previous, next) != text && !targets.count(id))
          unclassified.insert(id);
      }
    }
    // Keep unknown references fail-closed, but do not mistake annotation
    // scalars or bytes spanning two typed annotation fields for string IDs.
    for (uint32_t at = 0; at + 4 <= bytes_.size(); ++at) {
      const auto id = U32(at);
      const bool scalar = InAnnotation(at) || InDebug(at) || InCode(at);
      if (unclassified.count(id) && !scalar)
        throw std::runtime_error("包名存在暂不支持的字节码字符串引用，无法安全修改");
      if (targets.count(id) && !bound_classes_.count(id) && (!refs_.count(at) || refs_.at(at) != id) && !scalar)
        throw std::runtime_error("包名存在暂不支持的字节码引用，无法安全修改；名称和图标仍可编辑");
    }
    auto output = bytes_;
    std::map<uint32_t, uint32_t> moved;
    // A class descriptor is inline before its fields/methods. Copy the entire
    // typed class record and redirect member IDs; appending just its name would
    // leave the VM reading a string as class metadata. Code bodies stay put.
    if (!bound_classes_.empty()) {
      if (count != 1 || index_ends.size() != 1) throw std::runtime_error("暂不支持此多区域 Ark 模块重定位");
      for (auto id : bound_classes_) {
        const auto found = records_.find(id);
        if (found == records_.end()) throw std::runtime_error("不支持外部 Ark 模块重定位");
        const auto& record = found->second;
        moved[id] = output.size(); AppendString(output, targets.at(id));
        const auto body = uint32_t(output.size());
        copied_bodies_[record.body] = {record.end, body};
        output.insert(output.end(), bytes_.begin() + record.body, bytes_.begin() + record.end);
        for (auto member : record.members) moved[member] = body + member - record.body;
      }
    }
    for (const auto& target : targets) {
      if (bound_classes_.count(target.first)) continue;
      moved[target.first] = output.size();
      AppendString(output, target.second);
    }
    if (moved.empty()) return output;
    for (const auto& item : debug_records_) {
      const auto& debug = item.second;
      bool changed = false;
      for (auto ref = leb_strings_.lower_bound(debug.start); ref != leb_strings_.end() && ref->first < debug.end; ++ref)
        if (moved.count(ref->second.first)) { changed = true; break; }
      if (!changed) continue;
      const auto prefix = PatchLebRange(debug.start, debug.pool_size, moved);
      const auto pool = PatchLebRange(debug.pool_start, debug.pool_end, moved);
      moved[debug.start] = output.size();
      output.insert(output.end(), prefix.begin(), prefix.end()); AppendLeb(output, pool.size());
      output.insert(output.end(), pool.begin(), pool.end());
      output.insert(output.end(), bytes_.begin() + debug.pool_end, bytes_.begin() + debug.end);
    }
    for (const auto& ref : refs_) if (moved.count(ref.second)) Put(output, CopyPosition(ref.first), moved.at(ref.second));
    if (!bound_classes_.empty()) {
      auto sorted = classes;
      std::sort(sorted.begin(), sorted.end(), [&](uint32_t a, uint32_t b) {
        const auto left = U32(a), right = U32(b);
        return (targets.count(left) ? targets.at(left) : String(left)) <
               (targets.count(right) ? targets.at(right) : String(right));
      });
      for (size_t i = 0; i < classes.size(); ++i) {
        const auto id = U32(sorted[i]); Put(output, classes[i], moved.count(id) ? moved.at(id) : id);
      }
    }
    if (output.size() > 64 * 1024 * 1024) throw std::runtime_error("编辑后的 Ark 字节码超限");
    Put(output, 16, output.size());
    for (auto at : index_ends) Put(output, at, output.size());
    Put(output, 8, adler32(1, output.data() + 12, output.size() - 12));
    return output;
  }
 private:
  const std::vector<uint8_t>& bytes_;
  std::map<uint32_t, uint32_t> refs_;
  std::set<uint32_t> visited_;
  std::set<uint32_t> annotations_;
  std::map<uint32_t, uint32_t> annotation_ranges_;
  std::map<uint32_t, uint32_t> code_ranges_;
  std::set<uint32_t> code_items_;
  std::set<uint32_t> module_items_;
  struct ClassRecord { uint32_t body = 0, end = 0; std::vector<uint32_t> members; };
  std::map<uint32_t, ClassRecord> records_;
  std::set<uint32_t> bound_classes_;
  std::set<std::string> module_roots_;
  std::map<uint32_t, std::pair<uint32_t, uint32_t>> copied_bodies_;
  struct DebugRecord { uint32_t start, pool_size, pool_start, pool_end, end; };
  std::map<uint32_t, DebugRecord> debug_records_;
  std::map<uint32_t, uint32_t> debug_program_ranges_;
  // debug strings use LEB IDs, not the 32-bit IDs used by ordinary tables.
  std::map<uint32_t, std::pair<uint32_t, uint32_t>> leb_strings_;
  static void AppendLeb(std::vector<uint8_t>& out, uint32_t value) {
    do { out.push_back(uint8_t(value & 127) | (value > 127 ? 128 : 0)); value >>= 7; } while (value);
  }
  std::vector<uint8_t> PatchLebRange(uint32_t start, uint32_t end, const std::map<uint32_t, uint32_t>& moved) const {
    std::vector<uint8_t> out; uint32_t at = start;
    for (auto ref = leb_strings_.lower_bound(start); ref != leb_strings_.end() && ref->first < end; ++ref) {
      if (ref->second.second > end) throw std::runtime_error("Ark 调试字符串越界");
      out.insert(out.end(), bytes_.begin() + at, bytes_.begin() + ref->first);
      const auto id = ref->second.first; AppendLeb(out, moved.count(id) ? moved.at(id) : id);
      at = ref->second.second;
    }
    out.insert(out.end(), bytes_.begin() + at, bytes_.begin() + end); return out;
  }
  void SkipLeb(uint32_t& at) const {
    for (unsigned i = 0; i < 5; ++i) if (!(Byte(at) & 128)) return;
    throw std::runtime_error("Ark 调试数字无效");
  }
  void LebString(uint32_t& at) {
    const auto start = at, id = Leb(at);
    if (id) { String(id); leb_strings_[start] = {id, at}; }
  }
  bool InDebug(uint32_t at) const {
    // A raw four-byte window can straddle consecutive DebugInfo/line programs.
    // Exempt it only when every byte belongs to a parsed numeric/LEB region.
    for (uint32_t byte = at; byte < at + 4; ++byte) {
      const auto next = debug_records_.upper_bound(byte);
      if (next != debug_records_.begin() && byte < std::prev(next)->second.end) continue;
      const auto program = debug_program_ranges_.upper_bound(byte);
      if (program != debug_program_ranges_.begin() && byte < std::prev(program)->second) continue;
      return false;
    }
    return true;
  }
  bool InCode(uint32_t at) const {
    const auto next = code_ranges_.upper_bound(at);
    return next != code_ranges_.begin() && uint64_t(at) + 4 <= std::prev(next)->second;
  }
  void Code(uint32_t id) {
    if (!id || !code_items_.insert(id).second) return;
    uint32_t at = id; Leb(at); Leb(at);
    const auto size = Leb(at), tries = Leb(at);
    if (tries > 65536) throw std::runtime_error("Ark 异常处理表超限");
    Skip(at, size);
    // Instruction IDs resolve through regional indexes (already in refs_).
    // Opcodes, immediates and overlapping operand bytes are not absolute IDs.
    // Try/catch entries contain only LEB PC offsets, lengths and regional
    // type indexes. Four overlapping bytes can resemble an absolute string ID.
    for (uint32_t i = 0; i < tries; ++i) {
      const auto pc = Leb(at), length = Leb(at), catches = Leb(at);
      if (pc > size || length > size - pc || catches > 65536)
        throw std::runtime_error("Ark 异常处理范围无效");
      for (uint32_t c = 0; c < catches; ++c) {
        Leb(at); const auto handler = Leb(at), count = Leb(at);
        if (handler > size || count > size - handler) throw std::runtime_error("Ark 异常处理入口无效");
      }
    }
    code_ranges_[id] = at;
  }
  void Debug(uint32_t id) {
    if (!id || debug_records_.count(id)) return;
    uint32_t at = id; Leb(at); const auto params = Leb(at);
    if (params > 65536) throw std::runtime_error("Ark 调试参数超限");
    for (uint32_t p = 0; p < params; ++p) LebString(at);
    DebugRecord debug{id, at, 0, 0, 0}; const auto size = Leb(at);
    debug.pool_start = at; Skip(at, size); debug.pool_end = at;
    const auto index = Leb(at); debug.end = at;
    if (index >= U32(36)) throw std::runtime_error("Ark 调试程序索引无效");
    uint32_t table_end = U32(40);
    if (U32(36) > 1000000) throw std::runtime_error("Ark 调试程序表超限");
    Skip(table_end, U32(36) * 4);
    uint32_t program = U32(U32(40) + index * 4), pool = debug.pool_start;
    const auto program_start = program;
    for (auto opcode = Byte(program); opcode; opcode = Byte(program)) {
      switch (opcode) {
        case 1: case 2: case 11: SkipLeb(pool); break;
        case 3: case 4:
          SkipLeb(program); LebString(pool); LebString(pool);
          if (opcode == 4) LebString(pool);
          break;
        case 5: case 6: SkipLeb(program); break;
        case 7: case 8: break;
        case 9: case 10: LebString(pool); break;
        default: break; // special opcodes encode PC/line increments inline
      }
      if (pool > debug.pool_end) throw std::runtime_error("Ark 调试常量池越界");
    }
    debug_program_ranges_[program_start] = program;
    debug_records_[id] = debug;
  }
  uint32_t CopyPosition(uint32_t at) const {
    const auto next = copied_bodies_.upper_bound(at);
    if (next == copied_bodies_.begin()) return at;
    const auto range = std::prev(next);
    return at < range->second.first ? range->second.second + at - range->first : at;
  }
  std::string SelfText(const std::string& text, const std::string& previous, const std::string& next) const {
    if (text.compare(0, previous.size() + 2, "L" + previous + "/") == 0)
      return "L" + next + text.substr(previous.size() + 1);
    if (text == previous || text.compare(0, previous.size() + 1, previous + ".") == 0)
      return next + text.substr(previous.size());
    if (text.compare(0, previous.size() + 1, previous + "/") == 0) {
      const auto start = previous.size() + 1, end = text.find_first_of("/@", start);
      // Flutter's Dart AOT and Ark side share custom channel names. These are
      // protocol identifiers, not module identities; preserve both ends.
      if (module_roots_.empty() || module_roots_.count(text.substr(start, end - start)))
        return next + text.substr(previous.size());
    }
    for (const std::string prefix : {"@bundle:", "@app:"})
      if (text.compare(0, prefix.size() + previous.size() + 1, prefix + previous + "/") == 0)
        return prefix + next + text.substr(prefix.size() + previous.size());
    return text;
  }
  static void AppendString(std::vector<uint8_t>& out, const std::string& text) {
    uint32_t units = 0; bool ascii = true;
    for (unsigned char byte : text) {
      if (byte >= 128) ascii = false;
      if ((byte & 0xc0) != 0x80) units += byte >= 0xf0 ? 2 : 1;
    }
    uint32_t length = (units << 1) | (ascii ? 1 : 0);
    do { out.push_back(uint8_t(length & 127) | (length > 127 ? 128 : 0)); length >>= 7; } while (length);
    out.insert(out.end(), text.begin(), text.end()); out.push_back(0);
  }
  uint8_t Byte(uint32_t& at) const {
    if (at >= bytes_.size()) throw std::runtime_error("Ark 字节码越界");
    return bytes_[at++];
  }
  void Skip(uint32_t& at, uint32_t size) const {
    if (at > bytes_.size() || size > bytes_.size() - at) throw std::runtime_error("Ark 字节码越界");
    at += size;
  }
  uint32_t Leb(uint32_t& at) const {
    uint32_t value = 0;
    for (unsigned shift = 0; shift < 35; shift += 7) {
      const auto b = Byte(at);
      if (shift == 28 && (b & 0xf0)) throw std::runtime_error("Ark 字节码长度无效");
      value |= uint32_t(b & 127) << shift;
      if (!(b & 128)) return value;
    }
    throw std::runtime_error("Ark 字节码长度无效");
  }
  void StringRef(uint32_t at) {
    const auto id = U32(at); String(id); refs_[at] = id;
  }
  void Module(uint32_t id) {
    if (!module_items_.insert(id).second) return;
    uint32_t at = id; Skip(at, 4); // literalnum; module data is NOT a tagged literal array
    const auto requests = U32(at); Skip(at, 4);
    if (requests > 65536) throw std::runtime_error("Ark 模块请求表超限");
    for (uint32_t i = 0; i < requests; ++i) { StringRef(at); Skip(at, 4); }
    // regular import, namespace import, local export, indirect export, star export
    for (unsigned group = 0; group < 5; ++group) {
      const auto entries = U32(at); Skip(at, 4);
      if (entries > 1000000) throw std::runtime_error("Ark 模块导入导出表超限");
      const unsigned strings = group == 1 ? 1 : group == 4 ? 0 : 2;
      for (uint32_t i = 0; i < entries; ++i) {
        for (unsigned s = 0; s < strings; ++s) { StringRef(at); Skip(at, 4); }
        if (group != 2) {
          const auto low = Byte(at), high = Byte(at);
          if ((uint32_t(low) | uint32_t(high) << 8) >= requests)
            throw std::runtime_error("Ark 模块请求索引无效");
        }
      }
    }
  }
  bool InAnnotation(uint32_t at) const {
    const auto next = annotation_ranges_.upper_bound(at);
    if (next == annotation_ranges_.begin()) return false;
    const auto range = std::prev(next);
    return at >= range->first && uint64_t(at) + 4 <= range->second;
  }
  void Annotation(uint32_t id, unsigned depth = 0) {
    if (depth > 64) throw std::runtime_error("Ark 注解嵌套过深");
    if (!annotations_.insert(id).second) return;
    const auto header = U32(id), count = header >> 16;
    uint32_t end = id; Skip(end, 4); Skip(end, count * 9);
    for (uint32_t i = 0; i < count; ++i) {
      const auto element = id + 4 + i * 8;
      StringRef(element);
      const char tag = bytes_[id + 4 + count * 8 + i];
      if (tag == 'C') StringRef(element + 4);
      else if (tag == 'D' || tag == 'E' || tag == 'F') refs_[element + 4] = U32(element + 4);
      else if (tag == 'G') Annotation(U32(element + 4), depth + 1);
      else if (tag == 'V') {
        const auto array = U32(element + 4), size = U32(array);
        for (auto position : Table(array + 4, size)) StringRef(position);
      } else if (std::string("123456789ABDEFIJKLMNOPQRSTUWXYZ@*").find(tag) == std::string::npos) {
        throw std::runtime_error("Ark 注解类型暂不支持");
      }
    }
    annotation_ranges_[id] = end;
  }
  // Follow class/member tags, rather than searching arbitrary byte patterns
  // for annotation headers. Based on libpandafile's data accessors. Only the
  // exact string fields are redirected; scalar values are never rewritten.
  void Metadata(const std::vector<uint32_t>& classes) {
    const auto foreign = U32(20), foreign_size = U32(24);
    for (auto position : classes) {
      uint32_t at = U32(position);
      if (at >= foreign && uint64_t(at) < uint64_t(foreign) + foreign_size) continue;
      const auto id = at;
      Leb(at); while (Byte(at)) {}  // class descriptor (already validated)
      ClassRecord record; record.body = at;
      refs_[at] = U32(at); Skip(at, 4); Leb(at);  // superclass, access flags
      const auto fields = Leb(at), methods = Leb(at);
      if (uint64_t(fields) + methods > bytes_.size() / 9) throw std::runtime_error("Ark 成员表无效");
      for (auto tag = Byte(at); tag; tag = Byte(at)) {
        if (tag == 1) { const auto count = Leb(at); if (count > 65536) throw std::runtime_error("Ark 接口表无效"); Skip(at, count * 2); }
        else if (tag == 2) Skip(at, 1);
        else if (tag >= 3 && tag <= 6) { Annotation(U32(at)); Skip(at, 4); }
        else if (tag == 7) { StringRef(at); Skip(at, 4); }
        else throw std::runtime_error("Ark 类标记暂不支持");
      }
      for (uint32_t i = 0; i < fields + methods; ++i) {
        record.members.push_back(at);
        Skip(at, 4); const auto name = String(U32(at)); StringRef(at); Skip(at, 4); Leb(at);
        for (auto tag = Byte(at); tag; tag = Byte(at)) {
          if (i < fields) {
            if (tag == 1) { // signed LEB scalar: only skip its encoded bytes
              unsigned length = 0; while (Byte(at) & 128) if (++length >= 5) throw std::runtime_error("Ark 字段值无效");
            } else if (tag == 2) { if (name == "moduleRecordIdx") Module(U32(at)); Skip(at, 4); }
            else if (tag >= 3 && tag <= 6) { Annotation(U32(at)); Skip(at, 4); }
            else throw std::runtime_error("Ark 字段标记暂不支持");
          } else {
            if (tag == 2) Skip(at, 1);
            else if (tag == 1) { Code(U32(at)); Skip(at, 4); } // code bodies do not move
            else if (tag == 5) { refs_[at] = U32(at); Debug(U32(at)); Skip(at, 4); }
            else if (tag == 3 || tag == 6 || tag == 8 || tag == 9) { Annotation(U32(at)); Skip(at, 4); }
            else if (tag == 4 || tag == 7) { // parameter annotations
              uint32_t array = U32(at); const auto count = U32(array); Skip(array, 4);
              if (count > 65536) throw std::runtime_error("Ark 参数表无效");
              for (uint32_t p = 0; p < count; ++p) {
                const auto size = U32(array); Skip(array, 4);
                for (auto ref : Table(array, size)) Annotation(U32(ref));
                Skip(array, size * 4);
              }
              Skip(at, 4);
            } else throw std::runtime_error("Ark 方法标记暂不支持");
          }
        }
      }
      record.end = at; records_[id] = std::move(record);
    }
  }
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
        if (tag == 6 || tag == 7 || tag == 22 || tag == 26 || tag == 27) found[at] = U32(at);
        if (tag == 24) children.push_back(U32(at));
        at += size;
      }
    } catch (const std::exception&) { return; }
    refs_.insert(found.begin(), found.end());
    for (auto child : children) Literal(child, depth + 1);
  }
};
}  // namespace qingqi::hap
