#include <jni.h>
#include <llama.h>

#include <atomic>
#include <cstdint>
#include <mutex>
#include <random>
#include <string>
#include <vector>

namespace {
struct LocalSession {
    llama_model *model = nullptr;
    llama_context *context = nullptr;
    const llama_vocab *vocab = nullptr;
    std::atomic<bool> cancelled{false};
    std::mutex generation_mutex;
};

std::once_flag backend_once;

void throw_java(JNIEnv *env, const char *message) {
    jclass type = env->FindClass("java/lang/IllegalStateException");
    if (type != nullptr) env->ThrowNew(type, message);
}

size_t complete_utf8_prefix(const std::string &text) {
    size_t i = 0;
    while (i < text.size()) {
        const auto first = static_cast<unsigned char>(text[i]);
        size_t width = first < 0x80 ? 1 : (first & 0xe0) == 0xc0 ? 2
                              : (first & 0xf0) == 0xe0 ? 3
                              : (first & 0xf8) == 0xf0 ? 4 : 1;
        if (i + width > text.size()) break;
        bool valid = true;
        for (size_t j = 1; j < width; ++j) {
            if ((static_cast<unsigned char>(text[i + j]) & 0xc0) != 0x80) {
                valid = false;
                break;
            }
        }
        i += valid ? width : 1;
    }
    return i;
}

void emit_utf8(JNIEnv *env, jobject sink, jmethodID on_token, std::string &pending,
               bool flush) {
    size_t length = flush ? pending.size() : complete_utf8_prefix(pending);
    if (length == 0) return;
    jstring piece = env->NewStringUTF(pending.substr(0, length).c_str());
    if (piece != nullptr) {
        env->CallVoidMethod(sink, on_token, piece);
        env->DeleteLocalRef(piece);
    }
    if (env->ExceptionCheck()) return;
    pending.erase(0, length);
}

std::string format_chat(JNIEnv *env, const llama_model *model, jobjectArray roles,
                        jobjectArray contents) {
    const jsize count = env->GetArrayLength(roles);
    if (count != env->GetArrayLength(contents) || count == 0) {
        throw_java(env, "La conversación local está vacía o no es válida.");
        return {};
    }
    std::vector<std::string> role_strings(static_cast<size_t>(count));
    std::vector<std::string> content_strings(static_cast<size_t>(count));
    std::vector<llama_chat_message> messages(static_cast<size_t>(count));
    for (jsize i = 0; i < count; ++i) {
        auto role = static_cast<jstring>(env->GetObjectArrayElement(roles, i));
        auto content = static_cast<jstring>(env->GetObjectArrayElement(contents, i));
        const char *role_chars = env->GetStringUTFChars(role, nullptr);
        const char *content_chars = env->GetStringUTFChars(content, nullptr);
        role_strings[static_cast<size_t>(i)] = role_chars;
        content_strings[static_cast<size_t>(i)] = content_chars;
        env->ReleaseStringUTFChars(role, role_chars);
        env->ReleaseStringUTFChars(content, content_chars);
        env->DeleteLocalRef(role);
        env->DeleteLocalRef(content);
        messages[static_cast<size_t>(i)] = {
            role_strings[static_cast<size_t>(i)].c_str(),
            content_strings[static_cast<size_t>(i)].c_str(),
        };
    }

    // Select the template embedded in this exact GGUF and let the pinned
    // llama.cpp template parser render the recognized Qwen ChatML family; never
    // fall back to manually concatenated role delimiters.
    const char *chat_template = llama_model_chat_template(model, nullptr);
    if (chat_template == nullptr) {
        throw_java(env, "El GGUF no contiene una plantilla de conversación.");
        return {};
    }
    const int32_t required = llama_chat_apply_template(
        chat_template, messages.data(), messages.size(), true, nullptr, 0);
    if (required <= 0) {
        throw_java(env, "llama.cpp no reconoce la plantilla del GGUF Qwen.");
        return {};
    }
    std::string prompt(static_cast<size_t>(required) + 1, '\0');
    const int32_t written = llama_chat_apply_template(
        chat_template, messages.data(), messages.size(), true, prompt.data(),
        static_cast<int32_t>(prompt.size()));
    if (written < 0 || written > required) {
        throw_java(env, "No se pudo aplicar la plantilla de conversación del GGUF.");
        return {};
    }
    prompt.resize(static_cast<size_t>(written));
    return prompt;
}
} // namespace

extern "C" JNIEXPORT jlong JNICALL
Java_app_chronoxai_MainActivity_nativeLoadModel(JNIEnv *env, jobject, jstring path,
                                                 jint context_size, jint threads) {
    const char *path_chars = env->GetStringUTFChars(path, nullptr);
    std::call_once(backend_once, [] { llama_backend_init(); });

    auto *session = new LocalSession();
    auto model_params = llama_model_default_params();
    model_params.n_gpu_layers = 0;
    session->model = llama_model_load_from_file(path_chars, model_params);
    env->ReleaseStringUTFChars(path, path_chars);
    if (session->model == nullptr) {
        delete session;
        throw_java(env, "No se pudo abrir el GGUF Qwen.");
        return 0;
    }

    auto context_params = llama_context_default_params();
    context_params.n_ctx = static_cast<uint32_t>(context_size);
    context_params.n_batch = static_cast<uint32_t>(context_size);
    context_params.n_threads = threads;
    context_params.n_threads_batch = threads;
    session->context = llama_init_from_model(session->model, context_params);
    if (session->context == nullptr) {
        llama_model_free(session->model);
        delete session;
        throw_java(env, "No se pudo reservar el contexto de inferencia.");
        return 0;
    }
    session->vocab = llama_model_get_vocab(session->model);
    return reinterpret_cast<jlong>(session);
}

extern "C" JNIEXPORT void JNICALL
Java_app_chronoxai_MainActivity_nativeGenerate(JNIEnv *env, jobject, jlong handle,
                                                jobjectArray roles,
                                                jobjectArray contents,
                                                jint max_tokens, jfloat temperature,
                                                jobject sink) {
    auto *session = reinterpret_cast<LocalSession *>(handle);
    if (session == nullptr) {
        throw_java(env, "No hay modelo local cargado.");
        return;
    }
    std::lock_guard<std::mutex> lock(session->generation_mutex);
    const auto prompt = format_chat(env, session->model, roles, contents);
    if (env->ExceptionCheck()) return;

    const int32_t token_count = -llama_tokenize(session->vocab, prompt.c_str(),
                                                 static_cast<int32_t>(prompt.size()),
                                                 nullptr, 0, true, true);
    if (token_count <= 0 || token_count + max_tokens >= llama_n_ctx(session->context)) {
        throw_java(env, "El prompt excede el contexto local disponible.");
        return;
    }
    std::vector<llama_token> tokens(static_cast<size_t>(token_count));
    if (llama_tokenize(session->vocab, prompt.c_str(), static_cast<int32_t>(prompt.size()),
                       tokens.data(), token_count, true, true) < 0) {
        throw_java(env, "No se pudo tokenizar la conversación.");
        return;
    }

    // Provider sends the full current turn history on each call, so discard the
    // previous KV/recurrent state instead of appending a duplicate transcript.
    llama_memory_clear(llama_get_memory(session->context), true);
    auto batch = llama_batch_get_one(tokens.data(), token_count);
    if (llama_decode(session->context, batch) != 0) {
        throw_java(env, "Falló la evaluación del prompt local.");
        return;
    }

    jclass sink_class = env->GetObjectClass(sink);
    jmethodID on_token = env->GetMethodID(sink_class, "onToken", "(Ljava/lang/String;)V");
    auto *sampler = llama_sampler_chain_init(llama_sampler_chain_default_params());
    if (temperature <= 0.0f) {
        // A zero-temperature run is genuinely deterministic (greedy), which is
        // needed for reproducible diagnostics and offline acceptance evidence.
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy());
    } else {
        llama_sampler_chain_add(sampler, llama_sampler_init_top_k(40));
        llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.9f, 1));
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(temperature));
        std::random_device random_device;
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(random_device()));
    }

    std::string pending_utf8;
    std::vector<char> piece(256);
    for (jint index = 0; index < max_tokens && !session->cancelled.load(); ++index) {
        const llama_token token = llama_sampler_sample(sampler, session->context, -1);
        if (llama_vocab_is_eog(session->vocab, token)) break;
        int32_t written = llama_token_to_piece(session->vocab, token, piece.data(),
                                               static_cast<int32_t>(piece.size()), 0, true);
        if (written < 0) {
            piece.resize(static_cast<size_t>(-written));
            written = llama_token_to_piece(session->vocab, token, piece.data(),
                                           static_cast<int32_t>(piece.size()), 0, true);
        }
        if (written < 0) break;
        pending_utf8.append(piece.data(), static_cast<size_t>(written));
        emit_utf8(env, sink, on_token, pending_utf8, false);
        if (env->ExceptionCheck() || index + 1 == max_tokens || session->cancelled.load()) break;
        auto next_batch = llama_batch_get_one(const_cast<llama_token *>(&token), 1);
        if (llama_decode(session->context, next_batch) != 0) break;
    }
    emit_utf8(env, sink, on_token, pending_utf8, true);
    llama_sampler_free(sampler);
}

extern "C" JNIEXPORT void JNICALL
Java_app_chronoxai_MainActivity_nativeCancel(JNIEnv *, jobject, jlong handle) {
    auto *session = reinterpret_cast<LocalSession *>(handle);
    if (session != nullptr) session->cancelled.store(true);
}

extern "C" JNIEXPORT void JNICALL
Java_app_chronoxai_MainActivity_nativeResetCancellation(JNIEnv *, jobject, jlong handle) {
    auto *session = reinterpret_cast<LocalSession *>(handle);
    if (session != nullptr) session->cancelled.store(false);
}

extern "C" JNIEXPORT void JNICALL
Java_app_chronoxai_MainActivity_nativeUnloadModel(JNIEnv *, jobject, jlong handle) {
    auto *session = reinterpret_cast<LocalSession *>(handle);
    if (session == nullptr) return;
    session->cancelled.store(true);
    std::lock_guard<std::mutex> lock(session->generation_mutex);
    llama_free(session->context);
    llama_model_free(session->model);
    delete session;
}
