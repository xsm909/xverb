#ifndef RUNNER_GL_CONTEXT_H_
#define RUNNER_GL_CONTEXT_H_

#include <windows.h>

#include <gl/GL.h>

#include <string>

// An OpenGL 3.3 core context on a window nobody sees, plus the entry points
// that `opengl32.lib` does not export.
//
// Windows always has `opengl32.dll` and it always answers — with OpenGL 1.1,
// software, from 1995, if no driver has replaced it. That answer is worse than
// what the application already does: `Canvas.drawVertices` rasterises on the
// GPU and only the vertex work is on the CPU, whereas 1.1 puts *both* on the
// CPU and adds a frame readback on top. So this asks for 3.3 core and takes no
// substitute: below it there are no vertex buffers to keep geometry on the card
// with, no shaders to pose it in, and no framebuffer objects to draw into. A
// machine that cannot answer is not a machine to fall back gently for — it is
// the machine the existing renderer is right for.
//
// Nothing here is loaded eagerly. [GlContext::Probe] is the one call that makes
// a context, and it is made once, kept, and reused by every model the
// application opens.
namespace gl {

// The types `gl/GL.h` predates.
using GLchar = char;
using GLsizeiptr = ptrdiff_t;
using GLintptr = ptrdiff_t;

// Constants the 1.1 header does not carry. Named rather than written inline,
// because a mistyped enum in a GL call fails silently and at the far end.
constexpr GLenum kArrayBuffer = 0x8892;
constexpr GLenum kElementArrayBuffer = 0x8893;
constexpr GLenum kUniformBuffer = 0x8A11;
constexpr GLenum kPixelPackBuffer = 0x88EB;
constexpr GLenum kStaticDraw = 0x88E4;
constexpr GLenum kDynamicDraw = 0x88E8;
constexpr GLenum kStreamRead = 0x88E1;
constexpr GLenum kReadOnly = 0x88B8;

constexpr GLenum kVertexShader = 0x8B31;
constexpr GLenum kFragmentShader = 0x8B30;
constexpr GLenum kCompileStatus = 0x8B81;
constexpr GLenum kLinkStatus = 0x8B82;
constexpr GLenum kInfoLogLength = 0x8B84;

constexpr GLenum kFramebuffer = 0x8D40;
constexpr GLenum kReadFramebuffer = 0x8CA8;
constexpr GLenum kDrawFramebuffer = 0x8CA9;
constexpr GLenum kRenderbuffer = 0x8D41;
constexpr GLenum kColorAttachment0 = 0x8CE0;
constexpr GLenum kDepthAttachment = 0x8D00;
constexpr GLenum kFramebufferComplete = 0x8CD5;
constexpr GLenum kDepthComponent24 = 0x81A6;
constexpr GLenum kRgba8 = 0x8058;
constexpr GLenum kMultisample = 0x809D;
constexpr GLenum kMaxSamples = 0x8D57;
constexpr GLenum kTexture0 = 0x84C0;
constexpr GLenum kClampToEdge = 0x812F;
constexpr GLenum kMajorVersion = 0x821B;
constexpr GLenum kMinorVersion = 0x821C;
constexpr GLenum kMaxUniformBlockSize = 0x8A30;

// The entry points, as they are named in GL. Function pointers rather than
// link-time symbols: everything above 1.1 has to be asked of the driver
// through `wglGetProcAddress`, which answers only while a context is current.
using PfnGenBuffers = void(APIENTRY*)(GLsizei, GLuint*);
using PfnBindBuffer = void(APIENTRY*)(GLenum, GLuint);
using PfnBufferData = void(APIENTRY*)(GLenum, GLsizeiptr, const void*, GLenum);
using PfnBufferSubData = void(APIENTRY*)(GLenum, GLintptr, GLsizeiptr,
                                         const void*);
using PfnDeleteBuffers = void(APIENTRY*)(GLsizei, const GLuint*);
using PfnMapBuffer = void*(APIENTRY*)(GLenum, GLenum);
using PfnUnmapBuffer = GLboolean(APIENTRY*)(GLenum);
using PfnBindBufferBase = void(APIENTRY*)(GLenum, GLuint, GLuint);

using PfnGenVertexArrays = void(APIENTRY*)(GLsizei, GLuint*);
using PfnBindVertexArray = void(APIENTRY*)(GLuint);
using PfnDeleteVertexArrays = void(APIENTRY*)(GLsizei, const GLuint*);
using PfnEnableVertexAttribArray = void(APIENTRY*)(GLuint);
using PfnVertexAttribPointer = void(APIENTRY*)(GLuint, GLint, GLenum,
                                               GLboolean, GLsizei, const void*);
using PfnVertexAttribIPointer = void(APIENTRY*)(GLuint, GLint, GLenum, GLsizei,
                                                const void*);

using PfnCreateShader = GLuint(APIENTRY*)(GLenum);
using PfnShaderSource = void(APIENTRY*)(GLuint, GLsizei, const GLchar* const*,
                                        const GLint*);
using PfnCompileShader = void(APIENTRY*)(GLuint);
using PfnGetShaderiv = void(APIENTRY*)(GLuint, GLenum, GLint*);
using PfnGetShaderInfoLog = void(APIENTRY*)(GLuint, GLsizei, GLsizei*, GLchar*);
using PfnDeleteShader = void(APIENTRY*)(GLuint);
using PfnCreateProgram = GLuint(APIENTRY*)();
using PfnAttachShader = void(APIENTRY*)(GLuint, GLuint);
using PfnLinkProgram = void(APIENTRY*)(GLuint);
using PfnGetProgramiv = void(APIENTRY*)(GLuint, GLenum, GLint*);
using PfnGetProgramInfoLog = void(APIENTRY*)(GLuint, GLsizei, GLsizei*,
                                             GLchar*);
using PfnUseProgram = void(APIENTRY*)(GLuint);
using PfnDeleteProgram = void(APIENTRY*)(GLuint);
using PfnGetUniformLocation = GLint(APIENTRY*)(GLuint, const GLchar*);
using PfnUniform1i = void(APIENTRY*)(GLint, GLint);
using PfnUniform1f = void(APIENTRY*)(GLint, GLfloat);
using PfnUniform3fv = void(APIENTRY*)(GLint, GLsizei, const GLfloat*);
using PfnUniform4fv = void(APIENTRY*)(GLint, GLsizei, const GLfloat*);
using PfnUniformMatrix3fv = void(APIENTRY*)(GLint, GLsizei, GLboolean,
                                            const GLfloat*);
using PfnUniformMatrix4fv = void(APIENTRY*)(GLint, GLsizei, GLboolean,
                                            const GLfloat*);
using PfnGetUniformBlockIndex = GLuint(APIENTRY*)(GLuint, const GLchar*);
using PfnUniformBlockBinding = void(APIENTRY*)(GLuint, GLuint, GLuint);

using PfnGenFramebuffers = void(APIENTRY*)(GLsizei, GLuint*);
using PfnBindFramebuffer = void(APIENTRY*)(GLenum, GLuint);
using PfnDeleteFramebuffers = void(APIENTRY*)(GLsizei, const GLuint*);
using PfnFramebufferTexture2D = void(APIENTRY*)(GLenum, GLenum, GLenum, GLuint,
                                                GLint);
using PfnFramebufferRenderbuffer = void(APIENTRY*)(GLenum, GLenum, GLenum,
                                                   GLuint);
using PfnGenRenderbuffers = void(APIENTRY*)(GLsizei, GLuint*);
using PfnBindRenderbuffer = void(APIENTRY*)(GLenum, GLuint);
using PfnDeleteRenderbuffers = void(APIENTRY*)(GLsizei, const GLuint*);
using PfnRenderbufferStorage = void(APIENTRY*)(GLenum, GLenum, GLsizei,
                                               GLsizei);
using PfnRenderbufferStorageMultisample = void(APIENTRY*)(GLenum, GLsizei,
                                                          GLenum, GLsizei,
                                                          GLsizei);
using PfnCheckFramebufferStatus = GLenum(APIENTRY*)(GLenum);
using PfnBlitFramebuffer = void(APIENTRY*)(GLint, GLint, GLint, GLint, GLint,
                                           GLint, GLint, GLint, GLbitfield,
                                           GLenum);

using PfnActiveTexture = void(APIENTRY*)(GLenum);
using PfnGenerateMipmap = void(APIENTRY*)(GLenum);

// Everything [Probe] found, and everything it loaded. One instance, owned by
// [Instance].
struct Api {
  PfnGenBuffers GenBuffers = nullptr;
  PfnBindBuffer BindBuffer = nullptr;
  PfnBufferData BufferData = nullptr;
  PfnBufferSubData BufferSubData = nullptr;
  PfnDeleteBuffers DeleteBuffers = nullptr;
  PfnMapBuffer MapBuffer = nullptr;
  PfnUnmapBuffer UnmapBuffer = nullptr;
  PfnBindBufferBase BindBufferBase = nullptr;

  PfnGenVertexArrays GenVertexArrays = nullptr;
  PfnBindVertexArray BindVertexArray = nullptr;
  PfnDeleteVertexArrays DeleteVertexArrays = nullptr;
  PfnEnableVertexAttribArray EnableVertexAttribArray = nullptr;
  PfnVertexAttribPointer VertexAttribPointer = nullptr;
  PfnVertexAttribIPointer VertexAttribIPointer = nullptr;

  PfnCreateShader CreateShader = nullptr;
  PfnShaderSource ShaderSource = nullptr;
  PfnCompileShader CompileShader = nullptr;
  PfnGetShaderiv GetShaderiv = nullptr;
  PfnGetShaderInfoLog GetShaderInfoLog = nullptr;
  PfnDeleteShader DeleteShader = nullptr;
  PfnCreateProgram CreateProgram = nullptr;
  PfnAttachShader AttachShader = nullptr;
  PfnLinkProgram LinkProgram = nullptr;
  PfnGetProgramiv GetProgramiv = nullptr;
  PfnGetProgramInfoLog GetProgramInfoLog = nullptr;
  PfnUseProgram UseProgram = nullptr;
  PfnDeleteProgram DeleteProgram = nullptr;
  PfnGetUniformLocation GetUniformLocation = nullptr;
  PfnUniform1i Uniform1i = nullptr;
  PfnUniform1f Uniform1f = nullptr;
  PfnUniform3fv Uniform3fv = nullptr;
  PfnUniform4fv Uniform4fv = nullptr;
  PfnUniformMatrix3fv UniformMatrix3fv = nullptr;
  PfnUniformMatrix4fv UniformMatrix4fv = nullptr;
  PfnGetUniformBlockIndex GetUniformBlockIndex = nullptr;
  PfnUniformBlockBinding UniformBlockBinding = nullptr;

  PfnGenFramebuffers GenFramebuffers = nullptr;
  PfnBindFramebuffer BindFramebuffer = nullptr;
  PfnDeleteFramebuffers DeleteFramebuffers = nullptr;
  PfnFramebufferTexture2D FramebufferTexture2D = nullptr;
  PfnFramebufferRenderbuffer FramebufferRenderbuffer = nullptr;
  PfnGenRenderbuffers GenRenderbuffers = nullptr;
  PfnBindRenderbuffer BindRenderbuffer = nullptr;
  PfnDeleteRenderbuffers DeleteRenderbuffers = nullptr;
  PfnRenderbufferStorage RenderbufferStorage = nullptr;
  PfnRenderbufferStorageMultisample RenderbufferStorageMultisample = nullptr;
  PfnCheckFramebufferStatus CheckFramebufferStatus = nullptr;
  PfnBlitFramebuffer BlitFramebuffer = nullptr;

  PfnActiveTexture ActiveTexture = nullptr;
  PfnGenerateMipmap Generatemipmap = nullptr;
};

// The context, the window it hangs on, and what the driver said it is.
class Context {
 public:
  // Makes the context if it can, once. Returns null when this machine has no
  // OpenGL worth using — see the note at the top of this file — and the reason
  // is then in [failure].
  static Context* Instance();

  // Why [Instance] came back null, in one line fit to show a person:
  // "OpenGL 1.1 (GDI Generic)" says everything that needs saying.
  static const std::string& failure();

  // Makes this context current on the calling thread. Every entry point below
  // is undefined until it has been.
  bool MakeCurrent();

  // What to tell the user it is drawing with: "OpenGL 4.6 · NVIDIA GeForce
  // RTX 3070".
  const std::string& description() const { return description_; }

  // How many samples a multisampled renderbuffer may have here, 1 when it may
  // not have more.
  GLsizei samples() const { return samples_; }

  const Api& api() const { return api_; }

 private:
  Context() = default;

  bool Start();

  HWND window_ = nullptr;
  HDC dc_ = nullptr;
  HGLRC context_ = nullptr;
  std::string description_;
  GLsizei samples_ = 1;
  Api api_;
};

}  // namespace gl

#endif  // RUNNER_GL_CONTEXT_H_
