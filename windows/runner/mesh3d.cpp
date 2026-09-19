#include "mesh3d.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <flutter_plugin_registrar.h>
#include <flutter_texture_registrar.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

#include "gl_context.h"

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

constexpr char kChannelName[] = "xverb/mesh3d";

// How many bones one mesh may be posed by here.
//
// A uniform block is guaranteed 16 kB and no more, and a matrix is 64 bytes, so
// 192 is what fits with room to spare. Characters in the files this was built
// for carry 60 to 100. A mesh above the line is not drawn badly — the upload is
// refused and Dart keeps that model on its own renderer, which has no such
// ceiling.
constexpr int kMaxJoints = 192;

// The three ways of looking, as `MeshLook` declares them in Dart. The index of
// the enum travels, so the order there is the order here.
constexpr int kLookShaded = 0;
constexpr int kLookWire = 1;
constexpr int kLookUnlit = 2;

// Five attributes in one buffer: position, normal, texture, the four bones that
// pull on the vertex and how hard each pulls.
constexpr GLsizei kStride = 3 * 4 + 3 * 4 + 2 * 4 + 4 * 2 + 4 * 4;  // 56

// The field of view and the framing, as `MeshCamera` has them. Both paths must
// frame a model identically or turning acceleration on would move the camera.
constexpr double kFocal = 2.414;
constexpr double kMargin = 1.06;

// No picture is ever asked of a surface bigger than this. A window can be
// dragged to the size of a wall of monitors, and the readback is per-frame.
constexpr int kMaxSurface = 4096;

const char* kModelVertex = R"(#version 330 core
layout(location = 0) in vec3 aPosition;
layout(location = 1) in vec3 aNormal;
layout(location = 2) in vec2 aTexture;
layout(location = 3) in uvec4 aJoint;
layout(location = 4) in vec4 aWeight;

// Where every bone stands this frame. The plugin bakes these row-vector, and a
// column-major `mat4` multiplied on the left reads exactly the same numbers in
// exactly the same places as `_skin` reads them in Dart — so the two paths pose
// a vertex identically, with no transposing anywhere.
layout(std140) uniform Pose {
  mat4 bone[192];
};

uniform mat4 uView;
uniform mat4 uProjection;
uniform vec3 uCentre;
uniform int uSkinned;
uniform int uJoints;

out vec3 vNormal;
out vec3 vPosition;
out vec2 vTexture;

void main() {
  vec3 position = aPosition;
  vec3 normal = aNormal;

  if (uSkinned == 1) {
    vec3 posed = vec3(0.0);
    vec3 turned = vec3(0.0);
    float total = 0.0;
    for (int slot = 0; slot < 4; ++slot) {
      float weight = aWeight[slot];
      int joint = int(aJoint[slot]);
      if (weight <= 0.0 || joint >= uJoints) continue;
      mat4 m = bone[joint];
      posed += weight * (m * vec4(aPosition, 1.0)).xyz;
      turned += weight * (mat3(m) * aNormal);
      total += weight;
    }
    // A vertex nothing pulls on stays where it was rather than collapsing to
    // the origin — the same rule the processor path has, for the same reason.
    if (total > 1e-6) {
      position = posed;
      normal = turned;
    }
  }

  vPosition = position - uCentre;
  vNormal = normal;
  vTexture = aTexture;
  gl_Position = uProjection * (uView * vec4(vPosition, 1.0));
}
)";

const char* kModelFragment = R"(#version 330 core
in vec3 vNormal;
in vec3 vPosition;
in vec2 vTexture;

out vec4 oColour;

uniform mat3 uViewNormal;
uniform vec3 uEye;
uniform vec4 uColour;
uniform int uTextured;
uniform int uLit;
uniform int uMirror;
uniform float uRoughness;
uniform float uMetallic;
uniform sampler2D uPicture;

// The lights, and they are the same three numbers the processor path is lit by:
// a key standing in the world above and to one side, a bounce from under it,
// and a weak fill riding with the camera. Solved for once, against a cube, so
// that three faces of one solid read as three planes — see `_MeshPainter`.
const vec3 kKey = vec3(-0.568, 0.770, 0.290);
const vec3 kBounce = vec3(0.501, -0.751, -0.431);
const vec3 kFill = vec3(0.87, 0.49, -0.06);
const float kKeyWeight = 0.66;
const float kBounceWeight = 0.20;
const float kFillWeight = 0.16;
const float kAmbient = 0.16;

// What the model stands in, as arithmetic rather than a picture: sky overhead,
// a bright band at the horizon, dark ground below, and the sun where the key
// light already is. No cube map, no asset, nothing to ship — and enough for a
// surface to have something to reflect, which is the whole point of it.
//
// Roughness widens every band and blunts the sun, which is what roughness does
// to a reflection.
vec3 environment(vec3 direction, float roughness) {
  float soften = mix(1.0, 0.35, roughness);
  float height = clamp(direction.y, -1.0, 1.0);
  vec3 zenith = vec3(0.42, 0.52, 0.68);
  vec3 horizon = vec3(0.62, 0.64, 0.66);
  vec3 ground = vec3(0.16, 0.15, 0.14);
  vec3 colour = height >= 0.0
      ? mix(horizon, zenith, pow(height, 0.65 * soften + 0.35))
      : mix(horizon, ground, pow(-height, 0.45 * soften + 0.35));
  float sun = pow(max(dot(direction, kKey), 0.0), mix(160.0, 8.0, roughness));
  return colour + vec3(1.0, 0.95, 0.86) * sun * mix(3.0, 0.5, roughness);
}

void main() {
  // A picture *is* the colour where there is one: multiplying it by whatever
  // grey the exporter wrote would only darken a photograph.
  vec3 base = uTextured == 1 ? texture(uPicture, vTexture).rgb : uColour.rgb;

  vec3 normal = normalize(vNormal);
  vec3 seen = uViewNormal * normal;

  // Two-sided, by turning a normal that points away back towards the eye —
  // not by dropping the sign of the dot product. A surface you can see is a
  // surface facing you; a normal that points away is one the file wrote
  // backwards, and that is all two-sidedness is for.
  float facing = seen.z <= 0.0 ? 1.0 : -1.0;
  vec3 front = normal * facing;

  // Premultiplied, because that is what the engine composites: a wireframe is
  // drawn at less than full alpha, as the painter draws it, and everything
  // else at uColour.a = 1 and so unchanged.
  if (uLit == 0) {
    oColour = vec4(base * uColour.a, uColour.a);
    return;
  }

  float key = max(dot(front, kKey), 0.0) * kKeyWeight;
  float bounce = max(dot(front, kBounce), 0.0) * kBounceWeight;
  float fill = max(dot(seen * facing, kFill), 0.0) * kFillWeight;

  vec3 ambient = uMirror == 1 ? environment(front, 1.0) * 0.30 : vec3(kAmbient);
  vec3 lit = base * (key + bounce + fill + ambient);

  if (uMirror == 1) {
    vec3 view = normalize(uEye - vPosition);
    float grazing = 1.0 - max(dot(front, view), 0.0);
    float f0 = mix(0.08, 1.0, uMetallic);
    float fresnel = f0 + (1.0 - f0) * pow(grazing, 5.0);
    // A metal is coloured by its own reflection; a dielectric reflects white.
    vec3 tint = mix(vec3(1.0), base, uMetallic);
    vec3 mirror = environment(reflect(-view, front), uRoughness) * tint;
    lit = mix(lit, mirror, clamp(fresnel * (1.0 - uRoughness * 0.5), 0.0, 1.0));

    vec3 halfway = normalize(view + kKey);
    float gloss = pow(max(dot(front, halfway), 0.0), mix(256.0, 8.0, uRoughness));
    lit += vec3(1.0, 0.96, 0.90) * gloss * (1.0 - uRoughness) * 0.8;
  }

  oColour = vec4(lit * uColour.a, uColour.a);
}
)";

const char* kLineVertex = R"(#version 330 core
layout(location = 0) in vec3 aPosition;
uniform mat4 uView;
uniform mat4 uProjection;
uniform vec3 uCentre;
void main() {
  gl_Position = uProjection * (uView * vec4(aPosition - uCentre, 1.0));
}
)";

const char* kLineFragment = R"(#version 330 core
uniform vec4 uColour;
uniform int uRound;
out vec4 oColour;
void main() {
  // A joint is a dot, and a square dot is a different thing. `gl_PointCoord`
  // is only defined while points are being drawn, hence the flag rather than
  // reading it always.
  if (uRound == 1 && length(gl_PointCoord - vec2(0.5)) > 0.5) discard;
  oColour = uColour;
}
)";

// ---------------------------------------------------------------------------
// Reading what Dart sent.
//
// Every array arrives as bytes rather than as a typed list. Dart's standard
// codec has no Uint32List and no Uint16List, and indices are the former while
// bone slots are the latter — so rather than two encodings and a conversion,
// there is one: `list.buffer.asUint8List()` on that side, a reinterpreted
// pointer on this one.
// ---------------------------------------------------------------------------

const EncodableValue* Find(const EncodableMap& map, const char* key) {
  const auto found = map.find(EncodableValue(std::string(key)));
  return found == map.end() ? nullptr : &found->second;
}

int IntOr(const EncodableMap& map, const char* key, int fallback) {
  const EncodableValue* value = Find(map, key);
  if (value == nullptr) return fallback;
  if (const auto* narrow = std::get_if<int32_t>(value)) return *narrow;
  if (const auto* large = std::get_if<int64_t>(value)) {
    return static_cast<int>(*large);
  }
  return fallback;
}

// The same, kept whole.
//
// A texture id is what the engine chose to call the texture, and on Windows it
// is a large number — 1 863 525 693 296 was the first one this ever saw. Read
// into an `int` it comes back as something else entirely and finds no model,
// which is exactly as silent as every other way this can say no.
int64_t LongOr(const EncodableMap& map, const char* key, int64_t fallback) {
  const EncodableValue* value = Find(map, key);
  if (value == nullptr) return fallback;
  if (const auto* narrow = std::get_if<int32_t>(value)) return *narrow;
  if (const auto* wide = std::get_if<int64_t>(value)) return *wide;
  return fallback;
}

double DoubleOr(const EncodableMap& map, const char* key, double fallback) {
  const EncodableValue* value = Find(map, key);
  if (value == nullptr) return fallback;
  if (const auto* real = std::get_if<double>(value)) return *real;
  if (const auto* narrow = std::get_if<int32_t>(value)) return *narrow;
  return fallback;
}

bool BoolOr(const EncodableMap& map, const char* key, bool fallback) {
  const EncodableValue* value = Find(map, key);
  if (value == nullptr) return fallback;
  const auto* flag = std::get_if<bool>(value);
  return flag == nullptr ? fallback : *flag;
}

const std::vector<uint8_t>* Bytes(const EncodableMap& map, const char* key) {
  const EncodableValue* value = Find(map, key);
  return value == nullptr ? nullptr : std::get_if<std::vector<uint8_t>>(value);
}

const EncodableList* List(const EncodableMap& map, const char* key) {
  const EncodableValue* value = Find(map, key);
  return value == nullptr ? nullptr : std::get_if<EncodableList>(value);
}

// `0xAARRGGBB` as the three numbers a shader wants, alpha dropped: nothing here
// is see-through, and a model that arrived with a transparent material would
// disappear rather than look like glass.
void Unpack(int64_t argb, float* rgba) {
  rgba[0] = static_cast<float>((argb >> 16) & 0xFF) / 255.0f;
  rgba[1] = static_cast<float>((argb >> 8) & 0xFF) / 255.0f;
  rgba[2] = static_cast<float>(argb & 0xFF) / 255.0f;
  rgba[3] = 1.0f;
}

template <typename T>
const T* As(const std::vector<uint8_t>* bytes) {
  return bytes == nullptr || bytes->empty()
             ? nullptr
             : reinterpret_cast<const T*>(bytes->data());
}

template <typename T>
size_t CountOf(const std::vector<uint8_t>* bytes) {
  return bytes == nullptr ? 0 : bytes->size() / sizeof(T);
}

// ---------------------------------------------------------------------------
// What a model is, once it is on the card.
// ---------------------------------------------------------------------------

struct Mesh {
  GLuint array = 0;    // the vertex array object
  GLuint vertices = 0;
  GLuint elements = 0;
  GLsizei indices = 0;
  int joints = 0;
  int image = -1;
  float colour[4] = {0.8f, 0.8f, 0.8f, 1.0f};
  bool tinted = false;  // whether the file said a colour at all

  // What the surface reflects with. A painted surface: rough enough that the
  // sky it takes is a wash rather than a picture, and not a metal, so what it
  // reflects is white and not its own colour.
  float roughness = 0.35f;
  float metallic = 0.0f;

  // Where the bones rest and what each hangs from, for drawing the skeleton.
  std::vector<float> bones;
  std::vector<int16_t> parents;
};

struct Clip {
  int frames = 0;
  // One track per mesh, `frames * joints * 16` floats, or empty where a mesh is
  // not animated by this clip.
  std::vector<std::vector<float>> tracks;
};

// One open model: its geometry, its pictures, and the surface it is drawn onto.
struct View {
  // The texture the engine handed out. Also names the model on this side: one
  // surface, one model, one id.
  int64_t id = 0;

  std::vector<Mesh> meshes;
  std::vector<GLuint> pictures;
  std::vector<Clip> clips;

  // Where the model sits and how big it is, measured once off the rest pose —
  // the same measurement `_Scene.of` makes, so the framing agrees.
  float centre[3] = {0.0f, 0.0f, 0.0f};
  float radius = 1.0f;

  // The surface. Multisampled where it is drawn, plain where it is read from:
  // `glReadPixels` cannot read a multisampled buffer, so the samples are
  // resolved by a blit between the two.
  int width = 0;
  int height = 0;
  GLuint sampled = 0;
  GLuint sampledColour = 0;
  GLuint sampledDepth = 0;
  GLuint flat = 0;
  GLuint flatColour = 0;

  GLuint pose = 0;   // the uniform buffer the bone matrices go in
  GLuint lines = 0;  // a buffer for the skeleton, grown as needed
  size_t lineRoom = 0;

  // The finished picture, and the one being made. Two buffers because the
  // engine reads the finished one on its raster thread while this one is drawn
  // on the platform thread.
  std::vector<uint8_t> shown;
  std::vector<uint8_t> drawing;
  std::mutex held;
  FlutterDesktopPixelBuffer descriptor{};
};

// ---------------------------------------------------------------------------
// The shared machinery: the context, two programs, and where their uniforms
// live. One of each, however many models are open.
// ---------------------------------------------------------------------------

struct Program {
  GLuint id = 0;
  std::unordered_map<std::string, GLint> places;

  GLint At(const gl::Api& api, const char* name) {
    const auto found = places.find(name);
    if (found != places.end()) return found->second;
    const GLint place = api.GetUniformLocation(id, name);
    places.emplace(name, place);
    return place;
  }
};

struct Renderer {
  gl::Context* context = nullptr;
  Program model;
  Program line;
  // The one vertex array the skeleton is drawn through. Shared, because the
  // buffer behind it is rebound per model and there is only ever one context.
  GLuint boneArray = 0;
  bool ready = false;
};

Renderer* Shared() {
  static Renderer renderer;
  return &renderer;
}

std::unordered_map<int64_t, std::unique_ptr<View>>* Views() {
  static std::unordered_map<int64_t, std::unique_ptr<View>> views;
  return &views;
}

// Where textures are registered, taken once from the engine.
//
// The C registrar rather than the C++ wrapper's: `flutter::PluginRegistrar` is
// compiled into the wrapper library plugins link and the runner does not, and
// the three calls wanted here — register, mark, unregister — are the whole of
// what that wrapper would have added.
FlutterDesktopTextureRegistrarRef* Textures() {
  static FlutterDesktopTextureRegistrarRef textures = nullptr;
  return &textures;
}

GLuint Compile(const gl::Api& api, GLenum kind, const char* source) {
  const GLuint shader = api.CreateShader(kind);
  api.ShaderSource(shader, 1, &source, nullptr);
  api.CompileShader(shader);
  GLint compiled = 0;
  api.GetShaderiv(shader, gl::kCompileStatus, &compiled);
  if (compiled == GL_TRUE) return shader;

  // A shader that will not compile is a mistake in this file, not a property
  // of the machine. It is reported by refusing acceleration rather than by
  // crashing, because the model still has a renderer to be drawn by.
  GLint length = 0;
  api.GetShaderiv(shader, gl::kInfoLogLength, &length);
  std::string log(static_cast<size_t>(length > 0 ? length : 1), '\0');
  api.GetShaderInfoLog(shader, length, nullptr, log.data());
  OutputDebugStringA(("xverb mesh3d shader: " + log + "\n").c_str());
  api.DeleteShader(shader);
  return 0;
}

bool Link(const gl::Api& api, Program* program, const char* vertex,
          const char* fragment) {
  const GLuint first = Compile(api, gl::kVertexShader, vertex);
  const GLuint second = Compile(api, gl::kFragmentShader, fragment);
  if (first == 0 || second == 0) return false;

  program->id = api.CreateProgram();
  api.AttachShader(program->id, first);
  api.AttachShader(program->id, second);
  api.LinkProgram(program->id);
  api.DeleteShader(first);
  api.DeleteShader(second);

  GLint linked = 0;
  api.GetProgramiv(program->id, gl::kLinkStatus, &linked);
  if (linked == GL_TRUE) return true;

  GLint length = 0;
  api.GetProgramiv(program->id, gl::kInfoLogLength, &length);
  std::string log(static_cast<size_t>(length > 0 ? length : 1), '\0');
  api.GetProgramInfoLog(program->id, length, nullptr, log.data());
  OutputDebugStringA(("xverb mesh3d link: " + log + "\n").c_str());
  api.DeleteProgram(program->id);
  program->id = 0;
  return false;
}

// Makes the context current and the programs, once. Every entry point here
// goes through this, and everything it touches is null until it has answered
// true.
bool Ready() {
  Renderer* shared = Shared();
  if (shared->ready) return shared->context->MakeCurrent();
  if (shared->context != nullptr) return false;  // tried, and failed

  shared->context = gl::Context::Instance();
  if (shared->context == nullptr) return false;
  if (!shared->context->MakeCurrent()) return false;

  const gl::Api& api = shared->context->api();
  if (!Link(api, &shared->model, kModelVertex, kModelFragment)) return false;
  if (!Link(api, &shared->line, kLineVertex, kLineFragment)) return false;

  // The pose block, bound where both the program and the upload agree it is.
  const GLuint block = api.GetUniformBlockIndex(shared->model.id, "Pose");
  if (block != 0xFFFFFFFFu) api.UniformBlockBinding(shared->model.id, block, 0);

  shared->ready = true;
  return true;
}

// ---------------------------------------------------------------------------
// Uploading.
// ---------------------------------------------------------------------------

// Builds the one interleaved buffer a mesh is drawn from. Separate arrays
// arrive; a single stride is what the card wants.
bool MakeMesh(const gl::Api& api, const EncodableMap& source, Mesh* mesh) {
  const std::vector<uint8_t>* positions = Bytes(source, "positions");
  const std::vector<uint8_t>* normals = Bytes(source, "normals");
  const std::vector<uint8_t>* indices = Bytes(source, "indices");
  const size_t count = CountOf<float>(positions) / 3;
  const size_t triangles = CountOf<uint32_t>(indices) / 3;
  if (count == 0 || triangles == 0) return false;
  if (CountOf<float>(normals) / 3 < count) return false;

  const std::vector<uint8_t>* uvs = Bytes(source, "uvs");
  const std::vector<uint8_t>* slots = Bytes(source, "jointIndices");
  const std::vector<uint8_t>* weights = Bytes(source, "jointWeights");

  const float* position = As<float>(positions);
  const float* normal = As<float>(normals);
  const float* uv = CountOf<float>(uvs) >= count * 2 ? As<float>(uvs) : nullptr;
  const uint16_t* slot =
      CountOf<uint16_t>(slots) >= count * 4 ? As<uint16_t>(slots) : nullptr;
  const float* weight =
      CountOf<float>(weights) >= count * 4 ? As<float>(weights) : nullptr;

  mesh->joints = IntOr(source, "joints", 0);
  if (mesh->joints > kMaxJoints) return false;
  if (slot == nullptr || weight == nullptr) mesh->joints = 0;

  std::vector<uint8_t> packed(count * kStride);
  for (size_t v = 0; v < count; ++v) {
    uint8_t* at = packed.data() + v * kStride;
    std::memcpy(at, position + v * 3, 12);
    std::memcpy(at + 12, normal + v * 3, 12);
    if (uv != nullptr) {
      std::memcpy(at + 24, uv + v * 2, 8);
    } else {
      std::memset(at + 24, 0, 8);
    }
    if (slot != nullptr) {
      std::memcpy(at + 32, slot + v * 4, 8);
      std::memcpy(at + 40, weight + v * 4, 16);
    } else {
      std::memset(at + 32, 0, 24);
    }
  }

  api.GenVertexArrays(1, &mesh->array);
  api.BindVertexArray(mesh->array);

  api.GenBuffers(1, &mesh->vertices);
  api.BindBuffer(gl::kArrayBuffer, mesh->vertices);
  api.BufferData(gl::kArrayBuffer, static_cast<gl::GLsizeiptr>(packed.size()),
                 packed.data(), gl::kStaticDraw);

  api.EnableVertexAttribArray(0);
  api.VertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, kStride, nullptr);
  api.EnableVertexAttribArray(1);
  api.VertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, kStride,
                          reinterpret_cast<const void*>(12));
  api.EnableVertexAttribArray(2);
  api.VertexAttribPointer(2, 2, GL_FLOAT, GL_FALSE, kStride,
                          reinterpret_cast<const void*>(24));
  api.EnableVertexAttribArray(3);
  api.VertexAttribIPointer(3, 4, GL_UNSIGNED_SHORT, kStride,
                           reinterpret_cast<const void*>(32));
  api.EnableVertexAttribArray(4);
  api.VertexAttribPointer(4, 4, GL_FLOAT, GL_FALSE, kStride,
                          reinterpret_cast<const void*>(40));

  api.GenBuffers(1, &mesh->elements);
  api.BindBuffer(gl::kElementArrayBuffer, mesh->elements);
  api.BufferData(gl::kElementArrayBuffer,
                 static_cast<gl::GLsizeiptr>(triangles * 3 * sizeof(uint32_t)),
                 As<uint32_t>(indices), gl::kStaticDraw);
  api.BindVertexArray(0);

  mesh->indices = static_cast<GLsizei>(triangles * 3);
  mesh->image = IntOr(source, "image", -1);
  if (uv == nullptr) mesh->image = -1;

  // Already what it will be shown as: Dart lifted it, by the painter's rule,
  // before sending it. Absent means the file named no colour and the theme's
  // stands in — and that one arrives per frame, because a theme can change
  // under an open model.
  const EncodableValue* tint = Find(source, "color");
  if (tint != nullptr && !std::holds_alternative<std::monostate>(*tint)) {
    Unpack(LongOr(source, "color", 0), mesh->colour);
    mesh->tinted = true;
  }
  // How rough and how metallic the surface is stays at what [Mesh] declares:
  // a painted surface, which is what most of a model is. The contract has no
  // room to say otherwise yet, and a field read from a payload nothing sends
  // is a field that only looks like a feature — when a plugin can name a
  // material, it goes here.

  const std::vector<uint8_t>* rest = Bytes(source, "bones");
  const std::vector<uint8_t>* parents = Bytes(source, "boneParents");
  if (rest != nullptr && parents != nullptr) {
    mesh->bones.assign(As<float>(rest),
                       As<float>(rest) + CountOf<float>(rest));
    mesh->parents.assign(As<int16_t>(parents),
                         As<int16_t>(parents) + CountOf<int16_t>(parents));
  }
  return true;
}

GLuint MakePicture(const gl::Api& api, const EncodableMap& source) {
  const int width = IntOr(source, "width", 0);
  const int height = IntOr(source, "height", 0);
  const std::vector<uint8_t>* pixels = Bytes(source, "pixels");
  if (width <= 0 || height <= 0 || pixels == nullptr) return 0;
  if (pixels->size() < static_cast<size_t>(width) * height * 4) return 0;

  GLuint texture = 0;
  glGenTextures(1, &texture);
  glBindTexture(GL_TEXTURE_2D, texture);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA,
               GL_UNSIGNED_BYTE, pixels->data());
  // Repeated, as the processor path repeats it, and mipmapped because a model
  // seen small reads a texture at a hundredth of its size.
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_REPEAT);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_REPEAT);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER,
                  GL_LINEAR_MIPMAP_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  api.Generatemipmap(GL_TEXTURE_2D);
  glBindTexture(GL_TEXTURE_2D, 0);
  return texture;
}

// The bounding sphere of the rest pose, measured the way `_Scene.of` measures
// it: the middle of the box, and half its diagonal.
void Measure(const EncodableList& meshes, View* view) {
  float least[3] = {HUGE_VALF, HUGE_VALF, HUGE_VALF};
  float most[3] = {-HUGE_VALF, -HUGE_VALF, -HUGE_VALF};
  bool any = false;

  for (const EncodableValue& entry : meshes) {
    const auto* source = std::get_if<EncodableMap>(&entry);
    if (source == nullptr) continue;
    const std::vector<uint8_t>* positions = Bytes(*source, "positions");
    const float* position = As<float>(positions);
    const size_t count = CountOf<float>(positions) / 3;
    for (size_t v = 0; v < count; ++v) {
      for (int axis = 0; axis < 3; ++axis) {
        const float value = position[v * 3 + axis];
        least[axis] = std::min(least[axis], value);
        most[axis] = std::max(most[axis], value);
      }
      any = true;
    }
  }

  if (!any) return;
  double diagonal = 0;
  for (int axis = 0; axis < 3; ++axis) {
    view->centre[axis] = (least[axis] + most[axis]) / 2;
    const double side = most[axis] - least[axis];
    diagonal += side * side;
  }
  view->radius = static_cast<float>(std::max(1e-6, 0.5 * std::sqrt(diagonal)));
}

// ---------------------------------------------------------------------------
// The surface.
// ---------------------------------------------------------------------------

void ForgetSurface(const gl::Api& api, View* view) {
  if (view->sampled != 0) api.DeleteFramebuffers(1, &view->sampled);
  if (view->flat != 0) api.DeleteFramebuffers(1, &view->flat);
  if (view->sampledColour != 0) {
    api.DeleteRenderbuffers(1, &view->sampledColour);
  }
  if (view->sampledDepth != 0) api.DeleteRenderbuffers(1, &view->sampledDepth);
  if (view->flatColour != 0) glDeleteTextures(1, &view->flatColour);
  view->sampled = view->flat = 0;
  view->sampledColour = view->sampledDepth = view->flatColour = 0;
  view->width = view->height = 0;
}

bool Resize(const gl::Api& api, View* view, int width, int height) {
  if (view->width == width && view->height == height) return true;
  ForgetSurface(api, view);

  const GLsizei samples = Shared()->context->samples();

  api.GenFramebuffers(1, &view->sampled);
  api.BindFramebuffer(gl::kFramebuffer, view->sampled);
  api.GenRenderbuffers(1, &view->sampledColour);
  api.BindRenderbuffer(gl::kRenderbuffer, view->sampledColour);
  if (samples > 1) {
    api.RenderbufferStorageMultisample(gl::kRenderbuffer, samples, gl::kRgba8,
                                       width, height);
  } else {
    api.RenderbufferStorage(gl::kRenderbuffer, gl::kRgba8, width, height);
  }
  api.FramebufferRenderbuffer(gl::kFramebuffer, gl::kColorAttachment0,
                              gl::kRenderbuffer, view->sampledColour);
  api.GenRenderbuffers(1, &view->sampledDepth);
  api.BindRenderbuffer(gl::kRenderbuffer, view->sampledDepth);
  if (samples > 1) {
    api.RenderbufferStorageMultisample(gl::kRenderbuffer, samples,
                                       gl::kDepthComponent24, width, height);
  } else {
    api.RenderbufferStorage(gl::kRenderbuffer, gl::kDepthComponent24, width,
                            height);
  }
  api.FramebufferRenderbuffer(gl::kFramebuffer, gl::kDepthAttachment,
                              gl::kRenderbuffer, view->sampledDepth);
  if (api.CheckFramebufferStatus(gl::kFramebuffer) != gl::kFramebufferComplete) {
    ForgetSurface(api, view);
    return false;
  }

  api.GenFramebuffers(1, &view->flat);
  api.BindFramebuffer(gl::kFramebuffer, view->flat);
  glGenTextures(1, &view->flatColour);
  glBindTexture(GL_TEXTURE_2D, view->flatColour);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA,
               GL_UNSIGNED_BYTE, nullptr);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  api.FramebufferTexture2D(gl::kFramebuffer, gl::kColorAttachment0,
                           GL_TEXTURE_2D, view->flatColour, 0);
  if (api.CheckFramebufferStatus(gl::kFramebuffer) != gl::kFramebufferComplete) {
    ForgetSurface(api, view);
    return false;
  }
  api.BindFramebuffer(gl::kFramebuffer, 0);

  view->width = width;
  view->height = height;
  view->drawing.assign(static_cast<size_t>(width) * height * 4, 0);
  {
    const std::lock_guard<std::mutex> hold(view->held);
    view->shown.assign(static_cast<size_t>(width) * height * 4, 0);
  }
  return true;
}

// ---------------------------------------------------------------------------
// The camera, which is `MeshCamera` and `_MeshPainter` written as matrices.
// ---------------------------------------------------------------------------

struct Camera {
  float view[16] = {};
  float normal[9] = {};
  float projection[16] = {};
  float eye[3] = {};
  double distance = 1;
};

Camera Look(const View& view, double yaw, double pitch, double zoom,
            double panX, double panY, int width, int height) {
  Camera camera;
  const double cosYaw = std::cos(yaw);
  const double sinYaw = std::sin(yaw);
  const double cosPitch = std::cos(pitch);
  const double sinPitch = std::sin(pitch);

  // The sphere of radius r fits inside a cone of half-angle θ only from
  // `r / sin θ` away, so the framing and the field of view are one number —
  // `MeshCamera.distanceFor`.
  camera.distance = view.radius * std::sqrt(1 + kFocal * kFocal) * kMargin /
                    std::max(zoom, 1e-6);

  // Across the screen, up it, and away from the eye: the three rows are
  // `MeshCamera.look` with the terms multiplied out.
  const double rows[3][3] = {
      {cosYaw, 0.0, sinYaw},
      {sinPitch * sinYaw, cosPitch, -sinPitch * cosYaw},
      {cosPitch * sinYaw, -sinPitch, -cosPitch * cosYaw},
  };
  for (int column = 0; column < 3; ++column) {
    for (int row = 0; row < 3; ++row) {
      camera.view[column * 4 + row] = static_cast<float>(rows[row][column]);
      camera.normal[column * 3 + row] = static_cast<float>(rows[row][column]);
    }
    camera.view[column * 4 + 3] = 0.0f;
  }
  camera.view[12] = 0.0f;
  camera.view[13] = 0.0f;
  camera.view[14] = static_cast<float>(camera.distance);
  camera.view[15] = 1.0f;

  // And the eye itself, in the space the vertices are handed over in.
  camera.eye[0] = static_cast<float>(-sinYaw * cosPitch * camera.distance);
  camera.eye[1] = static_cast<float>(sinPitch * camera.distance);
  camera.eye[2] = static_cast<float>(cosYaw * cosPitch * camera.distance);

  // The projection is the divide `_MeshPainter` does by hand, plus the pan it
  // adds afterwards: a pan is a shift in screen pixels, which in clip space is
  // a term proportional to depth.
  const double scale = std::min(width, height) / 2.0 * kFocal;
  const double nearPlane = std::max(1e-6, view.radius * 0.02);
  const double farPlane = camera.distance + view.radius * 3.0;
  camera.projection[0] = static_cast<float>(2 * scale / width);
  camera.projection[8] = static_cast<float>(2 * panX / width);

  // Upside down, deliberately.
  //
  // `glReadPixels` hands back the bottom row first — a framebuffer's origin is
  // its bottom left corner — and the engine wants the top row first. Turning
  // the picture over afterwards is a pass over every pixel; turning it over in
  // the blit is not allowed, because a multisampled source may be resolved but
  // never flipped; so it is turned over here, where it costs a minus sign.
  // Nothing downstream notices: winding is not read, both sides of every
  // triangle are drawn, and no shader here asks where on the screen it is.
  camera.projection[5] = static_cast<float>(-2 * scale / height);
  camera.projection[9] = static_cast<float>(2 * panY / height);
  camera.projection[10] = static_cast<float>((farPlane + nearPlane) / (farPlane - nearPlane));
  camera.projection[11] = 1.0f;
  camera.projection[14] = static_cast<float>(-2 * farPlane * nearPlane / (farPlane - nearPlane));
  return camera;
}

// Where a bone stands this frame: its resting place moved by its own matrix,
// which is one vertex with one bone pulling on it at full weight. The same
// arithmetic as `_poseBones`.
void PoseBones(const Mesh& mesh, const float* track, size_t length,
               std::vector<float>* out) {
  out->assign(mesh.bones.begin(), mesh.bones.end());
  if (track == nullptr) return;
  const size_t bones = mesh.bones.size() / 3;
  for (size_t b = 0; b < bones; ++b) {
    if (static_cast<int>(b) >= mesh.joints) continue;
    const size_t m = b * 16;
    if (m + 15 >= length) continue;
    const float x = mesh.bones[b * 3];
    const float y = mesh.bones[b * 3 + 1];
    const float z = mesh.bones[b * 3 + 2];
    (*out)[b * 3] =
        track[m] * x + track[m + 4] * y + track[m + 8] * z + track[m + 12];
    (*out)[b * 3 + 1] = track[m + 1] * x + track[m + 5] * y +
                        track[m + 9] * z + track[m + 13];
    (*out)[b * 3 + 2] = track[m + 2] * x + track[m + 6] * y +
                        track[m + 10] * z + track[m + 14];
  }
}

// ---------------------------------------------------------------------------
// One frame.
// ---------------------------------------------------------------------------

bool Draw(View* view, const EncodableMap& call) {
  Renderer* shared = Shared();
  const gl::Api& api = shared->context->api();

  const int width = std::clamp(IntOr(call, "width", 0), 1, kMaxSurface);
  const int height = std::clamp(IntOr(call, "height", 0), 1, kMaxSurface);
  if (!Resize(api, view, width, height)) return false;

  const int look = IntOr(call, "look", kLookShaded);
  const bool skeleton = BoolOr(call, "skeleton", false);
  const bool mirror = BoolOr(call, "reflections", true);
  const int which = IntOr(call, "clip", -1);
  const int frame = IntOr(call, "frame", 0);

  const Camera camera =
      Look(*view, DoubleOr(call, "yaw", 0), DoubleOr(call, "pitch", 0),
           DoubleOr(call, "zoom", 1), DoubleOr(call, "panX", 0),
           DoubleOr(call, "panY", 0), width, height);

  const Clip* clip = which >= 0 && which < static_cast<int>(view->clips.size())
                         ? &view->clips[which]
                         : nullptr;

  api.BindFramebuffer(gl::kFramebuffer, view->sampled);
  glViewport(0, 0, width, height);
  // Cleared to nothing at all, so the theme's own surface stays behind the
  // model exactly as it does under the processor path.
  glClearColor(0.0f, 0.0f, 0.0f, 0.0f);
  glClearDepth(1.0);
  glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
  if (shared->context->samples() > 1) glEnable(gl::kMultisample);

  // Both sides of every triangle, because the lighting is two-sided and a
  // model straight out of a file is not reliably wound. What made the far side
  // worth dropping on the processor path was the absence of a depth buffer;
  // there is one here.
  glDisable(GL_CULL_FACE);
  if (look == kLookWire) {
    // A wireframe is see-through, which is what it is for.
    glDisable(GL_DEPTH_TEST);
    glPolygonMode(GL_FRONT_AND_BACK, GL_LINE);
  } else {
    glEnable(GL_DEPTH_TEST);
    glDepthFunc(GL_LESS);
    glPolygonMode(GL_FRONT_AND_BACK, GL_FILL);
  }

  Program& program = shared->model;
  api.UseProgram(program.id);
  api.UniformMatrix4fv(program.At(api, "uView"), 1, GL_FALSE, camera.view);
  api.UniformMatrix4fv(program.At(api, "uProjection"), 1, GL_FALSE,
                       camera.projection);
  api.UniformMatrix3fv(program.At(api, "uViewNormal"), 1, GL_FALSE,
                       camera.normal);
  api.Uniform3fv(program.At(api, "uCentre"), 1, view->centre);
  api.Uniform3fv(program.At(api, "uEye"), 1, camera.eye);
  // A wireframe is flat, not lit: the painter draws its lines in one colour at
  // seven tenths, and a lit wireframe is a different picture.
  api.Uniform1i(program.At(api, "uLit"),
                look == kLookUnlit || look == kLookWire ? 0 : 1);
  api.Uniform1i(program.At(api, "uMirror"), mirror && look == kLookShaded);
  api.Uniform1i(program.At(api, "uPicture"), 0);
  api.BindBufferBase(gl::kUniformBuffer, 0, view->pose);

  // What a mesh whose file named no colour is drawn in, and what a wireframe
  // is drawn in: the theme's, as the painter has it.
  float fallback[4] = {0.55f, 0.68f, 0.95f, 1.0f};
  Unpack(LongOr(call, "fallback", 0xFF8CADF2), fallback);
  float wire[4] = {fallback[0], fallback[1], fallback[2], 0.7f};

  for (size_t index = 0; index < view->meshes.size(); ++index) {
    Mesh& mesh = view->meshes[index];
    const float* track = nullptr;
    size_t length = 0;
    if (clip != nullptr && index < clip->tracks.size() && mesh.joints > 0 &&
        !clip->tracks[index].empty()) {
      const std::vector<float>& whole = clip->tracks[index];
      const size_t stride = static_cast<size_t>(mesh.joints) * 16;
      const size_t at = static_cast<size_t>(std::clamp(
                            frame, 0, std::max(0, clip->frames - 1))) *
                        stride;
      if (at + stride <= whole.size()) {
        track = whole.data() + at;
        length = stride;
      }
    }

    if (track != nullptr) {
      api.BindBuffer(gl::kUniformBuffer, view->pose);
      api.BufferSubData(gl::kUniformBuffer, 0,
                        static_cast<gl::GLsizeiptr>(length * sizeof(float)),
                        track);
    }
    api.Uniform1i(program.At(api, "uSkinned"), track != nullptr ? 1 : 0);
    api.Uniform1i(program.At(api, "uJoints"), mesh.joints);

    const bool painted = look != kLookWire && mesh.image >= 0 &&
                         mesh.image < static_cast<int>(view->pictures.size()) &&
                         view->pictures[mesh.image] != 0;
    api.Uniform1i(program.At(api, "uTextured"), painted ? 1 : 0);
    api.Uniform4fv(
        program.At(api, "uColour"), 1,
        look == kLookWire ? wire : (mesh.tinted ? mesh.colour : fallback));
    api.Uniform1f(program.At(api, "uRoughness"), mesh.roughness);
    api.Uniform1f(program.At(api, "uMetallic"), mesh.metallic);
    if (painted) {
      api.ActiveTexture(gl::kTexture0);
      glBindTexture(GL_TEXTURE_2D, view->pictures[mesh.image]);
    }

    api.BindVertexArray(mesh.array);
    glDrawElements(GL_TRIANGLES, mesh.indices, GL_UNSIGNED_INT, nullptr);
  }
  api.BindVertexArray(0);
  glPolygonMode(GL_FRONT_AND_BACK, GL_FILL);

  // The skeleton, over everything and with no depth test of its own: a rig
  // half hidden inside its own model answers neither question anybody opens it
  // for.
  if (skeleton) {
    // A bone is a line to the bone it hangs from and a dot where it sits. Both
    // go in one buffer — the lines first, then every joint — so it is one
    // upload and two draws.
    std::vector<float> segments;
    std::vector<float> joints;
    std::vector<float> posed;
    for (size_t index = 0; index < view->meshes.size(); ++index) {
      const Mesh& mesh = view->meshes[index];
      if (mesh.parents.empty() || mesh.bones.empty()) continue;
      const float* track = nullptr;
      size_t length = 0;
      if (clip != nullptr && index < clip->tracks.size() && mesh.joints > 0 &&
          !clip->tracks[index].empty()) {
        const std::vector<float>& whole = clip->tracks[index];
        const size_t stride = static_cast<size_t>(mesh.joints) * 16;
        const size_t at = static_cast<size_t>(std::clamp(
                              frame, 0, std::max(0, clip->frames - 1))) *
                          stride;
        if (at + stride <= whole.size()) {
          track = whole.data() + at;
          length = stride;
        }
      }
      PoseBones(mesh, track, length, &posed);
      for (size_t bone = 0; bone < mesh.parents.size(); ++bone) {
        if (bone * 3 + 2 >= posed.size()) continue;
        for (int axis = 0; axis < 3; ++axis) {
          joints.push_back(posed[bone * 3 + axis]);
        }
        const int parent = mesh.parents[bone];
        if (parent < 0 || parent >= static_cast<int>(mesh.parents.size())) {
          continue;
        }
        if (static_cast<size_t>(parent) * 3 + 2 >= posed.size()) continue;
        for (int axis = 0; axis < 3; ++axis) {
          segments.push_back(posed[parent * 3 + axis]);
        }
        for (int axis = 0; axis < 3; ++axis) {
          segments.push_back(posed[bone * 3 + axis]);
        }
      }
    }

    segments.insert(segments.end(), joints.begin(), joints.end());
    if (!segments.empty()) {
      if (view->lines == 0) api.GenBuffers(1, &view->lines);
      api.BindBuffer(gl::kArrayBuffer, view->lines);
      if (segments.size() > view->lineRoom) {
        api.BufferData(gl::kArrayBuffer,
                       static_cast<gl::GLsizeiptr>(segments.size() * 4),
                       segments.data(), gl::kDynamicDraw);
        view->lineRoom = segments.size();
      } else {
        api.BufferSubData(gl::kArrayBuffer, 0,
                          static_cast<gl::GLsizeiptr>(segments.size() * 4),
                          segments.data());
      }

      if (shared->boneArray == 0) api.GenVertexArrays(1, &shared->boneArray);
      api.BindVertexArray(shared->boneArray);
      api.BindBuffer(gl::kArrayBuffer, view->lines);
      api.EnableVertexAttribArray(0);
      api.VertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 12, nullptr);

      Program& lines = shared->line;
      api.UseProgram(lines.id);
      api.UniformMatrix4fv(lines.At(api, "uView"), 1, GL_FALSE, camera.view);
      api.UniformMatrix4fv(lines.At(api, "uProjection"), 1, GL_FALSE,
                           camera.projection);
      api.Uniform3fv(lines.At(api, "uCentre"), 1, view->centre);
      glDisable(GL_DEPTH_TEST);

      const size_t lineCount = (segments.size() - joints.size()) / 3;
      if (lineCount > 0) {
        const float bone[4] = {0.0f, 0.898f, 1.0f, 1.0f};
        api.Uniform4fv(lines.At(api, "uColour"), 1, bone);
        api.Uniform1i(lines.At(api, "uRound"), 0);
        glLineWidth(1.6f);
        glDrawArrays(GL_LINES, 0, static_cast<GLsizei>(lineCount));
      }
      if (!joints.empty()) {
        const float joint[4] = {1.0f, 0.769f, 0.0f, 1.0f};
        api.Uniform4fv(lines.At(api, "uColour"), 1, joint);
        api.Uniform1i(lines.At(api, "uRound"), 1);
        glPointSize(4.4f);
        glDrawArrays(GL_POINTS, static_cast<GLint>(lineCount),
                     static_cast<GLsizei>(joints.size() / 3));
      }
      api.BindVertexArray(0);
    }
  }

  // Resolve the samples, then read. `glReadPixels` cannot see a multisampled
  // buffer, and it is the one copy this arrangement pays: the engine takes a
  // pixel buffer on Windows, not a GL texture. A shared DXGI surface would
  // remove it, and can be added behind this same call.
  api.BindFramebuffer(gl::kReadFramebuffer, view->sampled);
  api.BindFramebuffer(gl::kDrawFramebuffer, view->flat);
  api.BlitFramebuffer(0, 0, width, height, 0, 0, width, height,
                      GL_COLOR_BUFFER_BIT, GL_NEAREST);

  api.BindFramebuffer(gl::kReadFramebuffer, view->flat);
  glPixelStorei(GL_PACK_ALIGNMENT, 1);
  glReadPixels(0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE,
               view->drawing.data());
  api.BindFramebuffer(gl::kFramebuffer, 0);

  {
    const std::lock_guard<std::mutex> hold(view->held);
    view->shown.swap(view->drawing);
  }
  return true;
}

// ---------------------------------------------------------------------------
// The channel.
// ---------------------------------------------------------------------------

View* Which(const EncodableMap& call) {
  const auto found = Views()->find(LongOr(call, "view", -1));
  return found == Views()->end() ? nullptr : found->second.get();
}

void Forget(View* view) {
  if (!Ready()) return;
  const gl::Api& api = Shared()->context->api();
  for (Mesh& mesh : view->meshes) {
    if (mesh.array != 0) api.DeleteVertexArrays(1, &mesh.array);
    if (mesh.vertices != 0) api.DeleteBuffers(1, &mesh.vertices);
    if (mesh.elements != 0) api.DeleteBuffers(1, &mesh.elements);
  }
  view->meshes.clear();
  for (GLuint picture : view->pictures) {
    if (picture != 0) glDeleteTextures(1, &picture);
  }
  view->pictures.clear();
  view->clips.clear();
}

void Handle(const flutter::MethodCall<EncodableValue>& call,
            std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const std::string& name = call.method_name();
  const auto* arguments = std::get_if<EncodableMap>(call.arguments());

  if (name == "probe") {
    const bool ready = Ready();
    EncodableMap answer{
        {EncodableValue("available"), EncodableValue(ready)},
        {EncodableValue("renderer"),
         EncodableValue(ready ? Shared()->context->description()
                              : std::string())},
        {EncodableValue("reason"),
         EncodableValue(ready ? std::string() : gl::Context::failure())},
    };
    result->Success(EncodableValue(answer));
    return;
  }

  if (!Ready()) {
    result->Success(EncodableValue(false));
    return;
  }

  if (name == "create") {
    auto view = std::make_unique<View>();
    View* raw = view.get();
    const gl::Api& api = Shared()->context->api();
    api.GenBuffers(1, &raw->pose);
    api.BindBuffer(gl::kUniformBuffer, raw->pose);
    api.BufferData(gl::kUniformBuffer, kMaxJoints * 64, nullptr,
                   gl::kDynamicDraw);

    FlutterDesktopTextureInfo info{};
    info.type = kFlutterDesktopPixelBufferTexture;
    info.pixel_buffer_config.user_data = raw;
    info.pixel_buffer_config.callback =
        [](size_t, size_t, void* user_data) -> const FlutterDesktopPixelBuffer* {
      View* view = static_cast<View*>(user_data);
      // Locked here and unlocked when the engine says it has finished with the
      // buffer. That is the whole of the synchronisation: the platform thread
      // draws and swaps, the raster thread reads.
      view->held.lock();
      // Asked for before the first frame was drawn. There is nothing to hand
      // over, and the lock must not be held out of the door.
      if (view->shown.empty() || view->width <= 0) {
        view->held.unlock();
        return nullptr;
      }
      view->descriptor.buffer = view->shown.data();
      view->descriptor.width = static_cast<size_t>(view->width);
      view->descriptor.height = static_cast<size_t>(view->height);
      view->descriptor.release_context = view;
      view->descriptor.release_callback = [](void* context) {
        static_cast<View*>(context)->held.unlock();
      };
      return &view->descriptor;
    };
    raw->id = FlutterDesktopTextureRegistrarRegisterExternalTexture(*Textures(),
                                                                   &info);
    Views()->emplace(raw->id, std::move(view));
    result->Success(EncodableValue(raw->id));
    return;
  }

  if (arguments == nullptr) {
    result->Success(EncodableValue(false));
    return;
  }
  View* view = Which(*arguments);
  if (view == nullptr) {
    result->Success(EncodableValue(false));
    return;
  }

  if (name == "upload") {
    Forget(view);
    const gl::Api& api = Shared()->context->api();
    const EncodableList* meshes = List(*arguments, "meshes");
    if (meshes == nullptr || meshes->empty()) {
      result->Success(EncodableValue(false));
      return;
    }

    if (const EncodableList* pictures = List(*arguments, "images")) {
      for (const EncodableValue& entry : *pictures) {
        const auto* source = std::get_if<EncodableMap>(&entry);
        view->pictures.push_back(source == nullptr ? 0
                                                   : MakePicture(api, *source));
      }
    }

    for (const EncodableValue& entry : *meshes) {
      const auto* source = std::get_if<EncodableMap>(&entry);
      Mesh mesh;
      if (source == nullptr || !MakeMesh(api, *source, &mesh)) {
        // One mesh this side cannot hold means the model is not this side's to
        // draw. Half a model is worse than the renderer that draws all of it.
        Forget(view);
        result->Success(EncodableValue(false));
        return;
      }
      view->meshes.push_back(std::move(mesh));
    }
    Measure(*meshes, view);
    result->Success(EncodableValue(true));
    return;
  }

  if (name == "clips") {
    view->clips.clear();
    if (const EncodableList* clips = List(*arguments, "clips")) {
      for (const EncodableValue& entry : *clips) {
        const auto* source = std::get_if<EncodableMap>(&entry);
        if (source == nullptr) continue;
        Clip clip;
        clip.frames = IntOr(*source, "frames", 0);
        if (const EncodableList* tracks = List(*source, "tracks")) {
          for (const EncodableValue& track : *tracks) {
            const auto* bytes = std::get_if<std::vector<uint8_t>>(&track);
            if (bytes == nullptr || bytes->empty()) {
              clip.tracks.emplace_back();
              continue;
            }
            const float* values = reinterpret_cast<const float*>(bytes->data());
            clip.tracks.emplace_back(values,
                                     values + bytes->size() / sizeof(float));
          }
        }
        view->clips.push_back(std::move(clip));
      }
    }
    result->Success(EncodableValue(true));
    return;
  }

  if (name == "frame") {
    if (view->meshes.empty() || !Shared()->context->MakeCurrent()) {
      result->Success(EncodableValue(false));
      return;
    }
    const bool drawn = Draw(view, *arguments);
    if (drawn) {
      FlutterDesktopTextureRegistrarMarkExternalTextureFrameAvailable(
          *Textures(), view->id);
    }
    result->Success(EncodableValue(drawn));
    return;
  }

  if (name == "dispose") {
    Forget(view);
    const gl::Api& api = Shared()->context->api();
    ForgetSurface(api, view);
    if (view->pose != 0) api.DeleteBuffers(1, &view->pose);
    if (view->lines != 0) api.DeleteBuffers(1, &view->lines);
    // Unregistered first and forgotten afterwards: the raster thread may be
    // inside the callback this moment, and the buffer it is reading belongs to
    // the object about to go.
    FlutterDesktopTextureRegistrarUnregisterExternalTexture(
        *Textures(), view->id,
        [](void* context) {
          Views()->erase(reinterpret_cast<int64_t>(context));
        },
        reinterpret_cast<void*>(view->id));
    result->Success(EncodableValue(true));
    return;
  }

  result->NotImplemented();
}

std::unique_ptr<flutter::MethodChannel<EncodableValue>> g_channel;

}  // namespace

void RegisterMesh3dChannel(flutter::FlutterEngine* engine) {
  *Textures() = FlutterDesktopRegistrarGetTextureRegistrar(
      engine->GetRegistrarForPlugin("xverb.mesh3d"));

  g_channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      engine->messenger(), kChannelName,
      &flutter::StandardMethodCodec::GetInstance());
  g_channel->SetMethodCallHandler(
      [](const flutter::MethodCall<EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        Handle(call, std::move(result));
      });
}
