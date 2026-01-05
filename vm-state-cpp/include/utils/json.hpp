#pragma once

#include <string>
#include <map>
#include <optional>

namespace vmstate {
namespace utils {

/**
 * Simple JSON utilities for reading/writing assignment files
 *
 * We implement a minimal JSON parser rather than adding a dependency.
 * The JSON files we handle are simple key-value maps like:
 * {"slot1": "state1", "slot2": "state2"}
 */

/**
 * Parse a JSON object containing string key-value pairs
 * @param json JSON string
 * @return Map of key-value pairs, empty on parse error
 */
std::map<std::string, std::string> parse_json_object(const std::string& json);

/**
 * Serialize a map to JSON object string
 * @param data Map to serialize
 * @return JSON string
 */
std::string to_json_object(const std::map<std::string, std::string>& data);

/**
 * Read JSON file to map
 * @param path File path
 * @return Map if successful
 */
std::optional<std::map<std::string, std::string>> read_json_file(
    const std::string& path);

/**
 * Write map to JSON file
 * @param path File path
 * @param data Map to write
 * @return true if successful
 */
bool write_json_file(const std::string& path,
                     const std::map<std::string, std::string>& data);

} // namespace utils
} // namespace vmstate
