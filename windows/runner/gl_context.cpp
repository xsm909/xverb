#include "gl_context.h"

#include <cstring>

#pragma comment(lib, "opengl32.lib")

namespace gl {

namespace {

// The attributes `wglCreateContextAttribsARB` takes. From `WGL_ARB_create_
// context`, which is the only way to be given anything but a legacy context.
constexpr int kContextMajorVersion = 0x2091;
constexpr int kContextMinorVersion = 0x2092;
constexpr int kContextProfileMask = 0x9126;
constexpr int kContextCoreProfileBit = 0x00000001;

using PfnCreateContextAttribs = HGLRC(WINAPI*)(HDC, HGLRC, const int*);

// What the class is called. Registered once; a second `RegisterClass` with the
// same name fails and is not a problem, because the class is already there.
constexpr wchar_t kWindowClass[] = L"xverbOffscreenGL";

std::string Narrow(const GLubyte* text) {
  return text == nullptr ? std::string()
                         : std::string(reinterpret_cast<const char*>(text));
}

// Whether `renderer` is one of the implementations that do the rasterising on
// the processor. They exist, they are honest about their names, and every one
// of them is slower than the renderer this application already has — which
// puts its triangles through the GPU by way of Flutter's own canvas.
bool IsSoftware(const std::string& renderer) {
  static constexpr const char* kNames[] = {"GDI Generic", "llvmpipe",
                                           "softpipe", "swrast",
                                           "Microsoft Basic Render"};
  for (const char* name : kNames) {
    if (renderer.find(name) != std::string::npos) return true;
  }
  return false;
}

std::string* Failure() {
  static std::string reason;
  return &reason;
}

}  // namespace

const std::string& Context::failure() { return *Failure(); }

Context* Context::Instance() {
  // Tried once. A machine does not grow a driver while the application is
  // running, and a failed attempt leaves a window and a DC behind that there
  // is no reason to leave again.
  static Context* instance = []() -> Context* {
    auto* made = new Context();
    if (made->Start()) return made;
    delete made;
    return nullptr;
  }();
  return instance;
}

bool Context::MakeCurrent() {
  return context_ != nullptr && wglMakeCurrent(dc_, context_) == TRUE;
}

bool Context::Start() {
  WNDCLASSEXW description{};
  description.cbSize = sizeof(description);
  description.lpfnWndProc = DefWindowProcW;
  description.hInstance = GetModuleHandleW(nullptr);
  description.lpszClassName = kWindowClass;
  RegisterClassExW(&description);

  // A window nobody sees, and 1x1 because nothing is ever drawn to it: the
  // pictures are made in framebuffer objects. It exists because on Windows a
  // GL context is given out against a device context, and a device context
  // comes from a window.
  window_ = CreateWindowExW(0, kWindowClass, L"xverb OpenGL", WS_OVERLAPPED, 0,
                            0, 1, 1, nullptr, nullptr,
                            GetModuleHandleW(nullptr), nullptr);
  if (window_ == nullptr) {
    *Failure() = "no offscreen window";
    return false;
  }
  dc_ = GetDC(window_);
  if (dc_ == nullptr) {
    *Failure() = "no device context";
    return false;
  }

  PIXELFORMATDESCRIPTOR format{};
  format.nSize = sizeof(format);
  format.nVersion = 1;
  format.dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER;
  format.iPixelType = PFD_TYPE_RGBA;
  format.cColorBits = 32;
  format.cDepthBits = 24;
  format.iLayerType = PFD_MAIN_PLANE;
  const int chosen = ChoosePixelFormat(dc_, &format);
  if (chosen == 0 || SetPixelFormat(dc_, chosen, &format) == FALSE) {
    *Failure() = "no pixel format";
    return false;
  }

  // The two-step every Windows GL program does. `wglCreateContextAttribsARB`
  // is itself an extension, so a legacy context has to be made and made
  // current before the driver will say whether the real one can be had.
  HGLRC legacy = wglCreateContext(dc_);
  if (legacy == nullptr || wglMakeCurrent(dc_, legacy) == FALSE) {
    *Failure() = "no legacy context";
    if (legacy != nullptr) wglDeleteContext(legacy);
    return false;
  }

  // Asked of the legacy context, and this is the only moment it can be asked:
  // a context made for 3.3 reports 3.3 however much the driver can do, and
  // "OpenGL 3.3" on a card that does 4.6 reads like something went wrong.
  const std::string highest = Narrow(glGetString(GL_VERSION));

  auto create = reinterpret_cast<PfnCreateContextAttribs>(
      wglGetProcAddress("wglCreateContextAttribsARB"));
  if (create != nullptr) {
    const int attributes[] = {kContextMajorVersion, 3,
                              kContextMinorVersion, 3,
                              kContextProfileMask,  kContextCoreProfileBit,
                              0};
    context_ = create(dc_, nullptr, attributes);
  }
  wglMakeCurrent(nullptr, nullptr);
  wglDeleteContext(legacy);

  if (context_ == nullptr || !MakeCurrent()) {
    // No 3.3 to be had. Which is the answer, not a failure to get an answer:
    // the driver that cannot give a core context is the driver whose fixed
    // pipeline we do not want.
    *Failure() = "OpenGL 3.3 refused";
    return false;
  }

  const std::string renderer = Narrow(glGetString(GL_RENDERER));
  const std::string vendor = Narrow(glGetString(GL_VENDOR));
  const std::string version = Narrow(glGetString(GL_VERSION));
  if (IsSoftware(renderer)) {
    *Failure() = renderer + " is not a GPU";
    return false;
  }

  GLint major = 0;
  GLint minor = 0;
  glGetIntegerv(kMajorVersion, &major);
  glGetIntegerv(kMinorVersion, &minor);
  if (major < 3 || (major == 3 && minor < 3)) {
    *Failure() = "OpenGL " + version;
    return false;
  }

  // "4.6.0 NVIDIA 566.36" down to "4.6": the driver writes its own build after
  // the version and nobody reading a status line wants it.
  const size_t second = highest.find('.', highest.find('.') + 1);
  description_ = "OpenGL " +
                 (highest.empty()
                      ? std::to_string(major) + "." + std::to_string(minor)
                      : highest.substr(0, second)) +
                 " · " + (renderer.empty() ? vendor : renderer);

  // How much smoothing the edges can have. Four is plenty for a preview and
  // costs nothing worth measuring; a driver that offers less is taken at its
  // word.
  GLint most = 0;
  glGetIntegerv(kMaxSamples, &most);
  samples_ = most >= 4 ? 4 : (most >= 2 ? 2 : 1);

#define XVERB_LOAD(field, name)                                     \
  api_.field = reinterpret_cast<decltype(api_.field)>(              \
      wglGetProcAddress(name));                                     \
  if (api_.field == nullptr) {                                      \
    *Failure() = std::string("no ") + name;                         \
    return false;                                                   \
  }

  XVERB_LOAD(GenBuffers, "glGenBuffers")
  XVERB_LOAD(BindBuffer, "glBindBuffer")
  XVERB_LOAD(BufferData, "glBufferData")
  XVERB_LOAD(BufferSubData, "glBufferSubData")
  XVERB_LOAD(DeleteBuffers, "glDeleteBuffers")
  XVERB_LOAD(MapBuffer, "glMapBuffer")
  XVERB_LOAD(UnmapBuffer, "glUnmapBuffer")
  XVERB_LOAD(BindBufferBase, "glBindBufferBase")

  XVERB_LOAD(GenVertexArrays, "glGenVertexArrays")
  XVERB_LOAD(BindVertexArray, "glBindVertexArray")
  XVERB_LOAD(DeleteVertexArrays, "glDeleteVertexArrays")
  XVERB_LOAD(EnableVertexAttribArray, "glEnableVertexAttribArray")
  XVERB_LOAD(VertexAttribPointer, "glVertexAttribPointer")
  XVERB_LOAD(VertexAttribIPointer, "glVertexAttribIPointer")

  XVERB_LOAD(CreateShader, "glCreateShader")
  XVERB_LOAD(ShaderSource, "glShaderSource")
  XVERB_LOAD(CompileShader, "glCompileShader")
  XVERB_LOAD(GetShaderiv, "glGetShaderiv")
  XVERB_LOAD(GetShaderInfoLog, "glGetShaderInfoLog")
  XVERB_LOAD(DeleteShader, "glDeleteShader")
  XVERB_LOAD(CreateProgram, "glCreateProgram")
  XVERB_LOAD(AttachShader, "glAttachShader")
  XVERB_LOAD(LinkProgram, "glLinkProgram")
  XVERB_LOAD(GetProgramiv, "glGetProgramiv")
  XVERB_LOAD(GetProgramInfoLog, "glGetProgramInfoLog")
  XVERB_LOAD(UseProgram, "glUseProgram")
  XVERB_LOAD(DeleteProgram, "glDeleteProgram")
  XVERB_LOAD(GetUniformLocation, "glGetUniformLocation")
  XVERB_LOAD(Uniform1i, "glUniform1i")
  XVERB_LOAD(Uniform1f, "glUniform1f")
  XVERB_LOAD(Uniform3fv, "glUniform3fv")
  XVERB_LOAD(Uniform4fv, "glUniform4fv")
  XVERB_LOAD(UniformMatrix3fv, "glUniformMatrix3fv")
  XVERB_LOAD(UniformMatrix4fv, "glUniformMatrix4fv")
  XVERB_LOAD(GetUniformBlockIndex, "glGetUniformBlockIndex")
  XVERB_LOAD(UniformBlockBinding, "glUniformBlockBinding")

  XVERB_LOAD(GenFramebuffers, "glGenFramebuffers")
  XVERB_LOAD(BindFramebuffer, "glBindFramebuffer")
  XVERB_LOAD(DeleteFramebuffers, "glDeleteFramebuffers")
  XVERB_LOAD(FramebufferTexture2D, "glFramebufferTexture2D")
  XVERB_LOAD(FramebufferRenderbuffer, "glFramebufferRenderbuffer")
  XVERB_LOAD(GenRenderbuffers, "glGenRenderbuffers")
  XVERB_LOAD(BindRenderbuffer, "glBindRenderbuffer")
  XVERB_LOAD(DeleteRenderbuffers, "glDeleteRenderbuffers")
  XVERB_LOAD(RenderbufferStorage, "glRenderbufferStorage")
  XVERB_LOAD(RenderbufferStorageMultisample,
             "glRenderbufferStorageMultisample")
  XVERB_LOAD(CheckFramebufferStatus, "glCheckFramebufferStatus")
  XVERB_LOAD(BlitFramebuffer, "glBlitFramebuffer")

  XVERB_LOAD(ActiveTexture, "glActiveTexture")
  XVERB_LOAD(Generatemipmap, "glGenerateMipmap")

#undef XVERB_LOAD

  return true;
}

}  // namespace gl
