#include "audio.h"

#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <audiosessiontypes.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfmediaengine.h>
#include <mfreadwrite.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#pragma comment(lib, "mf.lib")
#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mfreadwrite.lib")
#pragma comment(lib, "mfuuid.lib")

namespace {

constexpr char kChannelName[] = "xverb/audio";
constexpr char kTicksName[] = "xverb/audio/ticks";

// Ten a second, matching the Mac. Often enough to keep the drawing's own clock
// honest, rare enough to cost nothing.
constexpr UINT kTickMs = 100;
constexpr UINT_PTR kTickTimer = 1;

// A finished sweep — a waveform or a spectrum — posted back from the thread
// that decoded it.
constexpr UINT kEnvelopeDone = WM_APP + 1;

using flutter::EncodableMap;
using flutter::EncodableValue;

std::unique_ptr<flutter::MethodChannel<EncodableValue>> g_channel;
std::unique_ptr<flutter::EventChannel<EncodableValue>> g_ticks;
std::unique_ptr<flutter::EventSink<EncodableValue>> g_sink;

// Media Foundation calls back on its own threads and a Flutter sink belongs to
// the platform thread, so everything crosses over through this window: it lives
// on the thread that made it, and the runner's message loop is what runs its
// procedure. A timer owned by a window rather than by the thread, for the same
// reason — it is dispatched where the channel can be touched.
HWND g_pump = nullptr;

bool g_media_ready = false;
IMFMediaEngine* g_engine = nullptr;
IMFMediaEngineEx* g_engine_ex = nullptr;
bool g_ticking = false;

// The application's own, never the system's mixer. Kept here so a file opened
// after a change is played at the volume that was set, not at full scale.
double g_volume = 0.7;

std::wstring Widen(const std::string& utf8) {
  if (utf8.empty()) return std::wstring();
  const int size = ::MultiByteToWideChar(
      CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), nullptr, 0);
  std::wstring wide(size, L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                        wide.data(), size);
  return wide;
}

// What the media engine has told us, remembered rather than acted on.
//
// The engine insists on a callback object even when nothing is watching, and
// what arrives comes in on a Media Foundation thread. So this only sets flags,
// and the tick that runs on the platform thread reads them.
class Notify : public IMFMediaEngineNotify {
 public:
  STDMETHODIMP QueryInterface(REFIID riid, void** out) override {
    if (riid == IID_IMFMediaEngineNotify || riid == IID_IUnknown) {
      *out = static_cast<IMFMediaEngineNotify*>(this);
      AddRef();
      return S_OK;
    }
    *out = nullptr;
    return E_NOINTERFACE;
  }

  STDMETHODIMP_(ULONG) AddRef() override {
    return ::InterlockedIncrement(&references_);
  }

  STDMETHODIMP_(ULONG) Release() override {
    const ULONG left = ::InterlockedDecrement(&references_);
    if (left == 0) delete this;
    return left;
  }

  STDMETHODIMP EventNotify(DWORD event, DWORD_PTR, DWORD) override {
    switch (event) {
      case MF_MEDIA_ENGINE_EVENT_ENDED:
        ended_ = true;
        break;
      case MF_MEDIA_ENGINE_EVENT_ERROR:
        failed_ = true;
        break;
      case MF_MEDIA_ENGINE_EVENT_PLAYING:
        ended_ = false;
        break;
      default:
        break;
    }
    return S_OK;
  }

  bool ended() const { return ended_; }
  bool failed() const { return failed_; }
  void forget() { ended_ = failed_ = false; }

 private:
  ULONG references_ = 1;
  volatile bool ended_ = false;
  volatile bool failed_ = false;
};

Notify* g_notify = nullptr;

// The name of a stream, in the same four characters the Mac reports.
//
// A Media Foundation audio subtype is built from the WAVE format tag, so an
// unknown one is still worth saying: the tag in hexadecimal is what a person
// searches for, and it beats an empty column.
std::string CodecName(const GUID& subtype) {
  if (subtype == MFAudioFormat_MP3) return "mp3";
  if (subtype == MFAudioFormat_AAC) return "aac";
  if (subtype == MFAudioFormat_FLAC) return "flac";
  if (subtype == MFAudioFormat_ALAC) return "alac";
  if (subtype == MFAudioFormat_PCM || subtype == MFAudioFormat_Float) {
    return "lpcm";
  }
  if (subtype == MFAudioFormat_WMAudioV8 ||
      subtype == MFAudioFormat_WMAudioV9 ||
      subtype == MFAudioFormat_WMAudio_Lossless) {
    return "wma";
  }
  if (subtype == MFAudioFormat_Opus) return "opus";
  if (subtype == MFAudioFormat_Dolby_AC3) return "ac-3";
  if (subtype == MFAudioFormat_AMR_NB || subtype == MFAudioFormat_AMR_WB) {
    return "amr";
  }
  char tag[16] = {};
  ::sprintf_s(tag, "0x%04x", static_cast<unsigned>(subtype.Data1 & 0xFFFF));
  return tag;
}

bool StartMedia() {
  if (g_media_ready) return true;
  // The runner's thread is an STA and Media Foundation is content with that —
  // this is the same apartment the system's own players run their media engine
  // in. A failure here is a machine without Media Foundation at all, which is
  // reported as "cannot play" rather than pretended around.
  if (FAILED(::MFStartup(MF_VERSION, MFSTARTUP_FULL))) return false;
  g_media_ready = true;
  return true;
}

// Everything the decoder will say about a file, or false if it will not open it.
bool ReadInfo(const std::wstring& path, EncodableMap* into) {
  // **The platform first, or the reader is never made.** `open` asks this
  // before it asks the media engine for anything, and a source reader built
  // before `MFStartup` fails with `MF_E_PLATFORM_NOT_INITIALIZED` — which read,
  // from the other end of the channel, as "this sound could not be read on this
  // machine", for every file, forever.
  if (!StartMedia()) return false;

  IMFSourceReader* reader = nullptr;
  if (FAILED(::MFCreateSourceReaderFromURL(path.c_str(), nullptr, &reader))) {
    return false;
  }

  IMFMediaType* native = nullptr;
  if (FAILED(reader->GetNativeMediaType(
          static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM), 0,
          &native))) {
    reader->Release();
    return false;
  }

  GUID subtype = {};
  native->GetGUID(MF_MT_SUBTYPE, &subtype);
  const UINT32 rate =
      ::MFGetAttributeUINT32(native, MF_MT_AUDIO_SAMPLES_PER_SECOND, 0);
  const UINT32 channels =
      ::MFGetAttributeUINT32(native, MF_MT_AUDIO_NUM_CHANNELS, 0);
  const UINT32 bits =
      ::MFGetAttributeUINT32(native, MF_MT_AUDIO_BITS_PER_SAMPLE, 0);
  const UINT32 bytes_a_second =
      ::MFGetAttributeUINT32(native, MF_MT_AUDIO_AVG_BYTES_PER_SECOND, 0);

  PROPVARIANT duration;
  ::PropVariantInit(&duration);
  int64_t ms = 0;
  if (SUCCEEDED(reader->GetPresentationAttribute(
          static_cast<DWORD>(MF_SOURCE_READER_MEDIASOURCE), MF_PD_DURATION,
          &duration))) {
    // Media Foundation counts in hundreds of nanoseconds, everywhere.
    ms = static_cast<int64_t>(duration.uhVal.QuadPart / 10000);
  }
  ::PropVariantClear(&duration);

  (*into)[EncodableValue("durationMs")] =
      EncodableValue(static_cast<int32_t>(ms));
  (*into)[EncodableValue("sampleRate")] =
      EncodableValue(static_cast<double>(rate));
  (*into)[EncodableValue("channels")] =
      EncodableValue(static_cast<int32_t>(channels));
  (*into)[EncodableValue("codec")] = EncodableValue(CodecName(subtype));
  (*into)[EncodableValue("bits")] = EncodableValue(static_cast<int32_t>(bits));
  (*into)[EncodableValue("bitrate")] =
      EncodableValue(static_cast<int32_t>(bytes_a_second * 8));

  WIN32_FILE_ATTRIBUTE_DATA about = {};
  if (::GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &about)) {
    const int64_t size = (static_cast<int64_t>(about.nFileSizeHigh) << 32) |
                         about.nFileSizeLow;
    (*into)[EncodableValue("bytes")] = EncodableValue(size);
  }

  native->Release();
  reader->Release();
  return rate > 0 && channels > 0;
}

void StopTicking() {
  if (!g_ticking) return;
  ::KillTimer(g_pump, kTickTimer);
  g_ticking = false;
}

void SendTick() {
  if (!g_sink || !g_engine) return;
  const double at = g_engine->GetCurrentTime();
  const bool ended = g_notify->ended() || g_engine->IsEnded();
  const bool playing = !ended && !g_engine->IsPaused();

  EncodableMap tick;
  tick[EncodableValue("positionMs")] =
      EncodableValue(static_cast<int32_t>(at * 1000));
  tick[EncodableValue("playing")] = EncodableValue(playing);
  tick[EncodableValue("ended")] = EncodableValue(ended);
  g_sink->Success(EncodableValue(tick));

  if (ended) StopTicking();
}

void StartTicking() {
  if (g_ticking || !g_pump) return;
  ::SetTimer(g_pump, kTickTimer, kTickMs, nullptr);
  g_ticking = true;
}

// One sweep of the decoder being made, and who is waiting for it.
struct SweepJob {
  std::unique_ptr<flutter::MethodResult<EncodableValue>> waiting;
  std::vector<float> shape;
};

// The shape of the whole file: `buckets` pairs of peak and average, 0..1.
//
// The source reader is asked for float samples, so one loop covers mp3, AAC,
// FLAC, ALAC and plain PCM alike — the decoder does the format and nothing here
// has to know one from another.
void DecodeEnvelope(const std::wstring& path, int buckets,
                    std::vector<float>* shape) {
  // Its own thread, so its own apartment. Multithreaded, which is what a
  // decoder wants and what the platform thread cannot be.
  if (FAILED(::CoInitializeEx(nullptr, COINIT_MULTITHREADED))) return;

  IMFSourceReader* reader = nullptr;
  if (SUCCEEDED(::MFCreateSourceReaderFromURL(path.c_str(), nullptr, &reader))) {
    IMFMediaType* want = nullptr;
    if (SUCCEEDED(::MFCreateMediaType(&want))) {
      want->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
      want->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_Float);
      const bool converted = SUCCEEDED(reader->SetCurrentMediaType(
          static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM), nullptr,
          want));
      want->Release();

      IMFMediaType* actual = nullptr;
      UINT32 channels = 0;
      UINT32 rate = 0;
      if (converted &&
          SUCCEEDED(reader->GetCurrentMediaType(
              static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM),
              &actual))) {
        channels = ::MFGetAttributeUINT32(actual, MF_MT_AUDIO_NUM_CHANNELS, 1);
        rate = ::MFGetAttributeUINT32(actual, MF_MT_AUDIO_SAMPLES_PER_SECOND, 0);
        actual->Release();
      }

      // How many frames there are is not something a reader is asked; it is the
      // duration times the rate, which is what the buckets are spread over.
      double frames = 0;
      PROPVARIANT duration;
      ::PropVariantInit(&duration);
      if (SUCCEEDED(reader->GetPresentationAttribute(
              static_cast<DWORD>(MF_SOURCE_READER_MEDIASOURCE), MF_PD_DURATION,
              &duration))) {
        frames = static_cast<double>(duration.uhVal.QuadPart) / 10000000.0 * rate;
      }
      ::PropVariantClear(&duration);

      if (channels > 0 && frames > 1) {
        shape->assign(static_cast<size_t>(buckets) * 2, 0.0f);
        std::vector<int> counts(buckets, 0);
        double frame = 0;

        while (true) {
          DWORD flags = 0;
          IMFSample* sample = nullptr;
          if (FAILED(reader->ReadSample(
                  static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM), 0,
                  nullptr, &flags, nullptr, &sample))) {
            break;
          }
          if (flags & MF_SOURCE_READERF_ENDOFSTREAM) {
            if (sample) sample->Release();
            break;
          }
          if (!sample) continue;  // A gap in the stream, not the end of it.

          IMFMediaBuffer* buffer = nullptr;
          if (SUCCEEDED(sample->ConvertToContiguousBuffer(&buffer))) {
            BYTE* bytes = nullptr;
            DWORD length = 0;
            if (SUCCEEDED(buffer->Lock(&bytes, nullptr, &length))) {
              const float* values = reinterpret_cast<const float*>(bytes);
              const size_t count = length / sizeof(float);
              for (size_t i = 0; i + channels <= count; i += channels) {
                // The louder of the channels, not their average: a sound in one
                // channel only is still a sound, and averaging halves it.
                float value = 0;
                for (UINT32 c = 0; c < channels; ++c) {
                  value = (std::max)(value, std::fabs(values[i + c]));
                }
                const int bucket = (std::min)(
                    buckets - 1,
                    static_cast<int>(frame / frames * buckets));
                if (bucket >= 0) {
                  float& peak = (*shape)[static_cast<size_t>(bucket) * 2];
                  peak = (std::max)(peak, value);
                  (*shape)[static_cast<size_t>(bucket) * 2 + 1] += value;
                  counts[bucket]++;
                }
                frame += 1;
              }
              buffer->Unlock();
            }
            buffer->Release();
          }
          sample->Release();
        }

        for (int b = 0; b < buckets; ++b) {
          if (counts[b] > 0) {
            (*shape)[static_cast<size_t>(b) * 2 + 1] /= counts[b];
          }
        }
      }
    }
    reader->Release();
  }

  ::CoUninitialize();
}

// An in-place radix-2 FFT over `size` complex samples.
//
// Written here rather than pulled in: it is forty lines, it is the same
// transform every textbook prints, and a dependency in the runner is a
// dependency in the installer. The Mac side calls Accelerate for this, which is
// why that one is shorter and this one is not wrong.
void Transform(std::vector<float>* real, std::vector<float>* imaginary) {
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
    const double angle = -2 * 3.14159265358979323846 / length;
    const float turnReal = static_cast<float>(std::cos(angle));
    const float turnImaginary = static_cast<float>(std::sin(angle));
    for (size_t at = 0; at < size; at += length) {
      float wReal = 1;
      float wImaginary = 0;
      for (size_t k = 0; k < length / 2; ++k) {
        const size_t a = at + k;
        const size_t b = at + k + length / 2;
        const float evenReal = (*real)[a];
        const float evenImaginary = (*imaginary)[a];
        const float oddReal = (*real)[b] * wReal - (*imaginary)[b] * wImaginary;
        const float oddImaginary =
            (*real)[b] * wImaginary + (*imaginary)[b] * wReal;
        (*real)[a] = evenReal + oddReal;
        (*imaginary)[a] = evenImaginary + oddImaginary;
        (*real)[b] = evenReal - oddReal;
        (*imaginary)[b] = evenImaginary - oddImaginary;
        const float nextReal = wReal * turnReal - wImaginary * turnImaginary;
        wImaginary = wReal * turnImaginary + wImaginary * turnReal;
        wReal = nextReal;
      }
    }
  }
}

// The file as frequencies: `columns` slices of time, each `bands` values from
// low to high, 0..1 off a decibel scale. The contract the Mac side answers, so
// the drawing does not know which machine it is on.
void DecodeSpectrum(const std::wstring& path, int columns, int bands,
                    std::vector<float>* picture) {
  if (FAILED(::CoInitializeEx(nullptr, COINIT_MULTITHREADED))) return;

  IMFSourceReader* reader = nullptr;
  if (SUCCEEDED(::MFCreateSourceReaderFromURL(path.c_str(), nullptr, &reader))) {
    IMFMediaType* want = nullptr;
    if (SUCCEEDED(::MFCreateMediaType(&want))) {
      want->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
      want->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_Float);
      const bool converted = SUCCEEDED(reader->SetCurrentMediaType(
          static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM), nullptr,
          want));
      want->Release();

      UINT32 channels = 0;
      UINT32 rate = 0;
      IMFMediaType* actual = nullptr;
      if (converted &&
          SUCCEEDED(reader->GetCurrentMediaType(
              static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM),
              &actual))) {
        channels = ::MFGetAttributeUINT32(actual, MF_MT_AUDIO_NUM_CHANNELS, 1);
        rate = ::MFGetAttributeUINT32(actual, MF_MT_AUDIO_SAMPLES_PER_SECOND, 0);
        actual->Release();
      }

      double frames = 0;
      PROPVARIANT duration;
      ::PropVariantInit(&duration);
      if (SUCCEEDED(reader->GetPresentationAttribute(
              static_cast<DWORD>(MF_SOURCE_READER_MEDIASOURCE), MF_PD_DURATION,
              &duration))) {
        frames = static_cast<double>(duration.uhVal.QuadPart) / 10000000.0 * rate;
      }
      ::PropVariantClear(&duration);

      // 2048, not 1024: at a thousand a bin is 43 Hz wide, so every band below
      // about 400 Hz lands on the same one or two bins and the bottom of the
      // picture comes out as blocks. The other two runners say the same.
      const size_t window = 2048;
      const size_t half = window / 2;
      if (channels > 0 && rate > 0 && frames > window) {
        std::vector<float> shape(window);
        for (size_t i = 0; i < window; ++i) {
          // Hann, so a slice does not report the edges of its own window as
          // sound.
          shape[i] = 0.5f * (1 - static_cast<float>(std::cos(
                                    2 * 3.14159265358979323846 * i /
                                    (window - 1))));
        }

        // Which bin each band ends at, spaced by ear: the top half of a linear
        // scale is where almost nothing happens.
        std::vector<int> edges(bands + 1);
        // And where each band sits in bins as a fraction, for the ones too
        // narrow to contain one.
        std::vector<double> centres(bands, 0.0);
        const float lowest = 40;
        const float highest =
            (std::min)(rate / 2.0f, 16000.0f);
        const float per_bin = rate / float(window);
        for (int b = 0; b <= bands; ++b) {
          const float hertz =
              lowest * std::pow(highest / lowest,
                                static_cast<float>(b) / bands);
          edges[b] = (std::min)(static_cast<int>(half) - 1,
                                (std::max)(1, static_cast<int>(hertz / per_bin)));
          if (b < bands) {
            const float next =
                lowest * std::pow(highest / lowest,
                                  static_cast<float>(b + 1) / bands);
            centres[b] = std::sqrt(hertz * next) / per_bin;
          }
        }

        picture->assign(static_cast<size_t>(columns) * bands, 0.0f);
        std::vector<float> ring(window, 0.0f);
        size_t ringAt = 0;
        std::vector<float> real(window), imaginary(window);
        double frame = 0;
        double nextSlice = 0;
        int slice = 0;
        const double hop = (std::max)(1.0, frames / columns);

        while (slice < columns) {
          DWORD flags = 0;
          IMFSample* sample = nullptr;
          if (FAILED(reader->ReadSample(
                  static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM), 0,
                  nullptr, &flags, nullptr, &sample))) {
            break;
          }
          if (flags & MF_SOURCE_READERF_ENDOFSTREAM) {
            if (sample) sample->Release();
            break;
          }
          if (!sample) continue;

          IMFMediaBuffer* buffer = nullptr;
          if (SUCCEEDED(sample->ConvertToContiguousBuffer(&buffer))) {
            BYTE* bytes = nullptr;
            DWORD length = 0;
            if (SUCCEEDED(buffer->Lock(&bytes, nullptr, &length))) {
              const float* values = reinterpret_cast<const float*>(bytes);
              const size_t count = length / sizeof(float);
              for (size_t i = 0; i + channels <= count && slice < columns;
                   i += channels) {
                // Mixed to one: a spectrum of the left channel is not a
                // spectrum of the file.
                float value = 0;
                for (UINT32 c = 0; c < channels; ++c) value += values[i + c];
                ring[ringAt] = value / channels;
                ringAt = (ringAt + 1) % window;

                if (frame >= nextSlice) {
                  for (size_t k = 0; k < window; ++k) {
                    real[k] = ring[(ringAt + k) % window] * shape[k];
                    imaginary[k] = 0;
                  }
                  Transform(&real, &imaginary);
                  for (int b = 0; b < bands; ++b) {
                    const int from = edges[b];
                    const int to = (std::max)(from + 1, edges[b + 1]);
                    // The average where the band covers bins, and the value
                    // *between* bins where it does not: a band narrower than a
                    // bin — which every band in the bass is — otherwise repeats
                    // its neighbour's number exactly, and a stack of bands all
                    // reading one bin is a blocky bottom.
                    float loudest = 0;
                    const auto magnitude = [&](int bin) {
                      return std::sqrt(real[bin] * real[bin] +
                                       imaginary[bin] * imaginary[bin]);
                    };
                    if (to - from >= 2) {
                      float sum = 0;
                      const int last = (std::min)(to, static_cast<int>(half));
                      for (int bin = from; bin < last; ++bin) sum += magnitude(bin);
                      loudest = last > from ? sum / (last - from) : 0;
                    } else {
                      const double exact = centres[b];
                      const int low = (std::min)(
                          static_cast<int>(half) - 1,
                          (std::max)(0, static_cast<int>(exact)));
                      const int high =
                          (std::min)(static_cast<int>(half) - 1, low + 1);
                      const float part = static_cast<float>(exact - low);
                      loudest = magnitude(low) * (1 - part) + magnitude(high) * part;
                    }
                    // The same scale the Mac reports, or the two machines draw
                    // the same file differently.
                    const float scaled = loudest / window;
                    const float decibels =
                        scaled > 0.0000001f
                            ? 20 * std::log10(scaled)
                            : -100.0f;
                    (*picture)[static_cast<size_t>(slice) * bands + b] =
                        (std::max)(0.0f,
                                   (std::min)(1.0f, (decibels + 80) / 80));
                  }
                  slice++;
                  nextSlice += hop;
                }
                frame += 1;
              }
              buffer->Unlock();
            }
            buffer->Release();
          }
          sample->Release();
        }
      }
    }
    reader->Release();
  }

  ::CoUninitialize();
}

void FinishSweep(SweepJob* job) {
  if (job->shape.empty()) {
    job->waiting->Success();
  } else {
    job->waiting->Success(EncodableValue(job->shape));
  }
  delete job;
}

LRESULT CALLBACK PumpProc(HWND window, UINT message, WPARAM wparam,
                          LPARAM lparam) {
  if (message == WM_TIMER && wparam == kTickTimer) {
    SendTick();
    return 0;
  }
  if (message == kEnvelopeDone) {
    FinishSweep(reinterpret_cast<SweepJob*>(lparam));
    return 0;
  }
  return ::DefWindowProc(window, message, wparam, lparam);
}

// A window with no pixels, only a thread. See [g_pump].
HWND MakePump() {
  static const wchar_t* kClass = L"XverbAudioPump";
  static bool registered = false;
  if (!registered) {
    WNDCLASSW description = {};
    description.lpfnWndProc = PumpProc;
    description.hInstance = ::GetModuleHandle(nullptr);
    description.lpszClassName = kClass;
    ::RegisterClassW(&description);
    registered = true;
  }
  return ::CreateWindowExW(0, kClass, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr,
                           ::GetModuleHandle(nullptr), nullptr);
}

void CloseFile() {
  StopTicking();
  if (g_engine) {
    g_engine->Pause();
    g_engine->SetCurrentTime(0);
  }
  if (g_notify) g_notify->forget();
}

// Hands the file to the media engine. One player, one file: a second open
// replaces the first, because two sounds at once out of a file manager is a
// defect however it comes about.
bool OpenFile(const std::wstring& path) {
  if (!StartMedia()) return false;

  if (!g_engine) {
    IMFMediaEngineClassFactory* factory = nullptr;
    if (FAILED(::CoCreateInstance(CLSID_MFMediaEngineClassFactory, nullptr,
                                  CLSCTX_INPROC_SERVER,
                                  IID_PPV_ARGS(&factory)))) {
      return false;
    }
    IMFAttributes* attributes = nullptr;
    if (FAILED(::MFCreateAttributes(&attributes, 2))) {
      factory->Release();
      return false;
    }
    g_notify = new Notify();
    attributes->SetUnknown(MF_MEDIA_ENGINE_CALLBACK, g_notify);
    attributes->SetUINT32(MF_MEDIA_ENGINE_AUDIO_CATEGORY, AudioCategory_Media);
    const HRESULT made = factory->CreateInstance(MF_MEDIA_ENGINE_AUDIOONLY,
                                                 attributes, &g_engine);
    attributes->Release();
    factory->Release();
    if (FAILED(made)) {
      g_notify->Release();
      g_notify = nullptr;
      return false;
    }
    g_engine->QueryInterface(IID_PPV_ARGS(&g_engine_ex));
  }

  CloseFile();
  g_engine->SetVolume(g_volume);

  // **The path goes over as a stream, not as a URL.** Gluing `file://` to a
  // Windows path is how the drive letter goes missing, and that is a lesson
  // this application has already paid for once.
  IMFByteStream* stream = nullptr;
  if (g_engine_ex &&
      SUCCEEDED(::MFCreateFile(MF_ACCESSMODE_READ, MF_OPENMODE_FAIL_IF_NOT_EXIST,
                               MF_FILEFLAGS_NONE, path.c_str(), &stream))) {
    BSTR hint = ::SysAllocString(path.c_str());
    const HRESULT set = g_engine_ex->SetSourceFromByteStream(stream, hint);
    ::SysFreeString(hint);
    stream->Release();
    return SUCCEEDED(set);
  }

  BSTR url = ::SysAllocString(path.c_str());
  const HRESULT set = g_engine->SetSource(url);
  ::SysFreeString(url);
  return SUCCEEDED(set);
}

void HandleCall(const flutter::MethodCall<EncodableValue>& call,
                std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const auto* arguments = std::get_if<EncodableMap>(call.arguments());
  const auto text = [&](const char* name) -> std::string {
    if (!arguments) return std::string();
    const auto found = arguments->find(EncodableValue(name));
    if (found == arguments->end()) return std::string();
    const auto* value = std::get_if<std::string>(&found->second);
    return value ? *value : std::string();
  };
  const auto number = [&](const char* name, double fallback) -> double {
    if (!arguments) return fallback;
    const auto found = arguments->find(EncodableValue(name));
    if (found == arguments->end()) return fallback;
    if (const auto* as_double = std::get_if<double>(&found->second)) {
      return *as_double;
    }
    if (const auto* as_int = std::get_if<int32_t>(&found->second)) {
      return static_cast<double>(*as_int);
    }
    if (const auto* as_long = std::get_if<int64_t>(&found->second)) {
      return static_cast<double>(*as_long);
    }
    return fallback;
  };

  const std::string& method = call.method_name();

  if (method == "open") {
    const std::wstring path = Widen(text("path"));
    EncodableMap info;
    if (path.empty() || !ReadInfo(path, &info) || !OpenFile(path)) {
      // Not an error: this machine does not read that sound, and the same file
      // on the other desktop may well play.
      result->Success();
      return;
    }
    result->Success(EncodableValue(info));
    return;
  }

  if (method == "play") {
    if (g_engine) {
      if (g_notify->ended() || g_engine->IsEnded()) {
        // Play on a finished track starts it again. Pressing play and getting
        // silence reads as a broken player.
        g_engine->SetCurrentTime(0);
        g_notify->forget();
      }
      g_engine->Play();
      StartTicking();
      SendTick();
    }
    result->Success();
    return;
  }

  if (method == "pause") {
    if (g_engine) {
      g_engine->Pause();
      SendTick();
      StopTicking();
    }
    result->Success();
    return;
  }

  if (method == "seek") {
    if (g_engine) {
      const double seconds = number("positionMs", 0) / 1000.0;
      const double duration = g_engine->GetDuration();
      const double at = (std::max)(
          0.0, (std::min)(std::isfinite(duration) ? duration : seconds, seconds));
      g_engine->SetCurrentTime(at);
      g_notify->forget();
      SendTick();
    }
    result->Success();
    return;
  }

  if (method == "volume") {
    g_volume = (std::max)(0.0, (std::min)(1.0, number("volume", 1)));
    if (g_engine) g_engine->SetVolume(g_volume);
    result->Success();
    return;
  }

  if (method == "close") {
    CloseFile();
    result->Success();
    return;
  }

  if (method == "envelope") {
    const std::wstring path = Widen(text("path"));
    const int buckets = static_cast<int>(number("buckets", 800));
    // Started here rather than on the sweep's own thread: the platform is one
    // per process, and this is the thread that owns it.
    if (path.empty() || buckets <= 0 || !StartMedia()) {
      result->Success();
      return;
    }
    auto* job = new SweepJob{std::move(result), {}};
    // Off the platform thread: decoding a long file is hundreds of milliseconds
    // and the window must not stop for it. The answer comes back through the
    // pump window, because a channel result belongs to the thread that made it.
    std::thread([path, buckets, job]() {
      DecodeEnvelope(path, buckets, &job->shape);
      ::PostMessage(g_pump, kEnvelopeDone, 0, reinterpret_cast<LPARAM>(job));
    }).detach();
    return;
  }

  if (method == "spectrum") {
    const std::wstring path = Widen(text("path"));
    const int columns = static_cast<int>(number("columns", 1024));
    const int bands = static_cast<int>(number("bands", 48));
    if (path.empty() || columns <= 0 || bands <= 0 || !StartMedia()) {
      result->Success();
      return;
    }
    auto* job = new SweepJob{std::move(result), {}};
    std::thread([path, columns, bands, job]() {
      DecodeSpectrum(path, columns, bands, &job->shape);
      ::PostMessage(g_pump, kEnvelopeDone, 0, reinterpret_cast<LPARAM>(job));
    }).detach();
    return;
  }

  result->NotImplemented();
}

}  // namespace

void RegisterAudioChannel(flutter::FlutterEngine* engine) {
  g_pump = MakePump();

  g_channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      engine->messenger(), kChannelName,
      &flutter::StandardMethodCodec::GetInstance());
  g_channel->SetMethodCallHandler(
      [](const flutter::MethodCall<EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        HandleCall(call, std::move(result));
      });

  g_ticks = std::make_unique<flutter::EventChannel<EncodableValue>>(
      engine->messenger(), kTicksName,
      &flutter::StandardMethodCodec::GetInstance());
  g_ticks->SetStreamHandler(
      std::make_unique<flutter::StreamHandlerFunctions<EncodableValue>>(
          [](const EncodableValue*,
             std::unique_ptr<flutter::EventSink<EncodableValue>>&& sink)
              -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
            g_sink = std::move(sink);
            return nullptr;
          },
          [](const EncodableValue*)
              -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
            g_sink = nullptr;
            return nullptr;
          }));
}
