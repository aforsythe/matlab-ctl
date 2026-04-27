// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Alex Forsythe, Academy of Motion Picture Arts and Sciences

// MEX body: marshal MATLAB arrays into per-channel float buffers,
// run one or more CTL transforms via Ctl::SimdInterpreter, and
// repack the result into a MATLAB output array.
//
// Invocation shapes (called through src/apply_ctl.m, not directly):
//
//   apply_ctl_mex(in, {'foo.ctl'})
//       Load foo.ctl and apply its main().
//   apply_ctl_mex(in, {'foo.ctl', 'bar.ctl'})
//       Chain: foo -> bar, output of each feeds the next.
//   apply_ctl_mex(in, {'foo.ctl'}, overrides)
//       Same, plus a scalar struct of per-parameter overrides
//       keyed by CTL input arg name.
//
// Interpreters are cached across calls in a file-scope
// unordered_map keyed on CTL source path + mtime. The MexFunction
// destructor drops the cache when MATLAB unloads the MEX (clear
// mex or session exit).

#include "mex.hpp"
#include "mexAdapter.hpp"

//
// utIsInterruptPending is an undocumented but long-stable MATLAB
// runtime function exported by libut -- polled inside long MEX
// loops so Ctrl+C can abort the call instead of being silently
// held until return. The header isn't in /extern/include but the
// symbol is always resolvable by MEX link (MATLAB preloads libut
// when loading a MEX).
//
extern "C" bool utIsInterruptPending(void);

#include <CtlInterpreter.h>
#include <CtlFunctionCall.h>
#include <CtlMessage.h>
#include <CtlRcPtr.h>
#include <CtlSimdInterpreter.h>
#include <CtlType.h>
#include <Iex.h>

#include <sys/stat.h>
#include <sys/types.h>

#include <algorithm>
#include <atomic>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

using matlab::mex::ArgumentList;
using namespace matlab::data;

namespace {

//
// ---- Shape handling ----
//

enum class ShapeKind { OneColumn, ThreeColumns, ThreeDim };

struct IOShape
{
    ShapeKind kind;
    std::size_t samples;
    std::size_t rows;
    std::size_t cols;
};

//
// Pick a worker count for parallel MATLAB<->float marshalling. The
// raw-pointer cast loops are memcpy-like bandwidth-bound work; 12
// cores on M4 Max saturate LPDDR5 long before we run out of
// parallelism. Below kParallelMinSamples, thread spawn/join (~200 us
// at 12 workers) costs more than we save.
//
constexpr std::size_t kParallelMinSamples = 32 * 1024;
unsigned marshalWorkers(std::size_t samples)
{
    if (samples < kParallelMinSamples) return 1;
    unsigned hw = std::thread::hardware_concurrency();
    if (hw == 0) hw = 1;
    return hw;
}

//
// Cast three contiguous planes of length N in parallel. Each worker
// takes a disjoint index range and does the same range on all three
// planes -- saves two thread spawn/join cycles over casting the
// planes sequentially, and the per-worker working set (3 x chunk x
// sizeof(SrcT/DstT)) fits comfortably in L2.
//
template <typename SrcT, typename DstT>
void castThreePlanes(const SrcT *s0, const SrcT *s1, const SrcT *s2,
                     DstT *d0, DstT *d1, DstT *d2, std::size_t N)
{
    auto range = [](const SrcT *s, DstT *d, std::size_t lo, std::size_t hi) {
        for (std::size_t i = lo; i < hi; ++i) d[i] = static_cast<DstT>(s[i]);
    };
    const unsigned nw = marshalWorkers(N);
    if (nw <= 1) {
        range(s0, d0, 0, N);
        range(s1, d1, 0, N);
        range(s2, d2, 0, N);
        return;
    }
    const std::size_t chunk = (N + nw - 1) / nw;
    auto worker = [&](unsigned widx) {
        const std::size_t lo = widx * chunk;
        const std::size_t hi = std::min(lo + chunk, N);
        if (lo >= hi) return;
        range(s0, d0, lo, hi);
        range(s1, d1, lo, hi);
        range(s2, d2, lo, hi);
    };
    std::vector<std::thread> pool;
    pool.reserve(nw - 1);
    for (unsigned w = 1; w < nw; ++w) pool.emplace_back(worker, w);
    worker(0);
    for (auto &t : pool) t.join();
}

IOShape classifyShape(const Array &in)
{
    const auto dims = in.getDimensions();
    IOShape s{};
    if (dims.size() == 2)
    {
        s.rows = dims[0];
        s.cols = dims[1];
        if (dims[1] == 1) { s.kind = ShapeKind::OneColumn;    s.samples = dims[0]; }
        else if (dims[1] == 3) { s.kind = ShapeKind::ThreeColumns; s.samples = dims[0]; }
        else throw std::runtime_error(
            "input must be Mx1 (neutral ramp), Mx3 (RGB columns), "
            "or MxNx3 (image)");
    }
    else if (dims.size() == 3)
    {
        if (dims[2] != 3)
            throw std::runtime_error(
                "3-D input must have exactly 3 channels on the third "
                "dimension");
        s.kind = ShapeKind::ThreeDim;
        s.rows = dims[0];
        s.cols = dims[1];
        s.samples = dims[0] * dims[1];
    }
    else
    {
        throw std::runtime_error("input must be 2-D or 3-D");
    }
    return s;
}

template <typename SrcT>
void extractChannels(const TypedArray<SrcT> &view,
                     const IOShape &shape,
                     std::vector<float> &R,
                     std::vector<float> &G,
                     std::vector<float> &B)
{
    R.resize(shape.samples);
    G.resize(shape.samples);
    B.resize(shape.samples);

    //
    // TypedIterator::operator* goes through an out-of-line dispatch
    // that doesn't inline across the MATLAB cppmex boundary (measured
    // ~80 ns/element on double inputs). For a contiguous column-major
    // array the iterator's underlying storage *is* a raw pointer, so
    // we grab it once via `&*begin()` and index it directly. Tight
    // `static_cast<float>(src[i])` auto-vectorizes to SIMD loads on
    // both x86_64 and arm64, and castThreePlanes splits the work
    // across hardware_concurrency() threads above kParallelMinSamples.
    //
    const SrcT *src = &(*view.begin());

    if (shape.kind == ShapeKind::OneColumn)
    {
        for (std::size_t i = 0; i < shape.samples; ++i)
        {
            const float v = static_cast<float>(src[i]);
            R[i] = v;
            G[i] = v;
            B[i] = v;
        }
        return;
    }

    const std::size_t stride = shape.samples;
    castThreePlanes<SrcT, float>(
        src, src + stride, src + 2 * stride,
        R.data(), G.data(), B.data(), stride);
}

Array packOutput(const IOShape &shape,
                 const std::vector<float> &R,
                 const std::vector<float> &G,
                 const std::vector<float> &B)
{
    ArrayFactory f;

    //
    // Output is always 3-channel. Mx1 input was replicated to R=G=B
    // on entry, but the CTL main() can produce a non-neutral result
    // -- e.g. a matrix whose rows don't sum equally, a chromatic
    // adaptation, a gamut-mapping stage. Returning only G would
    // silently hide that. Callers who know their transform is gray-
    // preserving can slice the G column themselves.
    //
    ArrayDimensions dims;
    switch (shape.kind)
    {
        case ShapeKind::OneColumn:    dims = {shape.rows, 3};            break;
        case ShapeKind::ThreeColumns: dims = {shape.rows, 3};            break;
        case ShapeKind::ThreeDim:     dims = {shape.rows, shape.cols, 3}; break;
    }
    TypedArray<double> out = f.createArray<double>(dims);
    // Same pointer trick as extractChannels -- iterator dereference
    // isn't inlined across the cppmex boundary.
    double *dst = &(*out.begin());

    const std::size_t stride = shape.samples;
    castThreePlanes<float, double>(
        R.data(), G.data(), B.data(),
        dst, dst + stride, dst + 2 * stride, stride);
    return out;
}

//
// ---- Interpreter cache ----
//
// Persistent across MEX calls. Keyed by absolute path of the .ctl
// file, so two callers asking for the same file share the loaded
// interpreter. The MexFunction destructor drops the cache when
// MATLAB unloads the MEX (e.g. on `clear mex` or session exit).
//
// A Ctl::Interpreter holds module state (parsed syntax tree,
// symbol table, instruction stream for SIMD backends) that's
// expensive to rebuild -- ACES v2 modules take ~150-400 ms to
// parse + codegen on first load. Caching turns that into a
// one-time cost per session.
//
// Cache entries track the .ctl file's mtime at load time. A stale
// entry (file edited on disk since load) is evicted and reloaded on
// next access, so iterative CTL development in MATLAB -- edit, save,
// re-run -- picks up the new source without needing `clear mex`.
//

struct CachedInterp
{
    std::unique_ptr<Ctl::SimdInterpreter> interp;
    time_t     mtime_sec;
    long       mtime_nsec;
};

using InterpMap = std::unordered_map<std::string, CachedInterp>;

InterpMap &interpCache()
{
    static InterpMap m;
    return m;
}

void cleanupCache()
{
    interpCache().clear();
}

//
// Derive a CTL module name from a file path: basename without the
// `.ctl` extension. Mirrors ctlrender's convention so the module
// name we load matches how the file self-declares itself if it has
// a `namespace` / top-level declaration.
//
std::string moduleNameFromPath(const std::string &path)
{
    std::string mod = path;
    auto slash = mod.find_last_of("/\\");
    if (slash != std::string::npos) mod = mod.substr(slash + 1);
    auto dot = mod.find_last_of('.');
    if (dot != std::string::npos) mod.resize(dot);
    return mod;
}

//
// Read mtime (seconds + nanoseconds) from a path. Throws on stat
// failure with a MATLAB-friendly message so the user sees "file not
// found" rather than the CTL interpreter's later complaint about
// loadFile.
//
void statMtime(const std::string &path,
               time_t &sec, long &nsec)
{
    struct stat st{};
    if (::stat(path.c_str(), &st) != 0)
        throw std::runtime_error(
            std::string("cannot stat CTL file: ") + path);
    sec = st.st_mtime;
#if defined(__APPLE__)
    nsec = st.st_mtimespec.tv_nsec;
#else
    nsec = st.st_mtim.tv_nsec;
#endif
}

//
// Refresh the interpreter's module search path from the
// CTL_MODULE_PATH environment variable, mirroring ctlrender's
// behaviour. Called on every cache-miss load so the env var stays
// authoritative for the rest of the MATLAB session -- the base
// Interpreter reads the env only once (static first-time guard),
// so users who setenv() after the MEX has already loaded a .ctl
// would otherwise see stale paths.
//
void applyCtlModulePath()
{
    const char *env = std::getenv("CTL_MODULE_PATH");
    if (!env || !*env) return;  // leave current paths alone

    std::vector<std::string> paths;
    std::string s = env;
    std::size_t pos = 0;
    while (pos <= s.size()) {
        std::size_t sep = s.find(':', pos);
        if (sep == std::string::npos) sep = s.size();
        if (sep > pos)
            paths.emplace_back(s.substr(pos, sep - pos));
        if (sep == s.size()) break;
        pos = sep + 1;
    }
    if (!paths.empty())
        Ctl::Interpreter::setModulePaths(paths);
}

//
// CTL diagnostics capture. The upstream library writes parse and
// import errors via its `MessageOutputFunction` callback (default:
// std::cerr) and then throws a follow-up exception. The exception
// itself is uninformative (e.g. "Failed to load CTL module" or
// "Cannot find CTL function main."); the *useful* line ("Cannot
// find CTL module \"X\".") only reaches the callback. Hooking the
// callback lets us splice that detail into the matlabctl:ctl error
// instead of letting it leak to a stderr nobody's watching.
//
// Buffer is thread_local so chunk-parallel CTL print() calls don't
// race on a shared string. We only inspect the main-thread buffer
// here (load and apply both run on the main MEX thread); worker
// threads have their own buffer that nobody drains, which means
// CTL print() output from worker code isn't preserved -- a small
// regression deemed acceptable for the much more common case of
// surfacing import / parse errors.
//
std::string &messageBuffer() noexcept
{
    thread_local std::string buf;
    return buf;
}

void captureMessage(const std::string &msg)
{
    messageBuffer() += msg;
}

class MessageScope
{
public:
    MessageScope() noexcept
    {
        messageBuffer().clear();
        prev_ = Ctl::setMessageOutputFunction(captureMessage);
    }

    ~MessageScope() noexcept
    {
        Ctl::setMessageOutputFunction(prev_);
        messageBuffer().clear();
    }

    MessageScope(const MessageScope &) = delete;
    MessageScope &operator=(const MessageScope &) = delete;

    //
    // Return everything captured so far and empty the buffer.
    //
    std::string drain() noexcept
    {
        std::string out;
        out.swap(messageBuffer());
        return out;
    }

private:
    Ctl::MessageOutputFunction prev_ = nullptr;
};

//
// Strip ASCII whitespace from both ends of S. Used when splicing
// captured stderr into a user-facing error: the upstream messages
// usually end with a newline we don't want in the matlabctl error.
//
std::string trimWhitespace(const std::string &s)
{
    const auto isWs = [](unsigned char c) {
        return c == ' ' || c == '\t' || c == '\n' || c == '\r';
    };
    std::size_t a = 0, b = s.size();
    while (a < b && isWs(static_cast<unsigned char>(s[a]))) ++a;
    while (b > a && isWs(static_cast<unsigned char>(s[b - 1]))) --b;
    return s.substr(a, b - a);
}

Ctl::SimdInterpreter &getOrLoadInterpreter(const std::string &path)
{
    time_t sec = 0; long nsec = 0;
    statMtime(path, sec, nsec);

    auto &cache = interpCache();
    auto it = cache.find(path);
    if (it != cache.end()) {
        if (it->second.mtime_sec == sec &&
            it->second.mtime_nsec == nsec)
            return *it->second.interp;
        // File edited since cached -- drop and reload below.
        cache.erase(it);
    }

    // Only matters when the CTL being loaded has `import` statements
    // (ACES v2 OutputTransform being the main use case). Applied
    // before loadFile so the interpreter's import resolver sees
    // the current env.
    applyCtlModulePath();

    auto interp = std::make_unique<Ctl::SimdInterpreter>();
    const std::string mod = moduleNameFromPath(path);
    if (!interp->moduleIsLoaded(mod))
        interp->loadFile(path, mod);

    CachedInterp entry{std::move(interp), sec, nsec};
    auto [inserted, ok] = cache.emplace(path, std::move(entry));
    (void)ok;
    return *inserted->second.interp;
}

//
// Write a scalar value to a uniform arg in the form its CTL type
// expects. Supports float, int, half, and bool -- the scalar types
// that can be bound from a single MATLAB numeric.
//
void writeScalarUniform(Ctl::FunctionArgPtr arg, double value)
{
    char *p = arg->data();
    const Ctl::DataTypePtr &t = arg->type();
    if (t.cast<Ctl::FloatType>())
        *reinterpret_cast<float *>(p) = static_cast<float>(value);
    else if (t.cast<Ctl::IntType>())
        *reinterpret_cast<int *>(p) = static_cast<int>(value);
    else if (t.cast<Ctl::UIntType>())
        *reinterpret_cast<unsigned int *>(p) =
            static_cast<unsigned int>(value);
    else if (t.cast<Ctl::BoolType>())
        *reinterpret_cast<bool *>(p) = (value != 0.0);
    else
        throw std::runtime_error(
            std::string("param '") + arg->name() +
            "': cannot override type " + t->asString() +
            " from a scalar numeric");
}

//
// Levenshtein edit distance on two ASCII names, clamped to a small
// cutoff so we can short-circuit long strings. Used for the "did
// you mean?" hint on unknown-override errors.
//
std::size_t editDistance(const std::string &a, const std::string &b,
                         std::size_t cutoff)
{
    const std::size_t la = a.size(), lb = b.size();
    if (la > lb + cutoff || lb > la + cutoff) return cutoff + 1;
    std::vector<std::size_t> prev(lb + 1), curr(lb + 1);
    for (std::size_t j = 0; j <= lb; ++j) prev[j] = j;
    for (std::size_t i = 1; i <= la; ++i) {
        curr[0] = i;
        std::size_t rowMin = curr[0];
        for (std::size_t j = 1; j <= lb; ++j) {
            const std::size_t cost = (a[i-1] == b[j-1]) ? 0 : 1;
            curr[j] = std::min({prev[j]     + 1,
                                curr[j-1]   + 1,
                                prev[j-1]   + cost});
            if (curr[j] < rowMin) rowMin = curr[j];
        }
        if (rowMin > cutoff) return cutoff + 1;
        std::swap(prev, curr);
    }
    return prev[lb];
}

//
// Broadcast a scalar value across a varying arg's buffer, for N
// samples. Only float is supported for varying overrides today
// (the common case -- alpha, exposure-per-pixel are both float).
//
void fillScalarVarying(Ctl::FunctionArgPtr arg, double value,
                       std::size_t N)
{
    const Ctl::DataTypePtr &t = arg->type();
    if (!t.cast<Ctl::FloatType>())
        throw std::runtime_error(
            std::string("param '") + arg->name() +
            "': varying override must be float (got " +
            t->asString() + ")");
    float *buf = reinterpret_cast<float *>(arg->data());
    const float v = static_cast<float>(value);
    for (std::size_t i = 0; i < N; ++i) buf[i] = v;
}

//
// Apply one CTL stage to R/G/B in place. Assumes the top-level
// entry is `main` with three input varying floats (rIn/gIn/bIn) and
// three output varying floats (rOut/gOut/bOut). Extra args beyond
// those three are handled by this policy:
//
//   1. If OVERRIDES contains the arg's name, apply the value
//      (uniform or varying depending on how the CTL declared it).
//   2. Else if the arg is a declared-varying float named "aIn",
//      auto-default to 1.0 (ACES convention: alpha passes through
//      as opaque when the caller isn't carrying alpha).
//   3. Else if the arg has a CTL-side default value, it fires
//      automatically on callFunction.
//   4. Else raise an error naming the missing parameter.
//
// Output args beyond rOut/gOut/bOut (e.g. aOut) are set varying so
// the interpreter has somewhere to write them; we don't read them
// back into MATLAB.
//
// Parallel dispatch: input is split into interp.maxSamples()-sized
// chunks; nworkers = min(hardware_concurrency, nchunks) threads
// each own one FunctionCall and pull chunks off a shared atomic
// counter. Matches ctlrender's Phase B tile dispatch -- the same
// pattern against the same libIlmCtl, so we know concurrent
// FunctionCalls from one interpreter are safe.
//
void applyCtlStage(Ctl::SimdInterpreter &interp,
                   const std::map<std::string, double> &overrides,
                   std::set<std::string> &consumedParams,
                   std::set<std::string> &dataArgNames,
                   std::set<std::string> &extraArgNames,
                   std::vector<float> &R,
                   std::vector<float> &G,
                   std::vector<float> &B)
{
    const std::size_t total = R.size();
    if (total == 0) return;  // Empty input: nothing to transform.

    const std::size_t chunk = interp.maxSamples();
    if (chunk == 0)
        throw std::runtime_error(
            "CTL interpreter reported maxSamples() == 0");
    const std::size_t nchunks = (total + chunk - 1) / chunk;

    unsigned hw = std::thread::hardware_concurrency();
    if (hw == 0) hw = 1;
    const unsigned nworkers =
        static_cast<unsigned>(std::min<std::size_t>(hw, nchunks));

    struct VaryingBroadcast { Ctl::FunctionArgPtr arg; double value; };
    struct Worker {
        Ctl::FunctionCallPtr fn;
        std::vector<VaryingBroadcast> varyingBroadcasts;
    };
    std::vector<Worker> workers(nworkers);

    //
    // Per-worker setup: create a FunctionCall, populate dataArgNames
    // and consumedParams (only on worker 0 -- same interpreter, same
    // signature), bind uniform overrides once on this worker's own
    // scratch, and record varying overrides for per-chunk broadcast.
    //
    for (unsigned w = 0; w < nworkers; ++w) {
        Ctl::FunctionCallPtr fn = interp.newFunctionCall("main");
        if (fn->numInputArgs() < 3 || fn->numOutputArgs() < 3)
            throw std::runtime_error(
                "CTL main() must have at least 3 input and 3 output "
                "varying float params (rIn/gIn/bIn -> rOut/gOut/bOut)");

        if (w == 0) {
            for (std::size_t i = 0; i < 3; ++i)
                dataArgNames.insert(fn->inputArg(i)->name());
        }

        for (std::size_t i = 3; i < fn->numInputArgs(); ++i) {
            Ctl::FunctionArgPtr arg = fn->inputArg(i);
            const std::string name = arg->name();
            const bool declaredVarying = arg->isVarying();

            if (w == 0) extraArgNames.insert(name);

            auto it = overrides.find(name);
            if (it != overrides.end()) {
                if (w == 0) consumedParams.insert(name);
                if (declaredVarying) {
                    arg->setVarying(true);
                    workers[w].varyingBroadcasts.push_back({arg, it->second});
                } else {
                    arg->setVarying(false);
                    writeScalarUniform(arg, it->second);
                }
                continue;
            }

            if (declaredVarying && name == "aIn") {
                arg->setVarying(true);
                workers[w].varyingBroadcasts.push_back({arg, 1.0});
                continue;
            }

            if (!arg->hasDefaultValue()) {
                std::string msg =
                    std::string("CTL main() input '") + name +
                    "' has no default value. Pass a value as a "
                    "trailing Name=Value argument to apply_ctl, "
                    "e.g. " + name + "=1.0.";
                // If the caller passed a near-match override, flag
                // it as the likely typo so they don't have to hunt.
                const std::size_t cutoff =
                    std::max<std::size_t>(2, name.size() / 3);
                for (const auto &kv : overrides) {
                    if (kv.first == name) continue;
                    if (editDistance(kv.first, name, cutoff) <= cutoff) {
                        msg += " (You passed '" + kv.first +
                               "' -- did you mean '" + name + "'?)";
                        break;
                    }
                }
                throw std::runtime_error(msg);
            }
        }

        for (std::size_t i = 0; i < 3; ++i) fn->inputArg(i)->setVarying(true);
        for (std::size_t i = 0; i < 3; ++i) fn->outputArg(i)->setVarying(true);
        for (std::size_t i = 3; i < fn->numOutputArgs(); ++i)
            fn->outputArg(i)->setVarying(true);

        workers[w].fn = fn;
    }

    std::vector<float> *planes[3] = {&R, &G, &B};
    std::atomic<std::size_t> nextChunk(0);
    std::atomic<bool>        aborted(false);
    std::mutex               errMutex;
    std::exception_ptr       firstErr;

    auto workerLoop = [&](unsigned widx) {
        try {
            Ctl::FunctionCall *fn = workers[widx].fn.pointer();
            const auto &vbs = workers[widx].varyingBroadcasts;
            while (!aborted.load(std::memory_order_relaxed)) {
                //
                // Poll Ctrl+C between chunks. Without this a long
                // ACES-class call at 4K+ is effectively uninterrupt-
                // ible: MATLAB only processes the interrupt when the
                // MEX returns, which could be seconds away.
                //
                // Only worker 0 polls -- utIsInterruptPending reads
                // libut's thread-local interrupt context, which
                // exists on MATLAB's main thread (worker 0, which
                // runs inline) but not on spawned std::threads. A
                // call from any other worker asserts in libut.
                // That's fine: worker 0 sees the interrupt, sets
                // the shared abort flag, and every other worker
                // bails at the next loop iteration.
                //
                if (widx == 0 && utIsInterruptPending()) {
                    aborted.store(true, std::memory_order_relaxed);
                    return;
                }
                const std::size_t k =
                    nextChunk.fetch_add(1, std::memory_order_relaxed);
                if (k >= nchunks) return;
                const std::size_t offset = k * chunk;
                const std::size_t N = std::min(chunk, total - offset);
                for (std::size_t i = 0; i < 3; ++i) {
                    float *dst =
                        reinterpret_cast<float *>(fn->inputArg(i)->data());
                    std::memcpy(dst, planes[i]->data() + offset,
                                N * sizeof(float));
                }
                for (const auto &vb : vbs)
                    fillScalarVarying(vb.arg, vb.value, N);
                fn->callFunction(N);
                for (std::size_t i = 0; i < 3; ++i) {
                    const float *src = reinterpret_cast<const float *>(
                        fn->outputArg(i)->data());
                    std::memcpy(planes[i]->data() + offset, src,
                                N * sizeof(float));
                }
            }
        } catch (...) {
            std::lock_guard<std::mutex> lock(errMutex);
            if (!firstErr) firstErr = std::current_exception();
            aborted.store(true, std::memory_order_relaxed);
        }
    };

    if (nworkers <= 1) {
        workerLoop(0);
    } else {
        std::vector<std::thread> pool;
        pool.reserve(nworkers - 1);
        for (unsigned w = 1; w < nworkers; ++w)
            pool.emplace_back(workerLoop, w);
        workerLoop(0);
        for (auto &t : pool) t.join();
    }

    if (firstErr) std::rethrow_exception(firstErr);
    // If workers aborted because of a pending interrupt but no
    // exception was captured, surface a clean error so the wrapper
    // layer rethrows to MATLAB as an interruption rather than
    // silently returning partial output.
    if (aborted.load(std::memory_order_relaxed))
        throw std::runtime_error(
            "apply_ctl interrupted (Ctrl+C pressed during dispatch)");
}

//
// Parse inputs[1] as a cell array of paths.
//
std::vector<std::string> extractPaths(const Array &cell)
{
    std::vector<std::string> paths;
    if (cell.getType() != ArrayType::CELL)
        throw std::runtime_error(
            "apply_ctl_mex: second argument must be a cell array of "
            ".ctl file paths (or omitted for pass-through)");
    CellArray c(cell);
    for (std::size_t i = 0; i < c.getNumberOfElements(); ++i) {
        const Array &element = c[i];
        if (element.getType() != ArrayType::CHAR)
            throw std::runtime_error(
                "every cell in the paths argument must be a string");
        CharArray s(element);
        paths.push_back(s.toAscii());
    }
    return paths;
}

//
// Build a MATLAB struct describing a CTL main()'s input/output
// signature. Used by the `get_ctl_signature` MATLAB wrapper for
// introspection / help.
//
Array buildSignatureStruct(const std::string &path)
{
    Ctl::SimdInterpreter &interp = getOrLoadInterpreter(path);
    Ctl::FunctionCallPtr fn = interp.newFunctionCall("main");

    ArrayFactory f;

    auto packArg = [&](Ctl::FunctionArgPtr arg, bool includeHasDefault,
                       StructArray &dst, std::size_t idx)
    {
        dst[idx]["Name"]    = f.createCharArray(arg->name());
        dst[idx]["Type"]    = f.createCharArray(arg->type()->asString());
        dst[idx]["Varying"] = f.createScalar(arg->isVarying());
        if (includeHasDefault)
            dst[idx]["HasDefault"] =
                f.createScalar(arg->hasDefaultValue());
    };

    StructArray inArr = f.createStructArray(
        {1, fn->numInputArgs()},
        {"Name", "Type", "Varying", "HasDefault"});
    for (std::size_t i = 0; i < fn->numInputArgs(); ++i)
        packArg(fn->inputArg(i), /*includeHasDefault*/ true, inArr, i);

    StructArray outArr = f.createStructArray(
        {1, fn->numOutputArgs()},
        {"Name", "Type", "Varying"});
    for (std::size_t i = 0; i < fn->numOutputArgs(); ++i)
        packArg(fn->outputArg(i), /*includeHasDefault*/ false, outArr, i);

    StructArray sig = f.createStructArray({1, 1},
        {"Path", "Inputs", "Outputs"});
    sig[0]["Path"]    = f.createCharArray(path);
    sig[0]["Inputs"]  = std::move(inArr);
    sig[0]["Outputs"] = std::move(outArr);
    return sig;
}

//
// Build a MATLAB struct array describing every interpreter
// currently in the process-wide cache. One entry per CTL path,
// with the (sec, nsec) mtime it was loaded with so stale caches
// are easy to diagnose ("did my edit take effect?").
//
Array buildCacheInfoStruct()
{
    ArrayFactory f;
    const auto &cache = interpCache();
    StructArray arr = f.createStructArray(
        {1, cache.size()},
        {"Path", "MtimeSec", "MtimeNsec"});
    std::size_t i = 0;
    for (const auto &kv : cache) {
        arr[i]["Path"]      = f.createCharArray(kv.first);
        arr[i]["MtimeSec"]  =
            f.createScalar(static_cast<double>(kv.second.mtime_sec));
        arr[i]["MtimeNsec"] =
            f.createScalar(static_cast<double>(kv.second.mtime_nsec));
        ++i;
    }
    return arr;
}

//
// Parse inputs[2] as a MATLAB struct whose fields are scalar
// numerics; each (name, value) becomes a uniform/varying override
// keyed by parameter name.
//
std::map<std::string, double> extractOverrides(const Array &s)
{
    std::map<std::string, double> out;
    if (s.isEmpty()) return out;
    if (s.getType() != ArrayType::STRUCT)
        throw std::runtime_error(
            "apply_ctl_mex: third argument (param overrides) must be "
            "a struct whose fields are scalar numerics");
    StructArray sa(s);
    if (sa.getNumberOfElements() != 1)
        throw std::runtime_error(
            "apply_ctl_mex: param-overrides struct must be scalar");
    for (const auto &name : sa.getFieldNames()) {
        const Array v = sa[0][std::string(name)];
        if (v.getNumberOfElements() != 1)
            throw std::runtime_error(
                std::string("Params field '") + std::string(name) +
                "' must be a scalar numeric value");
        double value = 0.0;
        switch (v.getType()) {
            case ArrayType::DOUBLE:
                value = TypedArray<double>(v)[0]; break;
            case ArrayType::SINGLE:
                value = static_cast<double>(TypedArray<float>(v)[0]); break;
            case ArrayType::INT32:
                value = static_cast<double>(TypedArray<int32_t>(v)[0]); break;
            case ArrayType::LOGICAL:
                value = TypedArray<bool>(v)[0] ? 1.0 : 0.0; break;
            default:
                throw std::runtime_error(
                    std::string("Params field '") + std::string(name) +
                    "' must be double, single, int32, or logical");
        }
        out[std::string(name)] = value;
    }
    return out;
}

} // anonymous namespace

class MexFunction : public matlab::mex::Function
{
public:
    ~MexFunction() override
    {
        //
        // Drop the interpreter cache when MATLAB unloads this MEX
        // (via `clear mex` or session shutdown). The static
        // unordered_map's own destructor would also free the
        // interpreters when the shared library is dlclose'd, but
        // calling here is explicit and runs *before* the CTL
        // libraries' own global destructors, avoiding any order-
        // of-destruction surprises.
        //
        cleanupCache();
    }

    void operator()(ArgumentList outputs, ArgumentList inputs)
    {
        if (inputs.size() < 1 || inputs.size() > 3)
            reportError("matlabctl:arg",
                        "apply_ctl_mex expects 1, 2, or 3 inputs");

        //
        // Command-string dispatch: a char-vector first argument is
        // a subcommand name rather than the usual numeric input.
        // Subcommands today:
        //   'signature'  <path>  -> struct describing a CTL's main()
        //   'cache-info'         -> struct array listing cached
        //                           interpreters + their mtimes
        //
        if (inputs[0].getType() == ArrayType::CHAR) {
            const std::string cmd = CharArray(inputs[0]).toAscii();
            if (cmd == "cache-info") {
                if (outputs.size() > 0)
                    outputs[0] = buildCacheInfoStruct();
                return;
            }
            if (cmd == "signature") {
                if (inputs.size() != 2 ||
                    inputs[1].getType() != ArrayType::CHAR) {
                    reportError("matlabctl:arg",
                        "apply_ctl_mex('signature', <path>) requires "
                        "a .ctl path as the second argument");
                    return;
                }
                const std::string path =
                    CharArray(inputs[1]).toAscii();
                MessageScope cap;
                try {
                    if (outputs.size() > 0)
                        outputs[0] = buildSignatureStruct(path);
                    std::string warns = cap.drain();
                    if (!warns.empty())
                        std::fwrite(warns.data(), 1, warns.size(),
                                    stderr);
                }
                catch (const Iex::BaseExc &e) {
                    std::string detail = e.what();
                    std::string captured = trimWhitespace(cap.drain());
                    if (!captured.empty())
                        detail = captured + "; " + detail;
                    reportError("matlabctl:ctl",
                        std::string("CTL error loading '") + path +
                        "': " + detail);
                }
                catch (const std::runtime_error &e) {
                    std::string detail = e.what();
                    std::string captured = trimWhitespace(cap.drain());
                    if (!captured.empty())
                        detail = captured + "; " + detail;
                    reportError("matlabctl:ctl",
                        std::string("error loading '") + path +
                        "': " + detail);
                }
                return;
            }
            reportError("matlabctl:arg",
                        std::string("apply_ctl_mex: unknown subcommand '")
                        + cmd + "'");
            return;
        }

        const Array &in = inputs[0];
        if (in.getType() != ArrayType::DOUBLE &&
            in.getType() != ArrayType::SINGLE)
            reportError("matlabctl:arg",
                        "input must be double or single");

        IOShape shape{};
        std::vector<std::string> paths;
        std::map<std::string, double> overrides;
        try {
            shape = classifyShape(in);
            if (inputs.size() >= 2) paths     = extractPaths(inputs[1]);
            if (inputs.size() >= 3) overrides = extractOverrides(inputs[2]);
        }
        catch (const std::runtime_error &e) {
            reportError("matlabctl:arg", e.what());
            return;
        }

        std::vector<float> R, G, B;
        if (in.getType() == ArrayType::DOUBLE)
            extractChannels(TypedArray<double>(in), shape, R, G, B);
        else
            extractChannels(TypedArray<float>(in), shape, R, G, B);

        //
        // Run each CTL stage in order, feeding the output of stage N
        // into the input of stage N+1 via the R/G/B buffers.
        // `consumedParams` tracks which override keys matched an
        // extra (overridable) input on some stage, and
        // `dataArgNames` collects the names of the first three
        // inputs -- so the post-loop check below can split typos
        // ("no stage declares this name") from data-arg collisions
        // ("this name is one of the first three inputs, bound to
        // R/G/B of the input array").
        //
        std::set<std::string> consumedParams;
        std::set<std::string> dataArgNames;
        std::set<std::string> extraArgNames;
        for (const auto &path : paths) {
            //
            // Capture stderr across BOTH the load and apply steps:
            // an `import` failure prints "Cannot find CTL module
            // ..." to stderr during loadFile but does NOT throw
            // there -- it throws later from applyCtlStage as the
            // generic "Cannot find CTL function main." So we keep
            // the capture alive across the whole stage and splice
            // any captured bytes into whichever error fires.
            //
            // Successful stages get their captured stderr re-emitted
            // verbatim, so CTL `print()` output and warnings still
            // reach the terminal in the normal case.
            //
            MessageScope cap;
            try {
                Ctl::SimdInterpreter &interp =
                    getOrLoadInterpreter(path);
                applyCtlStage(interp, overrides, consumedParams,
                              dataArgNames, extraArgNames, R, G, B);
                std::string warns = cap.drain();
                if (!warns.empty())
                    std::fwrite(warns.data(), 1, warns.size(), stderr);
            }
            catch (const Iex::BaseExc &e) {
                std::string detail = e.what();
                std::string captured = trimWhitespace(cap.drain());
                if (!captured.empty())
                    detail = captured + "; " + detail;
                reportError("matlabctl:ctl",
                    std::string("CTL error in '") + path + "': " +
                    detail);
                return;
            }
            catch (const std::runtime_error &e) {
                std::string detail = e.what();
                std::string captured = trimWhitespace(cap.drain());
                if (!captured.empty())
                    detail = captured + "; " + detail;
                reportError("matlabctl:ctl",
                    std::string("error applying '") + path + "': " +
                    detail);
                return;
            }
        }

        // Split leftover override names into two buckets so the
        // error tells the user *which* kind of mistake they made:
        //
        //   dataCollision  -- name matches one of the first three
        //                     CTL inputs (R/G/B of IN). These are
        //                     set from the input array, not from
        //                     Name=Value.
        //   unknownName    -- name matches no declared CTL input;
        //                     almost always a typo.
        //
        std::vector<std::string> dataCollision, unknownName;
        for (const auto &kv : overrides) {
            if (consumedParams.count(kv.first)) continue;
            if (dataArgNames.count(kv.first))
                dataCollision.push_back(kv.first);
            else
                unknownName.push_back(kv.first);
        }
        if (!dataCollision.empty()) {
            std::string msg = "cannot set ";
            for (std::size_t i = 0; i < dataCollision.size(); ++i) {
                if (i) msg += ", ";
                msg += dataCollision[i];
            }
            msg += " via Name=Value; the first three CTL inputs "
                   "(typically rIn/gIn/bIn) are bound to the R, G, "
                   "B planes of the input array. Change IN to "
                   "change those values.";
            reportError("matlabctl:arg", msg);
            return;
        }
        if (!unknownName.empty()) {
            std::string msg = "unknown parameter name(s): ";
            for (std::size_t i = 0; i < unknownName.size(); ++i) {
                if (i) msg += ", ";
                msg += unknownName[i];
            }
            // For each offender, pick the closest declared name
            // within a small edit distance and suggest it. If
            // none are close, just list all declared extras so
            // the caller can see what's actually available.
            std::vector<std::string> suggestions;
            for (const auto &bad : unknownName) {
                const std::size_t cutoff =
                    std::max<std::size_t>(2, bad.size() / 3);
                std::string best;
                std::size_t bestD = cutoff + 1;
                for (const auto &cand : extraArgNames) {
                    std::size_t d = editDistance(bad, cand, cutoff);
                    if (d < bestD) { bestD = d; best = cand; }
                }
                if (!best.empty() && bestD <= cutoff)
                    suggestions.push_back("'" + bad + "' -> '" + best + "'");
            }
            if (!suggestions.empty()) {
                msg += ". Did you mean: ";
                for (std::size_t i = 0; i < suggestions.size(); ++i) {
                    if (i) msg += ", ";
                    msg += suggestions[i];
                }
                msg += "?";
            } else if (!extraArgNames.empty()) {
                msg += ". Declared overridable inputs across the chain: ";
                bool first = true;
                for (const auto &n : extraArgNames) {
                    if (!first) msg += ", ";
                    msg += n;
                    first = false;
                }
                msg += ".";
            } else {
                msg += ". No CTL stage in the chain declares "
                       "overridable inputs beyond the R/G/B triplet.";
            }
            reportError("matlabctl:arg", msg);
            return;
        }

        Array packed = packOutput(shape, R, G, B);
        if (outputs.size() > 0)
            outputs[0] = std::move(packed);
    }

private:
    void reportError(const std::string &id, const std::string &msg)
    {
        ArrayFactory f;
        getEngine()->feval(u"error", 0,
            std::vector<Array>{
                f.createScalar(id),
                f.createScalar(msg)});
    }
};
