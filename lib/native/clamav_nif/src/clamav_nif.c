#include <erl_nif.h>
#include <clamav.h>
#include <string.h>
#include <stdio.h>

#define ENGINE_INVALID_ERROR "Engine resource is invalid or has been freed"
#define ENGINE_NOT_INITIALIZED_ERROR "Engine not initialized with database"

// Resource type for engine
typedef struct {
    struct cl_engine *engine;
    int initialized;
} engine_handle;

// Forward declarations
static ERL_NIF_TERM init_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]);
static ERL_NIF_TERM engine_new_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]);
static ERL_NIF_TERM engine_free_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]);
static ERL_NIF_TERM load_database_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]);
static ERL_NIF_TERM compile_engine_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]);
static ERL_NIF_TERM scan_file_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]);
static ERL_NIF_TERM scan_buffer_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]);
static ERL_NIF_TERM get_version_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]);
static ERL_NIF_TERM get_database_version_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]);
static void unload(ErlNifEnv* env, void* priv_data);

// Resource type handling
static ErlNifResourceType* ENGINE_RESOURCE_TYPE = NULL;

static void engine_destructor(ErlNifEnv* env, void* arg) {
    (void)env;
    engine_handle* handle = (engine_handle*)arg;
    if (handle && handle->engine) {
        cl_engine_free(handle->engine);
        handle->engine = NULL;
        handle->initialized = 0;
    }
}

static int load(ErlNifEnv* env, void** priv_data, ERL_NIF_TERM load_info) {
    (void)priv_data;
    (void)load_info;
    // Register resource type for engine handles
    ENGINE_RESOURCE_TYPE = enif_open_resource_type(
        env,
        NULL,
        "engine_handle",
        engine_destructor,
        ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER,
        NULL
    );

    if (ENGINE_RESOURCE_TYPE == NULL) {
        return -1;
    }

    return 0;
}

static int upgrade(ErlNifEnv* env, void** priv_data, void** old_priv_data, ERL_NIF_TERM load_info) {
    (void)old_priv_data;
    return load(env, priv_data, load_info);
}

static void unload(ErlNifEnv* env, void* priv_data) {
    (void)env;
    (void)priv_data;
    cl_cleanup();
}

static ERL_NIF_TERM make_error(ErlNifEnv* env, const char* error) {
    return enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_string(env, error, ERL_NIF_LATIN1));
}

static ERL_NIF_TERM make_clamav_error(ErlNifEnv* env, int error_code) {
    const char* error_msg = cl_strerror(error_code);
    return make_error(env, error_msg);
}

static int get_c_string(ErlNifEnv* env, ERL_NIF_TERM term, char* buffer, size_t buffer_size) {
    ErlNifBinary bin;

    if (buffer_size == 0) {
        return 0;
    }

    if (enif_inspect_binary(env, term, &bin)) {
        if (bin.size >= buffer_size) {
            return 0;
        }

        memcpy(buffer, bin.data, bin.size);
        buffer[bin.size] = '\0';
        return 1;
    }

    int chars_written = enif_get_string(env, term, buffer, buffer_size, ERL_NIF_LATIN1);
    if (chars_written > 0) {
        return 1;
    }

    return 0;
}

static void apply_legacy_flags(struct cl_scan_options* opts, unsigned int options_mask) {
    if (options_mask & 0x1) {
        opts->parse |= CL_SCAN_PARSE_ARCHIVE;
    }
    if (options_mask & 0x2) {
        opts->parse |= CL_SCAN_PARSE_MAIL;
    }
    if (options_mask & 0x4) {
        opts->parse |= CL_SCAN_PARSE_OLE2;
    }
    if (options_mask & 0x8) {
        opts->heuristic |= CL_SCAN_HEURISTIC_BROKEN;
    }
}

static void init_scan_options(struct cl_scan_options* opts, unsigned int options_mask) {
    memset(opts, 0, sizeof(*opts));

    unsigned int general_bits = options_mask &
        (CL_SCAN_GENERAL_ALLMATCHES |
         CL_SCAN_GENERAL_COLLECT_METADATA |
         CL_SCAN_GENERAL_HEURISTICS |
         CL_SCAN_GENERAL_HEURISTIC_PRECEDENCE |
         CL_SCAN_GENERAL_UNPRIVILEGED);

    opts->general = general_bits;

    apply_legacy_flags(opts, options_mask);
}

// Initialize the ClamAV library
static ERL_NIF_TERM init_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    unsigned int init_flags;

    if (!enif_get_uint(env, argv[0], &init_flags)) {
        return enif_make_badarg(env);
    }

    int ret = cl_init(init_flags);
    if (ret != CL_SUCCESS) {
        return make_clamav_error(env, ret);
    }

    return enif_make_atom(env, "ok");
}

// Create a new engine
static ERL_NIF_TERM engine_new_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    struct cl_engine* engine = cl_engine_new();

    if (!engine) {
        return make_error(env, "Failed to create engine");
    }

    engine_handle* handle = enif_alloc_resource(ENGINE_RESOURCE_TYPE, sizeof(engine_handle));
    if (!handle) {
        cl_engine_free(engine);
        return make_error(env, "Failed to allocate resource");
    }

    handle->engine = engine;
    handle->initialized = 0;

    ERL_NIF_TERM result = enif_make_resource(env, handle);
    enif_release_resource(handle);

    return enif_make_tuple2(env, enif_make_atom(env, "ok"), result);
}

// Free an engine
static ERL_NIF_TERM engine_free_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    engine_handle* handle;

    if (!enif_get_resource(env, argv[0], ENGINE_RESOURCE_TYPE, (void**)&handle)) {
        return enif_make_badarg(env);
    }

    if (handle->engine) {
        cl_engine_free(handle->engine);
        handle->engine = NULL;
    }
    handle->initialized = 0;

    return enif_make_atom(env, "ok");
}

// Load virus database
static ERL_NIF_TERM load_database_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    engine_handle* handle;
    char database_path[1024];

    if (!enif_get_resource(env, argv[0], ENGINE_RESOURCE_TYPE, (void**)&handle)) {
        return enif_make_badarg(env);
    }

    if (!handle->engine) {
        return make_error(env, ENGINE_INVALID_ERROR);
    }

    if (!get_c_string(env, argv[1], database_path, sizeof(database_path))) {
        return enif_make_badarg(env);
    }

    unsigned int signatures = 0;
    int ret = cl_load(database_path, handle->engine, &signatures, CL_DB_STDOPT);

    if (ret != CL_SUCCESS) {
        return make_clamav_error(env, ret);
    }

    handle->initialized = 1;

    return enif_make_tuple2(
        env,
        enif_make_atom(env, "ok"),
        enif_make_ulong(env, signatures)
    );
}

// Compile the engine
static ERL_NIF_TERM compile_engine_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    engine_handle* handle;

    if (!enif_get_resource(env, argv[0], ENGINE_RESOURCE_TYPE, (void**)&handle)) {
        return enif_make_badarg(env);
    }

    if (!handle->engine) {
        return make_error(env, ENGINE_INVALID_ERROR);
    }

    if (!handle->initialized) {
        return make_error(env, ENGINE_NOT_INITIALIZED_ERROR);
    }

    int ret = cl_engine_compile(handle->engine);

    if (ret != CL_SUCCESS) {
        return make_clamav_error(env, ret);
    }

    return enif_make_atom(env, "ok");
}

// Scan a file
static ERL_NIF_TERM scan_file_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    engine_handle* handle;
    char file_path[1024];
    const char* virus_name = NULL;
    unsigned long int scanned = 0;
    unsigned int options_mask = 0;
    struct cl_scan_options scan_opts;

    if (!enif_get_resource(env, argv[0], ENGINE_RESOURCE_TYPE, (void**)&handle)) {
        return enif_make_badarg(env);
    }

    if (!handle->engine) {
        return make_error(env, ENGINE_INVALID_ERROR);
    }

    if (!handle->initialized) {
        return make_error(env, ENGINE_NOT_INITIALIZED_ERROR);
    }

    if (!get_c_string(env, argv[1], file_path, sizeof(file_path))) {
        return enif_make_badarg(env);
    }

    if (argc > 2) {
        if (!enif_get_uint(env, argv[2], &options_mask)) {
            return enif_make_badarg(env);
        }
    }

    init_scan_options(&scan_opts, options_mask);

    int ret = cl_scanfile(
        file_path,
        &virus_name,
        &scanned,
        handle->engine,
        &scan_opts
    );

    switch (ret) {
        case CL_CLEAN:
            return enif_make_tuple2(
                env,
                enif_make_atom(env, "ok"),
                enif_make_atom(env, "clean")
            );
        case CL_VIRUS:
            return enif_make_tuple3(
                env,
                enif_make_atom(env, "ok"),
                enif_make_atom(env, "virus"),
                enif_make_string(env, virus_name ? virus_name : "", ERL_NIF_LATIN1)
            );
        default:
            return make_clamav_error(env, ret);
    }
}

// Scan a buffer in memory
static ERL_NIF_TERM scan_buffer_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    engine_handle* handle;
    ErlNifBinary buffer;
    const char* virus_name = NULL;
    unsigned long int scanned = 0;
    unsigned int options_mask = 0;
    struct cl_scan_options scan_opts;
    cl_fmap_t* map;

    if (!enif_get_resource(env, argv[0], ENGINE_RESOURCE_TYPE, (void**)&handle)) {
        return enif_make_badarg(env);
    }

    if (!handle->engine) {
        return make_error(env, ENGINE_INVALID_ERROR);
    }

    if (!handle->initialized) {
        return make_error(env, ENGINE_NOT_INITIALIZED_ERROR);
    }

    if (!enif_inspect_binary(env, argv[1], &buffer)) {
        return enif_make_badarg(env);
    }

    if (argc > 2) {
        if (!enif_get_uint(env, argv[2], &options_mask)) {
            return enif_make_badarg(env);
        }
    }

    init_scan_options(&scan_opts, options_mask);

    map = cl_fmap_open_memory(buffer.data, buffer.size);
    if (!map) {
        return make_error(env, "Failed to create fmap");
    }

    int ret = cl_scanmap_callback(
        map,
        NULL,
        &virus_name,
        &scanned,
        handle->engine,
        &scan_opts,
        NULL
    );

    cl_fmap_close(map);

    switch (ret) {
        case CL_CLEAN:
            return enif_make_tuple2(
                env,
                enif_make_atom(env, "ok"),
                enif_make_atom(env, "clean")
            );
        case CL_VIRUS:
            return enif_make_tuple3(
                env,
                enif_make_atom(env, "ok"),
                enif_make_atom(env, "virus"),
                enif_make_string(env, virus_name ? virus_name : "", ERL_NIF_LATIN1)
            );
        default:
            return make_clamav_error(env, ret);
    }
}

// Get ClamAV version
static ERL_NIF_TERM get_version_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    const char* version = cl_retver();
    return enif_make_string(env, version, ERL_NIF_LATIN1);
}

// Get database version
static ERL_NIF_TERM get_database_version_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    engine_handle* handle;
    int err = 0;
    long long version;

    if (!enif_get_resource(env, argv[0], ENGINE_RESOURCE_TYPE, (void**)&handle)) {
        return enif_make_badarg(env);
    }

    if (!handle->engine) {
        return make_error(env, ENGINE_INVALID_ERROR);
    }

    version = cl_engine_get_num(handle->engine, CL_ENGINE_DB_VERSION, &err);

    if (err != CL_SUCCESS) {
        return make_clamav_error(env, err);
    }

    return enif_make_ulong(env, (unsigned long)version);
}

// NIF function definitions
static ErlNifFunc nif_funcs[] = {
    {"init", 1, init_nif, 0},
    {"engine_new", 0, engine_new_nif, 0},
    {"engine_free", 1, engine_free_nif, 0},
    {"load_database", 2, load_database_nif, 0},
    {"compile_engine", 1, compile_engine_nif, 0},
    {"scan_file", 2, scan_file_nif, 0},
    {"scan_file", 3, scan_file_nif, 0},
    {"scan_buffer", 2, scan_buffer_nif, 0},
    {"scan_buffer", 3, scan_buffer_nif, 0},
    {"get_version", 0, get_version_nif, 0},
    {"get_database_version", 1, get_database_version_nif, 0}
};

ERL_NIF_INIT(Elixir.ExClamav.Nif, nif_funcs, load, NULL, upgrade, unload)
