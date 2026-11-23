// gogaku_dict_tool：发布侧构建官方词库用的命令行工具。
// 与设置应用导入共用 gc_dict_import 的同一份转换实现（docs/dictionaries.md §七）。
//
// 用法：
//   gogaku_dict_tool convert --input SRC --system-dict SC.DICT [--name NAME]
//                            [--work DIR] --output OUT.dict --report REPORT.json
//
// 过程：在 --work（缺省为 OUT 所在目录下的 .dict-tool-work）里走完整导入，
// 成功后把生成的 .dict 移到 --output，把结果 JSON 写到 --report。
// 失败时 stderr 打印原因并以非零退出；取消码（3）不会出现（无进度回调）。
#include "gogaku_core.h"

#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>

#ifdef _WIN32
#include "windows_io.h"
#endif

namespace {

bool copy_file_bytes(const std::string &from, const std::string &to) {
    std::ifstream in(from, std::ios::binary);
    if (!in) return false;
    std::string data((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    std::ofstream out(to, std::ios::binary);
    if (!out) return false;
    out.write(data.data(), static_cast<std::streamsize>(data.size()));
    return static_cast<bool>(out);
}

}  // namespace

int main(int argc, char **argv) {
    std::string input, systemDict, name, work, output, report;
    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        auto next = [&](const char *what) -> std::string {
            if (i + 1 >= argc) {
                std::cerr << "缺少 " << what << " 的值\n";
                exit(2);
            }
            return argv[++i];
        };
        if (arg == "convert") continue;  // 子命令：目前只有 convert
        else if (arg == "--input") input = next("--input");
        else if (arg == "--system-dict") systemDict = next("--system-dict");
        else if (arg == "--name") name = next("--name");
        else if (arg == "--work") work = next("--work");
        else if (arg == "--output") output = next("--output");
        else if (arg == "--report") report = next("--report");
        else {
            std::cerr << "未知参数：" << arg << "\n";
            return 2;
        }
    }
    if (input.empty() || systemDict.empty() || output.empty() || report.empty()) {
        std::cerr << "用法：gogaku_dict_tool convert --input SRC --system-dict SC.DICT "
                     "[--name NAME] [--work DIR] --output OUT.dict --report REPORT.json\n";
        return 2;
    }
    if (work.empty()) {
        const size_t slash = output.find_last_of("/\\");
        work = (slash == std::string::npos ? std::string(".") : output.substr(0, slash)) +
               "/.dict-tool-work";
    }
    std::error_code ec;
    std::filesystem::create_directories(
#ifdef _WIN32
        gogaku::windows_io::file_path(work),
#else
        std::filesystem::u8path(work),
#endif
        ec);
    if (ec) {
        std::cerr << "无法创建工作目录：" << work << "\n";
        return 2;
    }

    GcDictImportRequest req{};
    req.input_path = input.c_str();
    req.dictionaries_dir = work.c_str();
    req.system_dict_path = systemDict.c_str();
    req.display_name = name.empty() ? nullptr : name.c_str();
    char *result = nullptr;
    char err[512] = {0};
    const int rc = gc_dict_import(&req, nullptr, nullptr, &result, err, sizeof(err));
    if (rc != 0 || result == nullptr) {
        std::cerr << "转换失败（" << rc << "）：" << err << "\n";
        return rc == 0 ? 2 : rc;
    }
    // 从结果 JSON 取 id，把 .dict 移到输出位置。
    std::string resultText = result;
    gc_contract_free(result);
    const auto idPos = resultText.find("\"id\":\"");
    if (idPos == std::string::npos) {
        std::cerr << "导入结果缺少 id\n";
        return 2;
    }
    const size_t idStart = idPos + 6;
    const size_t idEnd = resultText.find('"', idStart);
    const std::string id = resultText.substr(idStart, idEnd - idStart);
    if (!copy_file_bytes(work + "/" + id + ".dict", output)) {
        std::cerr << "无法写出 " << output << "\n";
        return 2;
    }
    {
        std::ofstream out(report, std::ios::binary);
        out << resultText << "\n";
        if (!out) {
            std::cerr << "无法写出 " << report << "\n";
            return 2;
        }
    }
    std::cout << "已生成 " << output << "（" << resultText << "）\n";
    return 0;
}
