#include "utils/json.hpp"
#include <fstream>
#include <sstream>
#include <cctype>

namespace vmstate {
namespace utils {

namespace {

// Skip whitespace
void skip_ws(const std::string& s, size_t& pos) {
    while (pos < s.size() && std::isspace(s[pos])) {
        pos++;
    }
}

// Parse a JSON string
std::optional<std::string> parse_string(const std::string& s, size_t& pos) {
    skip_ws(s, pos);
    if (pos >= s.size() || s[pos] != '"') {
        return std::nullopt;
    }
    pos++;  // Skip opening quote

    std::string result;
    while (pos < s.size() && s[pos] != '"') {
        if (s[pos] == '\\' && pos + 1 < s.size()) {
            pos++;
            switch (s[pos]) {
                case '"': result += '"'; break;
                case '\\': result += '\\'; break;
                case 'n': result += '\n'; break;
                case 't': result += '\t'; break;
                case 'r': result += '\r'; break;
                default: result += s[pos]; break;
            }
        } else {
            result += s[pos];
        }
        pos++;
    }

    if (pos >= s.size()) {
        return std::nullopt;
    }
    pos++;  // Skip closing quote
    return result;
}

// Escape a string for JSON
std::string escape_string(const std::string& s) {
    std::string result;
    for (char c : s) {
        switch (c) {
            case '"': result += "\\\""; break;
            case '\\': result += "\\\\"; break;
            case '\n': result += "\\n"; break;
            case '\t': result += "\\t"; break;
            case '\r': result += "\\r"; break;
            default: result += c; break;
        }
    }
    return result;
}

}  // anonymous namespace

std::map<std::string, std::string> parse_json_object(const std::string& json) {
    std::map<std::string, std::string> result;
    size_t pos = 0;

    skip_ws(json, pos);
    if (pos >= json.size() || json[pos] != '{') {
        return result;  // Not a valid JSON object
    }
    pos++;  // Skip '{'

    while (pos < json.size()) {
        skip_ws(json, pos);

        if (pos < json.size() && json[pos] == '}') {
            break;  // End of object
        }

        // Parse key
        auto key = parse_string(json, pos);
        if (!key) {
            return {};  // Parse error
        }

        skip_ws(json, pos);
        if (pos >= json.size() || json[pos] != ':') {
            return {};  // Expected ':'
        }
        pos++;  // Skip ':'

        // Parse value
        auto value = parse_string(json, pos);
        if (!value) {
            return {};  // Parse error
        }

        result[*key] = *value;

        skip_ws(json, pos);
        if (pos < json.size() && json[pos] == ',') {
            pos++;  // Skip ','
        }
    }

    return result;
}

std::string to_json_object(const std::map<std::string, std::string>& data) {
    if (data.empty()) {
        return "{}";
    }

    std::ostringstream ss;
    ss << "{\n";

    bool first = true;
    for (const auto& [key, value] : data) {
        if (!first) {
            ss << ",\n";
        }
        first = false;
        ss << "  \"" << escape_string(key) << "\": \"" << escape_string(value) << "\"";
    }

    ss << "\n}";
    return ss.str();
}

std::optional<std::map<std::string, std::string>> read_json_file(
    const std::string& path) {
    std::ifstream file(path);
    if (!file) {
        return std::nullopt;
    }

    std::ostringstream ss;
    ss << file.rdbuf();
    std::string content = ss.str();

    if (content.empty()) {
        return std::map<std::string, std::string>{};
    }

    auto result = parse_json_object(content);
    return result;
}

bool write_json_file(const std::string& path,
                     const std::map<std::string, std::string>& data) {
    // Write to temp file first, then rename for atomicity
    std::string temp_path = path + ".tmp";
    std::ofstream file(temp_path);
    if (!file) {
        return false;
    }

    file << to_json_object(data) << "\n";
    file.close();

    if (!file) {
        return false;
    }

    if (rename(temp_path.c_str(), path.c_str()) != 0) {
        return false;
    }

    return true;
}

} // namespace utils
} // namespace vmstate
