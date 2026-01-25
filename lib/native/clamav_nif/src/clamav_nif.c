#include <erl_nif.h>
#include <clamav.h>
#include <string.h>
#include <stdio.h>

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

// Resource type handling
static ErlNifResourceType* ENGINE_RESOURCE_TYPE = NULL;

static void engine_destructor(ErlNifEnv* env, void* arg) {
    engine_handle* handle = (engine_handle*)arg;
    if (handle && handle->engine) {
        cl_engine_free(handle->engine);
        handle->engine = NULL;
        handle->initialized = 0;
    }
}

static int load(ErlNifEnv* env, void** priv_data, ERL_NIF_TERM load_info) {
    // Register resource type for engine handles
    ENGINE_RESOURCE_TYPE = enif_open_resource_type(
        env,
        NULL,
        "engine_handle",
        engine_destructor,
        ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER,
        NULL
    );

    return 0;
}

static int upgrade(ErlNifEnv* env, void** priv_data, void** old_priv_data, ERL_NIF_TERM load_info) {
    return load(env, priv_data, load_info);
}

static ERL_NIF_TERM make_error(ErlNifEnv* env, const char* error) {
    return enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_string(env, error, ERL_NIF_LATIN1));
}

static ERL_NIF_TERM make_clamav_error(ErlNifEnv* env, int error_code) {
    const char* error_msg = cl_strerror(error_code);
    return make_error(env, error_msg);
}

// Initialize the ClamAV library
static ERL_NIF_TERM init_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
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
    engine_handle* handle;

    if (!enif_get_resource(env, argv[0], ENGINE_RESOURCE_TYPE, (void**)&handle)) {
        return enif_make_badarg(env);
    }

    // The destructor will be called automatically when the resource is garbage collected
    return enif_make_atom(env, "ok");
}

// Load virus database
static ERL_NIF_TERM load_database_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    engine_handle* handle;
    char database_path[1024];

    if (!enif_get_resource(env, argv[0], ENGINE_RESOURCE_TYPE, (void**)&handle)) {
        return enif_make_badarg(env);
    }

    if (!enif_get_string(env, argv[1], database_path, sizeof(database_path), ERL_NIF_LATIN1)) {
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
    engine_handle* handle;

    if (!enif_get_resource(env, argv[0], ENGINE_RESOURCE_TYPE, (void**)&handle)) {
        return enif_make_badarg(env);
    }

    if (!handle->initialized) {
        return make_error(env, "Engine not initialized with database");
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
    char virus_name[1024];
    unsigned long int scanned = 0;
    unsigned int options = 0;

    if (!enif_get_resource(env, argv[0], ENGINE_RESOURCE_TYPE, (void**)&handle)) {
        return enif_make_badarg(env);
    }

    if (!enif_get_string(env, argv[1], file_path, sizeof(file_path), ERL_NIF_LATIN1)) {
        return enif_make_badarg(env);
    }

    if (argc > 2 && !enif_get_uint(env, argv[2], &options)) {
        return enif_make_badarg(env);
    }

    int ret = cl_scanfile(
        file_path,
        &virus_name[0],
        &scanned,
        handle->engine,
        options
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
                enif_make_string(env, virus_name, ERL_NIF_LATIN1)
            );
        default:
            return make_clamav_error(env, ret);
    }
}

// Scan a buffer in memory
static ERL_NIF_TERM scan_buffer_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    engine_handle* handle;
    ErlNifBinary buffer;
    char virus_name[1024];
    unsigned long int scanned = 0;
    unsigned int options = 0;

    if (!enif_get_resource(env, argv[0], ENGINE_RESOURCE_TYPE, (void**)&handle)) {
        return enif_make_badarg(env);
    }

    if (!enif_inspect_binary(env, argv[1], &buffer)) {
        return enif_make_badarg(env);
    }

    if (argc > 2 && !enif_get_uint(env, argv[2], &options)) {
        return enif_make_badarg(env);
    }

    int ret = cl_scanjit(
        buffer.data,
        buffer.size,
        &virus_name[0],
        &scanned,
        handle->engine,
        options
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
                enif_make_string(env, virus_name, ERL_NIF_LATIN1)
            );
        default:
            return make_clamav_error(env, ret);
    }
}

// Get ClamAV version
static ERL_NIF_TERM get_version_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    const char* version = cl_retver();
    return enif_make_string(env, version, ERL_NIF_LATIN1);
}

// Get database version
static ERL_NIF_TERM get_database_version_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    engine_handle* handle;
    unsigned int version;

    if (!enif_get_resource(env, argv[0], ENGINE_RESOURCE_TYPE, (void**)&handle)) {
        return enif_make_badarg(env);
    }

    int ret = cl_engine_get_num(handle->engine, CL_ENGINE_DB_VERSION, &version, NULL);

    if (ret != CL_SUCCESS) {
        return make_clamav_error(env, ret);
    }

    return enif_make_ulong(env, version);
}

// NIF function definitions
static ErlNifFunc nif_funcs[] = {
    {"init", 1, init_nif},
    {"engine_new", 0, engine_new_nif},
    {"engine_free", 1, engine_free_nif},
    {"load_database", 2, load_database_nif},
    {"compile_engine", 1, compile_engine_nif},
    {"scan_file", 2, scan_file_nif},
    {"scan_file", 3, scan_file_nif},
    {"scan_buffer", 2, scan_buffer_nif},
    {"scan_buffer", 3, scan_buffer_nif},
    {"get_version", 0, get_version_nif},
    {"get_database_version", 1, get_database_version_nif}
};

ERL_NIF_INIT(Elixir.ClamavEx.Nif, nif_funcs, load, NULL, upgrade, NULL)
