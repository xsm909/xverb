#include "audio.h"

#include <algorithm>
#include <cmath>
#include <string>
#include <vector>

#ifdef XVERB_HAS_GSTREAMER
#include <glib/gstdio.h>
#include <gst/app/gstappsink.h>
#include <gst/gst.h>
#include <gst/pbutils/pbutils.h>
#endif

namespace {

constexpr char kChannelName[] = "xverb/audio";
constexpr char kTicksName[] = "xverb/audio/ticks";

// Ten a second, as on the other two. Often enough to keep the drawing's own
// clock honest, rare enough to cost nothing.
constexpr guint kTickMs = 100;

FlMethodChannel* g_channel = nullptr;
FlEventChannel* g_ticks = nullptr;
bool g_listening = false;

// The application's own volume, never the system's mixer. Kept here so a file
// opened after a change is played at the volume that was set.
double g_volume = 0.7;

FlValue* string_arg(FlValue* args, const char* name) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return nullptr;
  }
  return fl_value_lookup_string(args, name);
}

std::string text_arg(FlValue* args, const char* name) {
  FlValue* value = string_arg(args, name);
  if (value == nullptr || fl_value_get_type(value) != FL_VALUE_TYPE_STRING) {
    return std::string();
  }
  return std::string(fl_value_get_string(value));
}

int64_t number_arg(FlValue* args, const char* name, int64_t fallback) {
  FlValue* value = string_arg(args, name);
  if (value == nullptr) return fallback;
  switch (fl_value_get_type(value)) {
    case FL_VALUE_TYPE_INT:
      return fl_value_get_int(value);
    case FL_VALUE_TYPE_FLOAT:
      return static_cast<int64_t>(fl_value_get_float(value));
    default:
      return fallback;
  }
}

double float_arg(FlValue* args, const char* name, double fallback) {
  FlValue* value = string_arg(args, name);
  if (value == nullptr) return fallback;
  switch (fl_value_get_type(value)) {
    case FL_VALUE_TYPE_FLOAT:
      return fl_value_get_float(value);
    case FL_VALUE_TYPE_INT:
      return static_cast<double>(fl_value_get_int(value));
    default:
      return fallback;
  }
}

#ifdef XVERB_HAS_GSTREAMER

GstElement* g_player = nullptr;
guint g_tick_source = 0;
bool g_ended = false;

// -- what is playing, and where it has got to -------------------------------

void stop_ticking() {
  if (g_tick_source != 0) {
    g_source_remove(g_tick_source);
    g_tick_source = 0;
  }
}

/// Whatever the bus has to say, read where the answer can be used rather than
/// on GStreamer's own thread: end of stream and failure both end the playing.
void drain_bus() {
  if (g_player == nullptr) return;
  GstBus* bus = gst_element_get_bus(g_player);
  if (bus == nullptr) return;
  while (GstMessage* message = gst_bus_pop_filtered(
             bus, static_cast<GstMessageType>(GST_MESSAGE_EOS |
                                              GST_MESSAGE_ERROR))) {
    g_ended = true;
    gst_message_unref(message);
  }
  gst_object_unref(bus);
}

gint64 position_ms() {
  gint64 at = 0;
  if (g_player != nullptr &&
      gst_element_query_position(g_player, GST_FORMAT_TIME, &at)) {
    return at / GST_MSECOND;
  }
  return 0;
}

bool is_playing() {
  if (g_player == nullptr || g_ended) return false;
  GstState state = GST_STATE_NULL;
  gst_element_get_state(g_player, &state, nullptr, 0);
  return state == GST_STATE_PLAYING;
}

void send_tick() {
  if (!g_listening || g_ticks == nullptr) return;
  drain_bus();
  g_autoptr(FlValue) tick = fl_value_new_map();
  fl_value_set_string_take(tick, "positionMs", fl_value_new_int(position_ms()));
  fl_value_set_string_take(tick, "playing", fl_value_new_bool(is_playing()));
  fl_value_set_string_take(tick, "ended", fl_value_new_bool(g_ended));
  fl_event_channel_send(g_ticks, tick, nullptr, nullptr);
  if (g_ended) stop_ticking();
}

gboolean on_tick(gpointer) {
  send_tick();
  return G_SOURCE_CONTINUE;
}

void start_ticking() {
  if (g_tick_source == 0) {
    g_tick_source = g_timeout_add(kTickMs, on_tick, nullptr);
  }
}

// -- opening ----------------------------------------------------------------

void close_file() {
  stop_ticking();
  if (g_player != nullptr) {
    gst_element_set_state(g_player, GST_STATE_NULL);
    gst_object_unref(g_player);
    g_player = nullptr;
  }
  g_ended = false;
}

/// Everything the decoder will say about a file, or nullptr if it will not open
/// it. `GstDiscoverer` is the one call that answers all of it at once.
FlValue* read_info(const std::string& path) {
  g_autoptr(GError) error = nullptr;
  g_autofree gchar* uri = gst_filename_to_uri(path.c_str(), &error);
  // **Never glued together by hand.** A path turned into a URI with string
  // arithmetic is how a drive letter or a space goes missing.
  if (uri == nullptr) return nullptr;

  g_autoptr(GstDiscoverer) discoverer = gst_discoverer_new(10 * GST_SECOND,
                                                           &error);
  if (discoverer == nullptr) return nullptr;
  g_autoptr(GstDiscovererInfo) info =
      gst_discoverer_discover_uri(discoverer, uri, &error);
  if (info == nullptr ||
      gst_discoverer_info_get_result(info) != GST_DISCOVERER_OK) {
    return nullptr;
  }

  GList* streams = gst_discoverer_info_get_audio_streams(info);
  if (streams == nullptr) return nullptr;
  auto* audio = static_cast<GstDiscovererAudioInfo*>(streams->data);

  FlValue* answer = fl_value_new_map();
  fl_value_set_string_take(
      answer, "durationMs",
      fl_value_new_int(gst_discoverer_info_get_duration(info) / GST_MSECOND));
  fl_value_set_string_take(
      answer, "sampleRate",
      fl_value_new_float(gst_discoverer_audio_info_get_sample_rate(audio)));
  fl_value_set_string_take(
      answer, "channels",
      fl_value_new_int(gst_discoverer_audio_info_get_channels(audio)));
  fl_value_set_string_take(
      answer, "bits",
      fl_value_new_int(gst_discoverer_audio_info_get_depth(audio)));
  guint bitrate = gst_discoverer_audio_info_get_bitrate(audio);
  if (bitrate == 0) {
    bitrate = gst_discoverer_audio_info_get_max_bitrate(audio);
  }
  fl_value_set_string_take(answer, "bitrate", fl_value_new_int(bitrate));

  // The stream's own name, shortened the way the other two runners report it:
  // `audio/mpeg` is mp3 to everybody who has ever looked at a file.
  std::string codec;
  g_autoptr(GstCaps) caps =
      gst_discoverer_stream_info_get_caps(GST_DISCOVERER_STREAM_INFO(audio));
  if (caps != nullptr && gst_caps_get_size(caps) > 0) {
    GstStructure* structure = gst_caps_get_structure(caps, 0);
    const gchar* name = gst_structure_get_name(structure);
    if (name != nullptr) {
      const std::string full(name);
      if (full == "audio/mpeg") {
        gint version = 0;
        gst_structure_get_int(structure, "mpegversion", &version);
        codec = version == 1 ? "mp3" : "aac";
      } else if (full == "audio/x-flac") {
        codec = "flac";
      } else if (full == "audio/x-alac") {
        codec = "alac";
      } else if (full == "audio/x-wav" || full == "audio/x-raw") {
        codec = "lpcm";
      } else if (full == "audio/x-wma") {
        codec = "wma";
      } else if (full == "audio/x-vorbis") {
        codec = "vorbis";
      } else if (full == "audio/x-opus") {
        codec = "opus";
      } else {
        const size_t slash = full.find('/');
        codec = slash == std::string::npos ? full : full.substr(slash + 1);
      }
    }
  }
  fl_value_set_string_take(answer, "codec", fl_value_new_string(codec.c_str()));

  GStatBuf stat_buffer;
  if (g_stat(path.c_str(), &stat_buffer) == 0) {
    fl_value_set_string_take(
        answer, "bytes", fl_value_new_int(stat_buffer.st_size));
  }

  gst_discoverer_stream_info_list_free(streams);
  return answer;
}

bool open_file(const std::string& path) {
  close_file();
  g_autoptr(GError) error = nullptr;
  g_autofree gchar* uri = gst_filename_to_uri(path.c_str(), &error);
  if (uri == nullptr) return false;

  g_player = gst_element_factory_make("playbin", "xverb-sound");
  if (g_player == nullptr) return false;
  g_object_set(g_player, "uri", uri, nullptr);
  // Audio only: a sound file with a cover picture in it is still a sound file,
  // and a window opening for it is not something anybody asked for.
  GstElement* nowhere = gst_element_factory_make("fakesink", nullptr);
  if (nowhere != nullptr) g_object_set(g_player, "video-sink", nowhere, nullptr);
  g_object_set(g_player, "volume", g_volume, nullptr);

  // Paused rather than playing: the file is opened when it is opened, and it
  // sounds when somebody says so.
  gst_element_set_state(g_player, GST_STATE_PAUSED);
  gst_element_get_state(g_player, nullptr, nullptr, 5 * GST_SECOND);
  return true;
}

// -- the two sweeps ---------------------------------------------------------

/// Decodes the whole file to mono float, handing each block to `take`.
///
/// One pipeline for both sweeps, because they differ only in what they do with
/// the samples: `decodebin` reads whatever this machine has a plugin for, and
/// the `appsink` hands it over a block at a time rather than in one piece —
/// ten minutes of float is a hundred megabytes and none of it is wanted twice.
template <typename Take>
bool sweep(const std::string& path, gint64* duration_ms, int* rate,
           const Take& take) {
  g_autoptr(GError) error = nullptr;
  g_autofree gchar* uri = gst_filename_to_uri(path.c_str(), &error);
  if (uri == nullptr) return false;

  GstElement* pipeline = gst_parse_launch(
      "uridecodebin name=source ! audioconvert ! audioresample ! "
      "appsink name=sink sync=false "
      "caps=\"audio/x-raw,format=F32LE,channels=1\"",
      &error);
  if (pipeline == nullptr) return false;

  GstElement* source = gst_bin_get_by_name(GST_BIN(pipeline), "source");
  g_object_set(source, "uri", uri, nullptr);
  gst_object_unref(source);

  GstElement* sink = gst_bin_get_by_name(GST_BIN(pipeline), "sink");
  gst_element_set_state(pipeline, GST_STATE_PLAYING);
  gst_element_get_state(pipeline, nullptr, nullptr, 10 * GST_SECOND);

  gint64 length = 0;
  if (gst_element_query_duration(pipeline, GST_FORMAT_TIME, &length)) {
    *duration_ms = length / GST_MSECOND;
  }

  GstCaps* caps = gst_app_sink_get_caps(GST_APP_SINK(sink));
  if (caps != nullptr && gst_caps_get_size(caps) > 0) {
    gst_structure_get_int(gst_caps_get_structure(caps, 0), "rate", rate);
    gst_caps_unref(caps);
  }

  while (true) {
    GstSample* sample = gst_app_sink_pull_sample(GST_APP_SINK(sink));
    if (sample == nullptr) break;  // End of stream, or the sink was stopped.
    if (*rate == 0) {
      GstCaps* current = gst_sample_get_caps(sample);
      if (current != nullptr && gst_caps_get_size(current) > 0) {
        gst_structure_get_int(gst_caps_get_structure(current, 0), "rate", rate);
      }
    }
    GstBuffer* buffer = gst_sample_get_buffer(sample);
    GstMapInfo mapped;
    if (buffer != nullptr && gst_buffer_map(buffer, &mapped, GST_MAP_READ)) {
      take(reinterpret_cast<const float*>(mapped.data),
           mapped.size / sizeof(float));
      gst_buffer_unmap(buffer, &mapped);
    }
    gst_sample_unref(sample);
  }

  gst_element_set_state(pipeline, GST_STATE_NULL);
  gst_object_unref(sink);
  gst_object_unref(pipeline);
  return true;
}

/// `buckets` pairs of peak and average, 0..1 — the contract the other two
/// runners answer.
std::vector<float> decode_envelope(const std::string& path, int buckets) {
  gint64 duration_ms = 0;
  int rate = 0;
  std::vector<float> shape(static_cast<size_t>(buckets) * 2, 0.0f);
  std::vector<int> counts(buckets, 0);
  double frame = 0;
  double frames = 0;

  const bool ok = sweep(path, &duration_ms, &rate,
                        [&](const float* values, size_t count) {
                          if (frames <= 0) {
                            frames = duration_ms / 1000.0 * rate;
                          }
                          if (frames <= 1) return;
                          for (size_t i = 0; i < count; ++i) {
                            const float value = std::fabs(values[i]);
                            const int bucket = std::min(
                                buckets - 1,
                                static_cast<int>(frame / frames * buckets));
                            if (bucket >= 0) {
                              float& peak = shape[static_cast<size_t>(bucket) * 2];
                              peak = std::max(peak, value);
                              shape[static_cast<size_t>(bucket) * 2 + 1] += value;
                              counts[bucket]++;
                            }
                            frame += 1;
                          }
                        });
  if (!ok) return {};

  for (int b = 0; b < buckets; ++b) {
    if (counts[b] > 0) shape[static_cast<size_t>(b) * 2 + 1] /= counts[b];
  }
  return shape;
}

/// An in-place radix-2 FFT. The same forty lines the Windows runner carries:
/// the two share no code and there is nothing to share it through, so what is
/// shared is the arithmetic and the contract.
void transform(std::vector<float>* real, std::vector<float>* imaginary) {
  const size_t size = real->size();
  for (size_t i = 1, j = 0; i < size; ++i) {
    size_t bit = size >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) {
      std::swap((*real)[i], (*real)[j]);
      std::swap((*imaginary)[i], (*imaginary)[j]);
    }
  }
  for (size_t length = 2; length <= size; length <<= 1) {
    const double angle = -2 * G_PI / length;
    const float turn_real = static_cast<float>(std::cos(angle));
    const float turn_imaginary = static_cast<float>(std::sin(angle));
    for (size_t at = 0; at < size; at += length) {
      float w_real = 1;
      float w_imaginary = 0;
      for (size_t k = 0; k < length / 2; ++k) {
        const size_t a = at + k;
        const size_t b = at + k + length / 2;
        const float even_real = (*real)[a];
        const float even_imaginary = (*imaginary)[a];
        const float odd_real =
            (*real)[b] * w_real - (*imaginary)[b] * w_imaginary;
        const float odd_imaginary =
            (*real)[b] * w_imaginary + (*imaginary)[b] * w_real;
        (*real)[a] = even_real + odd_real;
        (*imaginary)[a] = even_imaginary + odd_imaginary;
        (*real)[b] = even_real - odd_real;
        (*imaginary)[b] = even_imaginary - odd_imaginary;
        const float next_real =
            w_real * turn_real - w_imaginary * turn_imaginary;
        w_imaginary = w_real * turn_imaginary + w_imaginary * turn_real;
        w_real = next_real;
      }
    }
  }
}

std::vector<float> decode_spectrum(const std::string& path, int columns,
                                   int bands) {
  // 2048, not 1024: at a thousand a bin is 43 Hz wide, so every band below
  // about 400 Hz lands on the same one or two bins and the bottom of the
  // picture comes out as blocks. The other two runners say the same.
  const size_t window = 2048;
  const size_t half = window / 2;

  std::vector<float> shape(window);
  for (size_t i = 0; i < window; ++i) {
    // Hann, so a slice does not report the edges of its own window as sound.
    shape[i] = 0.5f * (1 - static_cast<float>(std::cos(2 * G_PI * i /
                                                       (window - 1))));
  }

  std::vector<float> picture(static_cast<size_t>(columns) * bands, 0.0f);
  std::vector<float> ring(window, 0.0f);
  std::vector<float> real(window), imaginary(window);
  std::vector<int> edges(bands + 1);
  std::vector<double> centres(bands, 0.0);
  size_t ring_at = 0;
  double frame = 0;
  double next_slice = 0;
  double frames = 0;
  int slice = 0;
  gint64 duration_ms = 0;
  int rate = 0;

  const bool ok = sweep(
      path, &duration_ms, &rate, [&](const float* values, size_t count) {
        if (frames <= 0) {
          frames = duration_ms / 1000.0 * rate;
          if (frames <= window || rate <= 0) return;
          // Which bin each band ends at, spaced by ear: the top half of a
          // linear scale is where almost nothing happens.
          const float lowest = 40;
          const float highest = std::min(rate / 2.0f, 16000.0f);
          const float per_bin = rate / float(window);
          for (int b = 0; b <= bands; ++b) {
            const float hertz =
                lowest * std::pow(highest / lowest,
                                  static_cast<float>(b) / bands);
            edges[b] = std::min(static_cast<int>(half) - 1,
                                std::max(1, static_cast<int>(hertz / per_bin)));
            if (b < bands) {
              // Where the band sits in bins as a fraction, for the ones too
              // narrow to contain one.
              const float next =
                  lowest * std::pow(highest / lowest,
                                    static_cast<float>(b + 1) / bands);
              centres[b] = std::sqrt(hertz * next) / per_bin;
            }
          }
        }
        if (frames <= window) return;

        for (size_t i = 0; i < count && slice < columns; ++i) {
          ring[ring_at] = values[i];
          ring_at = (ring_at + 1) % window;
          if (frame >= next_slice) {
            for (size_t k = 0; k < window; ++k) {
              real[k] = ring[(ring_at + k) % window] * shape[k];
              imaginary[k] = 0;
            }
            transform(&real, &imaginary);
            for (int b = 0; b < bands; ++b) {
              const int from = edges[b];
              const int to = std::max(from + 1, edges[b + 1]);
              // The average where the band covers bins, and the value *between*
              // bins where it does not — a band narrower than a bin otherwise
              // repeats its neighbour's number and the bass draws as blocks.
              const auto magnitude = [&](int bin) {
                return std::sqrt(real[bin] * real[bin] +
                                 imaginary[bin] * imaginary[bin]);
              };
              float loudest = 0;
              if (to - from >= 2) {
                float sum = 0;
                const int last = std::min(to, static_cast<int>(half));
                for (int bin = from; bin < last; ++bin) sum += magnitude(bin);
                loudest = last > from ? sum / (last - from) : 0;
              } else {
                const double exact = centres[b];
                const int low = std::min(static_cast<int>(half) - 1,
                                         std::max(0, static_cast<int>(exact)));
                const int high = std::min(static_cast<int>(half) - 1, low + 1);
                const float part = static_cast<float>(exact - low);
                loudest = magnitude(low) * (1 - part) + magnitude(high) * part;
              }
              // The same scale the other two report, or the same file is drawn
              // differently on different machines.
              const float scaled = loudest / window;
              const float decibels =
                  scaled > 0.0000001f ? 20 * std::log10(scaled) : -100.0f;
              picture[static_cast<size_t>(slice) * bands + b] =
                  std::max(0.0f, std::min(1.0f, (decibels + 80) / 80));
            }
            slice++;
            next_slice += std::max(1.0, frames / columns);
          }
          frame += 1;
        }
      });
  return ok ? picture : std::vector<float>();
}

// -- the work that must not happen on the platform thread -------------------

/// One sweep being made, and who is waiting for it. GStreamer decodes on its
/// own threads but the pull is blocking, so the whole thing runs in a thread of
/// its own and the answer is posted back to the loop that owns the channel.
struct Sweep {
  FlMethodCall* call;
  std::string path;
  int first;
  int second;
  bool frequencies;
  std::vector<float> result;
};

gboolean finish_sweep(gpointer data) {
  auto* work = static_cast<Sweep*>(data);
  g_autoptr(FlValue) answer =
      work->result.empty()
          ? fl_value_new_null()
          : fl_value_new_float32_list(work->result.data(), work->result.size());
  fl_method_call_respond_success(work->call, answer, nullptr);
  g_object_unref(work->call);
  delete work;
  return G_SOURCE_REMOVE;
}

gpointer run_sweep(gpointer data) {
  auto* work = static_cast<Sweep*>(data);
  work->result = work->frequencies
                     ? decode_spectrum(work->path, work->first, work->second)
                     : decode_envelope(work->path, work->first);
  g_idle_add(finish_sweep, work);
  return nullptr;
}

#endif  // XVERB_HAS_GSTREAMER

// -- the channel ------------------------------------------------------------

void handle_call(FlMethodChannel*, FlMethodCall* call, gpointer) {
  const gchar* method = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);

#ifdef XVERB_HAS_GSTREAMER
  if (g_strcmp0(method, "open") == 0) {
    const std::string path = text_arg(args, "path");
    FlValue* info = path.empty() ? nullptr : read_info(path);
    if (info == nullptr || !open_file(path)) {
      // Not an error: this machine does not read that sound, and the same file
      // on another desktop may well play.
      g_autoptr(FlValue) nothing = fl_value_new_null();
      fl_method_call_respond_success(call, nothing, nullptr);
      return;
    }
    g_autoptr(FlValue) answer = info;
    fl_method_call_respond_success(call, answer, nullptr);
    return;
  }

  if (g_strcmp0(method, "play") == 0) {
    if (g_player != nullptr) {
      if (g_ended) {
        // Play on a finished track starts it again; pressing play and getting
        // silence reads as a broken player.
        gst_element_seek_simple(g_player, GST_FORMAT_TIME,
                                GST_SEEK_FLAG_FLUSH, 0);
        g_ended = false;
      }
      gst_element_set_state(g_player, GST_STATE_PLAYING);
      start_ticking();
      send_tick();
    }
  } else if (g_strcmp0(method, "pause") == 0) {
    if (g_player != nullptr) {
      gst_element_set_state(g_player, GST_STATE_PAUSED);
      send_tick();
      stop_ticking();
    }
  } else if (g_strcmp0(method, "seek") == 0) {
    if (g_player != nullptr) {
      const gint64 where = std::max<gint64>(0, number_arg(args, "positionMs", 0));
      gst_element_seek_simple(
          g_player, GST_FORMAT_TIME,
          static_cast<GstSeekFlags>(GST_SEEK_FLAG_FLUSH | GST_SEEK_FLAG_KEY_UNIT),
          where * GST_MSECOND);
      g_ended = false;
      send_tick();
    }
  } else if (g_strcmp0(method, "volume") == 0) {
    g_volume = std::max(0.0, std::min(1.0, float_arg(args, "volume", 1)));
    if (g_player != nullptr) g_object_set(g_player, "volume", g_volume, nullptr);
  } else if (g_strcmp0(method, "close") == 0) {
    close_file();
  } else if (g_strcmp0(method, "envelope") == 0 ||
             g_strcmp0(method, "spectrum") == 0) {
    const bool frequencies = g_strcmp0(method, "spectrum") == 0;
    const std::string path = text_arg(args, "path");
    const int first = static_cast<int>(
        frequencies ? number_arg(args, "columns", 1024)
                    : number_arg(args, "buckets", 800));
    const int second = static_cast<int>(number_arg(args, "bands", 48));
    if (path.empty() || first <= 0) {
      g_autoptr(FlValue) nothing = fl_value_new_null();
      fl_method_call_respond_success(call, nothing, nullptr);
      return;
    }
    auto* work = new Sweep{FL_METHOD_CALL(g_object_ref(call)), path, first,
                           second, frequencies, {}};
    g_thread_unref(g_thread_new("xverb-sound-sweep", run_sweep, work));
    return;
  } else {
    fl_method_call_respond_not_implemented(call, nullptr);
    return;
  }

  g_autoptr(FlValue) done = fl_value_new_null();
  fl_method_call_respond_success(call, done, nullptr);
#else
  // A build without GStreamer's headers. Everything is answered, and `open`
  // answers nothing — which the viewer already knows how to say out loud.
  (void)args;
  if (g_strcmp0(method, "open") == 0 || g_strcmp0(method, "envelope") == 0 ||
      g_strcmp0(method, "spectrum") == 0) {
    g_autoptr(FlValue) nothing = fl_value_new_null();
    fl_method_call_respond_success(call, nothing, nullptr);
    return;
  }
  g_autoptr(FlValue) done = fl_value_new_null();
  fl_method_call_respond_success(call, done, nullptr);
#endif
}

FlMethodErrorResponse* on_listen(FlEventChannel*, FlValue*, gpointer) {
  g_listening = true;
  return nullptr;
}

FlMethodErrorResponse* on_cancel(FlEventChannel*, FlValue*, gpointer) {
  g_listening = false;
  return nullptr;
}

}  // namespace

void register_audio_channel(FlBinaryMessenger* messenger) {
#ifdef XVERB_HAS_GSTREAMER
  gst_init(nullptr, nullptr);
#endif

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_channel = fl_method_channel_new(messenger, kChannelName,
                                    FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(g_channel, handle_call, nullptr,
                                            nullptr);

  g_ticks = fl_event_channel_new(messenger, kTicksName, FL_METHOD_CODEC(codec));
  fl_event_channel_set_stream_handlers(g_ticks, on_listen, on_cancel, nullptr,
                                       nullptr);
}
