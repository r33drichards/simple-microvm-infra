project('vm-state', 'cpp',
  version : '0.1.0',
  default_options : ['warning_level=3', 'cpp_std=c++17'])

# Dependencies
zfs_dep = dependency('libzfs', required : true)
json_dep = dependency('nlohmann_json', required : true)

# Source files
sources = [
  'src/main.cpp',
  'src/vm_state.cpp',
]

# Build executable
executable('vm-state',
  sources,
  dependencies : [zfs_dep, json_dep],
  install : true)
