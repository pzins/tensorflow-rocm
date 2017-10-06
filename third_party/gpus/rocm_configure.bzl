_GCC_HOST_COMPILER_PATH = "GCC_HOST_COMPILER_PATH"
_ROCM_TOOLKIT_PATH = "ROCM_TOOLKIT_PATH"
_DEFAULT_ROCM_TOOLKIT_PATH = "/opt/rocm"
_TF_ROCM_CONFIG_REPO = "TF_ROCM_CONFIG_REPO"

_INC_DIR_MARKER_BEGIN = "#include <...>"


def _read_dir(repository_ctx, src_dir):
  """Returns a string with all files in a directory.

  Finds all files inside a directory, traversing subfolders and following
  symlinks. The returned string contains the full path of all files
  separated by line breaks.
  """
  find_result = _execute(
      repository_ctx, ["find", src_dir, "-follow", "-type", "f"],
      empty_stdout_fine=True)
  result = find_result.stdout
  return result

def _cxx_inc_convert(path):
  """Convert path returned by cc -E xc++ in a complete path."""
  path = path.strip()
  return path

def _rocm_include_path(repository_ctx, rocm_config):
  return "/opt/rocm/include"

def _execute(repository_ctx, cmdline, error_msg=None, error_details=None,
             empty_stdout_fine=False):
  """Executes an arbitrary shell command.

  Args:
    repository_ctx: the repository_ctx object
    cmdline: list of strings, the command to execute
    error_msg: string, a summary of the error if the command fails
    error_details: string, details about the error or steps to fix it
    empty_stdout_fine: bool, if True, an empty stdout result is fine, otherwise
      it's an error
  Return:
    the result of repository_ctx.execute(cmdline)
  """
  result = repository_ctx.execute(cmdline)
  if result.stderr or not (empty_stdout_fine or result.stdout):
    auto_configure_fail(
        "\n".join([
            error_msg.strip() if error_msg else "Repository command failed",
            result.stderr.strip(),
            error_details if error_details else ""]))
  return result


def _get_cxx_inc_directories_impl(repository_ctx, cc, lang_is_cpp):
  """Compute the list of default C or C++ include directories."""
  if lang_is_cpp:
    lang = "c++"
  else:
    lang = "c"
  # TODO: We pass -no-canonical-prefixes here to match the compiler flags,
  #       but in rocm_clang CROSSTOOL file that is a `feature` and we should
  #       handle the case when it's disabled and no flag is passed
  result = repository_ctx.execute([cc, "-no-canonical-prefixes",
                                   "-E", "-x" + lang, "-", "-v"])
  index1 = result.stderr.find(_INC_DIR_MARKER_BEGIN)
  if index1 == -1:
    return []
  index1 = result.stderr.find("\n", index1)
  if index1 == -1:
    return []
  index2 = result.stderr.rfind("\n ")
  if index2 == -1 or index2 < index1:
    return []
  index2 = result.stderr.find("\n", index2 + 1)
  if index2 == -1:
    inc_dirs = result.stderr[index1 + 1:]
  else:
    inc_dirs = result.stderr[index1 + 1:index2].strip()

  return [str(repository_ctx.path(_cxx_inc_convert(p)))
          for p in inc_dirs.split("\n")]

def get_cxx_inc_directories(repository_ctx, cc):
  """Compute the list of default C and C++ include directories."""
  # For some reason `clang -xc` sometimes returns include paths that are
  # different from the ones from `clang -xc++`. (Symlink and a dir)
  # So we run the compiler with both `-xc` and `-xc++` and merge resulting lists
  includes_cpp = _get_cxx_inc_directories_impl(repository_ctx, cc, True)
  includes_c = _get_cxx_inc_directories_impl(repository_ctx, cc, False)

  includes_cpp_set = set(includes_cpp)
  return includes_cpp + [inc for inc in includes_c
                         if inc not in includes_cpp_set]



def find_cc(repository_ctx):
  """Find the C++ compiler."""
  # On Windows, we use Bazel's MSVC CROSSTOOL for GPU build
  # Return a dummy value for GCC detection here to avoid error
  target_cc_name = "gcc"
  cc_path_envvar = _GCC_HOST_COMPILER_PATH
  cc_name = target_cc_name

  if cc_path_envvar in repository_ctx.os.environ:
    cc_name_from_env = repository_ctx.os.environ[cc_path_envvar].strip()
    if cc_name_from_env:
      cc_name = cc_name_from_env
  if cc_name.startswith("/"):
    # Absolute path, maybe we should make this supported by our which function.
    return cc_name
  cc = repository_ctx.which(cc_name)
  if cc == None:
    fail(("Cannot find {}, either correct your path or set the {}" +
          " environment variable").format(target_cc_name, cc_path_envvar))
  return cc

def _find_libs(repository_ctx, rocm_config):
  """Returns the CUDA and cuDNN libraries on the system.

  Args:
    repository_ctx: The repository context.
    rocm_config: The CUDA config as returned by _get_rocm_config

  Returns:
    Map of library names to structs of filename and path as returned by
    _find_rocm_lib and _find_cupti_lib.
  """
  cpu_value = rocm_config.cpu_value
  return {
      "rocm": _find_rocm_lib("hip_hcc", repository_ctx, cpu_value, rocm_config.rocm_toolkit_path),
      "rocmrt": _find_rocm_lib(
          "hip_hcc", repository_ctx, cpu_value, rocm_config.rocm_toolkit_path),
      "rocmrt_static": _find_rocm_lib(
          "hip_hcc_static", repository_ctx, cpu_value,
          rocm_config.rocm_toolkit_path, static=True),
      "rocblas": _find_rocm_lib(
          "rocblas-hcc", repository_ctx, cpu_value, rocm_config.rocm_toolkit_path),
  }


def _find_rocm_lib(lib, repository_ctx, cpu_value, basedir, version="",
                   static=False):
  """Finds the given CUDA or cuDNN library on the system.

  Args:
    lib: The name of the library, such as "rocmrt"
    repository_ctx: The repository context.
    cpu_value: The name of the host operating system.
    basedir: The install directory of CUDA or cuDNN.
    version: The version of the library.
    static: True if static library, False if shared object.

  Returns:
    Returns a struct with the following fields:
      file_name: The basename of the library found on the system.
      path: The full path to the library.
  """
  file_name = _lib_name(lib, cpu_value, version, static)
  if cpu_value == "Linux":
    path = repository_ctx.path("%s/lib64/%s" % (basedir, file_name))
    if path.exists:
      return struct(file_name=file_name, path=str(path.realpath))
    path = repository_ctx.path("%s/lib64/stubs/%s" % (basedir, file_name))
    if path.exists:
      return struct(file_name=file_name, path=str(path.realpath))
    path = repository_ctx.path(
        "%s/lib/x86_64-linux-gnu/%s" % (basedir, file_name))
    if path.exists:
      return struct(file_name=file_name, path=str(path.realpath))

  elif cpu_value == "Windows":
    path = repository_ctx.path("%s/lib/x64/%s" % (basedir, file_name))
    if path.exists:
      return struct(file_name=file_name, path=str(path.realpath))

  path = repository_ctx.path("%s/lib/%s" % (basedir, file_name))
  if path.exists:
    return struct(file_name=file_name, path=str(path.realpath))
  path = repository_ctx.path("%s/%s" % (basedir, file_name))
  if path.exists:
    return struct(file_name=file_name, path=str(path.realpath))

  auto_configure_fail("Cannot find rocm library %s" % file_name)



def auto_configure_fail(msg):
  """Output failure message when rocm configuration fails."""
  red = "\033[0;31m"
  no_color = "\033[0m"
  fail("\n%sCuda Configuration Error:%s %s\n" % (red, no_color, msg))
# END cc_configure common functions (see TODO above).

def _norm_path(path):
  """Returns a path with '/' and remove the trailing slash."""
  path = path.replace("\\", "/")
  if path[-1] == "/":
    path = path[:-1]
  return path


def _compute_rocm_extra_copts(repository_ctx):
  capability_flags = ["--amdgpu-target=gfx900"]
  return str(capability_flags)


def _rocmrt_static_linkopt(cpu_value):
  """Returns additional platform-specific linkopts for rocmrt."""
  return "" if cpu_value == "Darwin" else "\"-lrt\","

def _enable_rocm(repository_ctx):
  if "TF_NEED_ROCM" in repository_ctx.os.environ:
    enable_rocm = repository_ctx.os.environ["TF_NEED_ROCM"].strip()
    return enable_rocm == "1"
  return False

def _cpu_value(repository_ctx):
  """Returns the name of the host operating system.

  Args:
    repository_ctx: The repository context.

  Returns:
    A string containing the name of the host operating system.
  """
  os_name = repository_ctx.os.name.lower()
  if os_name.startswith("mac os"):
    return "Darwin"
  if os_name.find("windows") != -1:
    return "Windows"
  result = repository_ctx.execute(["uname", "-s"])
  return result.stdout.strip()

def _tpl(repository_ctx, tpl, substitutions={}, out=None):
  if not out:
    out = tpl.replace(":", "/")
  repository_ctx.template(
      out,
      Label("//third_party/gpus/%s.tpl" % tpl),
      substitutions)

def _file(repository_ctx, label):
  repository_ctx.template(
      label.replace(":", "/"),
      Label("//third_party/gpus/%s.tpl" % label),
      {})

def _host_compiler_includes(repository_ctx, cc):
  """Generates the cxx_builtin_include_directory entries for gcc inc dirs.

  Args:
    repository_ctx: The repository context.
    cc: The path to the gcc host compiler.

  Returns:
    A string containing the cxx_builtin_include_directory for each of the gcc
    host compiler include directories, which can be added to the CROSSTOOL
    file.
  """
  inc_dirs = get_cxx_inc_directories(repository_ctx, cc)
  inc_entries = []
  for inc_dir in inc_dirs:
    inc_entries.append("  cxx_builtin_include_directory: \"%s\"" % inc_dir)
  return "\n".join(inc_entries)

_DUMMY_CROSSTOOL_BZL_FILE = """
def error_gpu_disabled():
  fail("ERROR: Building with --config=rocm but TensorFlow is not configured " +
       "to build with GPU support. Please re-run ./configure and enter 'Y' " +
       "at the prompt to build with GPU support.")

  native.genrule(
      name = "error_gen_crosstool",
      outs = ["CROSSTOOL"],
      cmd = "echo 'Should not be run.' && exit 1",
  )

  native.filegroup(
      name = "crosstool",
      srcs = [":CROSSTOOL"],
      output_licenses = ["unencumbered"],
  )
"""


_DUMMY_CROSSTOOL_BUILD_FILE = """
load("//crosstool:error_gpu_disabled.bzl", "error_gpu_disabled")

error_gpu_disabled()
"""



def _lib_name(lib, cpu_value, version="", static=False):
  """Constructs the platform-specific name of a library.

  Args:
    lib: The name of the library, such as "rocmrt"
    cpu_value: The name of the host operating system.
    version: The version of the library.
    static: True the library is static or False if it is a shared object.

  Returns:
    The platform-specific name of the library.
  """
  if cpu_value in ("Linux", "FreeBSD"):
    if static:
      return "lib%s.a" % lib
    else:
      if version:
        version = ".%s" % version
      return "lib%s.so%s" % (lib, version)
  elif cpu_value == "Windows":
    return "%s.lib" % lib
  elif cpu_value == "Darwin":
    if static:
      return "lib%s.a" % lib
    else:
      if version:
        version = ".%s" % version
    return "lib%s%s.dylib" % (lib, version)
  else:
    auto_configure_fail("Invalid cpu_value: %s" % cpu_value)


def _create_dummy_repository(repository_ctx):
  cpu_value = _cpu_value(repository_ctx)

  # Set up BUILD file for rocm/.
  _tpl(repository_ctx, "rocm:build_defs.bzl",
       {
           "%{rocm_is_configured}": "False",
           "%{rocm_extra_copts}": "[]"
       })
  _tpl(repository_ctx, "rocm:BUILD",
       {
           "%{rocm_driver_lib}": _lib_name("rocm", cpu_value),
           "%{rocmrt_static_lib}": _lib_name("rocmrt_static", cpu_value,
                                             static=True),
           "%{rocmrt_static_linkopt}": _rocmrt_static_linkopt(cpu_value),
           "%{rocmrt_lib}": _lib_name("rocrt", cpu_value),
           "%{rocblas_lib}": _lib_name("rocblas", cpu_value),
           "%{rocm_include_genrules}": '',
           "%{rocm_headers}": '',
       })

  # Create dummy files for the CUDA toolkit since they are still required by
  # tensorflow/core/platform/default/build_config:rocm.
  repository_ctx.file("rocm/hip/include/hip/hip_runtime.h", "")
  repository_ctx.file("rocm/rocblas/include/rocblas/rocblas.h", "")
  repository_ctx.file("rocm/hip/lib/%s" % _lib_name("rocm", cpu_value))
  repository_ctx.file("rocm/hip/lib/%s" % _lib_name("rocmrt", cpu_value))
  repository_ctx.file("rocm/hip/lib/%s" % _lib_name("rocmrt_static", cpu_value))
  repository_ctx.file("rocm/rocblas/lib/%s" % _lib_name("rocblas", cpu_value))

  # Set up rocm_config.h, which is used by
  # tensorflow/stream_executor/dso_loader.cc.
  _tpl(repository_ctx, "rocm:rocm_config.h",
       {
           "%{rocm_toolkit_path}": _DEFAULT_ROCM_TOOLKIT_PATH,
       }, "rocm/rocm/rocm_config.h")

  # If rocm_configure is not configured to build with GPU support, and the user
  # attempts to build with --config=rocm, add a dummy build rule to intercept
  # this and fail with an actionable error message.
  repository_ctx.file("crosstool/error_gpu_disabled.bzl",
                      _DUMMY_CROSSTOOL_BZL_FILE)
  repository_ctx.file("crosstool/BUILD", _DUMMY_CROSSTOOL_BUILD_FILE)


def _create_remote_rocm_repository(repository_ctx, remote_config_repo):
  """Creates pointers to a remotely configured repo set up to build with CUDA."""
  _tpl(repository_ctx, "rocm:build_defs.bzl",
       {
           "%{rocm_is_configured}": "True",
           "%{rocm_extra_copts}": _compute_rocm_extra_copts(
               repository_ctx, #_compute_capabilities(repository_ctx)
            ),

       })

def _rocm_toolkit_path(repository_ctx):
  """Finds the rocm toolkit directory.

  Args:
    repository_ctx: The repository context.

  Returns:
    A speculative real path of the rocm toolkit install directory.
  """
  rocm_toolkit_path = _DEFAULT_ROCM_TOOLKIT_PATH
  if _ROCM_TOOLKIT_PATH in repository_ctx.os.environ:
    rocm_toolkit_path = repository_ctx.os.environ[_ROCM_TOOLKIT_PATH].strip()
  if not repository_ctx.path(rocm_toolkit_path).exists:
    auto_configure_fail("Cannot find rocm toolkit path.")
  return str(repository_ctx.path(rocm_toolkit_path).realpath)



def _get_rocm_config(repository_ctx):
  """Detects and returns information about the CUDA installation on the system.

  Args:
    repository_ctx: The repository context.

  Returns:
    A struct containing the following fields:
      rocm_toolkit_path: The CUDA toolkit installation directory.
      cudnn_install_basedir: The cuDNN installation directory.
      rocm_version: The version of CUDA on the system.
      cudnn_version: The version of cuDNN on the system.
      compute_capabilities: A list of the system's CUDA compute capabilities.
      cpu_value: The name of the host operating system.
  """
  cpu_value = _cpu_value(repository_ctx)
  rocm_toolkit_path = _rocm_toolkit_path(repository_ctx)
  return struct(
      rocm_toolkit_path = rocm_toolkit_path,
      cpu_value = cpu_value)

def _symlink_genrule_for_dir(repository_ctx, src_dir, dest_dir, genrule_name,
    src_files = [], dest_files = []):
  """Returns a genrule to symlink(or copy if on Windows) a set of files.

  If src_dir is passed, files will be read from the given directory; otherwise
  we assume files are in src_files and dest_files
  """
  if src_dir != None:
    src_dir = _norm_path(src_dir)
    dest_dir = _norm_path(dest_dir)
    files = _read_dir(repository_ctx, src_dir)
    # Create a list with the src_dir stripped to use for outputs.
    dest_files = files.replace(src_dir, '').splitlines()
    src_files = files.splitlines()
  command = []
  # We clear folders that might have been generated previously to avoid
  # undesired inclusions
  command.append('if [ -d "$(@D)/include" ]; then rm $(@D)/include -drf; fi')
  command.append('if [ -d "$(@D)/lib" ]; then rm $(@D)/lib -drf; fi')
  outs = []
  for i in range(len(dest_files)):
    if dest_files[i] != "":
      # If we have only one file to link we do not want to use the dest_dir, as
      # $(@D) will include the full path to the file.
      dest = '$(@D)/' + dest_dir + dest_files[i] if len(dest_files) != 1 else '$(@D)/' + dest_files[i]
      # On Windows, symlink is not supported, so we just copy all the files.
      cmd = 'ln -s'
      command.append(cmd + ' "%s" "%s"' % (src_files[i] , dest))
      outs.append('        "' + dest_dir + dest_files[i] + '",')
  genrule = _genrule(src_dir, genrule_name, " && ".join(command),
                     "\n".join(outs))
  return genrule

def _genrule(src_dir, genrule_name, command, outs):
  """Returns a string with a genrule.

  Genrule executes the given command and produces the given outputs.
  """
  return (
      'genrule(\n' +
      '    name = "' +
      genrule_name + '",\n' +
      '    outs = [\n' +
      outs +
      '\n    ],\n' +
      '    cmd = """\n' +
      command +
      '\n   """,\n' +
      ')\n'
  )




def _create_local_rocm_repository(repository_ctx):
  """Creates the repository containing files set up to build with CUDA."""
  rocm_config = _get_rocm_config(repository_ctx)

#  cudnn_header_dir = _find_cudnn_header_dir(repository_ctx,
#                                            rocm_config.cudnn_install_basedir)

  # Set up symbolic links for the rocm toolkit by creating genrules to do
  # symlinking. We create one genrule for each directory we want to track under
  # rocm_toolkit_path
  rocm_toolkit_path = rocm_config.rocm_toolkit_path
  rocm_include_path = rocm_toolkit_path + "/include"
  genrules = [_symlink_genrule_for_dir(repository_ctx,
      rocm_include_path, "rocm/include", "rocm-include")]

  rocm_libs = _find_libs(repository_ctx, rocm_config)
  rocm_lib_src = []
  rocm_lib_dest = []
  for lib in rocm_libs.values():
    rocm_lib_src.append(lib.path)
    rocm_lib_dest.append("rocm/lib/" + lib.file_name)
  genrules.append(_symlink_genrule_for_dir(repository_ctx, None, "", "rocm-lib",
                                       rocm_lib_src, rocm_lib_dest))

  # Set up the symbolic links for cudnn if cudnn was was not installed to
  # CUDA_TOOLKIT_PATH.
  included_files = _read_dir(repository_ctx, rocm_include_path).replace(
      rocm_include_path, '').splitlines()

  # Set up BUILD file for rocm/
  _tpl(repository_ctx, "rocm:build_defs.bzl",
       {
           "%{rocm_is_configured}": "True",
           "%{rocm_extra_copts}": _compute_rocm_extra_copts(
               repository_ctx),

       })
  _tpl(repository_ctx, "rocm:BUILD",
       {
           "%{rocm_driver_lib}": rocm_libs["rocm"].file_name,
           "%{rocmrt_static_lib}": rocm_libs["rocmrt_static"].file_name,
           "%{rocmrt_static_linkopt}": _rocmrt_static_linkopt(
               rocm_config.cpu_value),
           "%{rocmrt_lib}": rocm_libs["rocmrt"].file_name,
           "%{rocblas_lib}": rocm_libs["rocblas"].file_name,
           "%{rocm_headers}": ('":rocm-include",\n')
       })
  # Set up crosstool/
  _file(repository_ctx, "crosstool:BUILD")
  cc = find_cc(repository_ctx)
  host_compiler_includes = _host_compiler_includes(repository_ctx, cc)
  rocm_defines = {
           "%{rocm_include_path}": _rocm_include_path(repository_ctx,
                                                      rocm_config),
           "%{host_compiler_includes}": host_compiler_includes,
       }
  _tpl(repository_ctx,
       "crosstool:clang/bin/crosstool_wrapper_driver_is_not_gcc",
       {
           "%{cpu_compiler}": str(cc),
           "%{gcc_host_compiler_path}": str(cc),
       })

  # Set up rocm_config.h, which is used by
  # tensorflow/stream_executor/dso_loader.cc.
  _tpl(repository_ctx, "rocm:rocm_config.h",
       {
       }, "rocm/rocm/rocm_config.h")


def _rocm_autoconf_impl(repository_ctx):
  """Implementation of the rocm_autoconf repository rule."""
  if not _enable_rocm(repository_ctx):
    _create_dummy_repository(repository_ctx)
  else:
    if _TF_ROCM_CONFIG_REPO in repository_ctx.os.environ:
      _create_remote_rocm_repository(repository_ctx,
          repository_ctx.os.environ[_TF_ROCM_CONFIG_REPO])
    else:
      _create_local_rocm_repository(repository_ctx)


rocm_configure = repository_rule(
    implementation = _rocm_autoconf_impl,
    environ = [
        _GCC_HOST_COMPILER_PATH,
        "TF_NEED_ROCM",
        _ROCM_TOOLKIT_PATH,
        _TF_ROCM_CONFIG_REPO,
    ],
)
