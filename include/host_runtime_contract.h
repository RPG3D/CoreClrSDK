// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.
//
// host_runtime_contract.h — iOS CoreCLR P/Invoke override contract.
// Copied from the verified IOSClrDemo. Used to register a pinvoke_override
// callback so CoreCLR can resolve __Internal P/Invoke calls via dlsym.

#ifndef __HOST_RUNTIME_CONTRACT_H__
#define __HOST_RUNTIME_CONTRACT_H__

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
    #define HOST_CONTRACT_CALLTYPE __stdcall
#else
    #define HOST_CONTRACT_CALLTYPE
#endif

// Known host property names
#define HOST_PROPERTY_RUNTIME_CONTRACT "HOST_RUNTIME_CONTRACT"
#define HOST_PROPERTY_APP_PATHS "APP_PATHS"
#define HOST_PROPERTY_BUNDLE_PROBE "BUNDLE_PROBE"
#define HOST_PROPERTY_BUNDLE_EXTRACTION_PATH "BUNDLE_EXTRACTION_PATH"
#define HOST_PROPERTY_ENTRY_ASSEMBLY_NAME "ENTRY_ASSEMBLY_NAME"
#define HOST_PROPERTY_NATIVE_DLL_SEARCH_DIRECTORIES "NATIVE_DLL_SEARCH_DIRECTORIES"
#define HOST_PROPERTY_PINVOKE_OVERRIDE "PINVOKE_OVERRIDE"
#define HOST_PROPERTY_PLATFORM_RESOURCE_ROOTS "PLATFORM_RESOURCE_ROOTS"
#define HOST_PROPERTY_TRUSTED_PLATFORM_ASSEMBLIES "TRUSTED_PLATFORM_ASSEMBLIES"

// Context passed to get_native_code_data callback
struct host_runtime_contract_native_code_context
{
    size_t size;
    const char* assembly_path;
    const char* owner_composite_name;
};

// Data returned by get_native_code_data callback
struct host_runtime_contract_native_code_data
{
    size_t size;
    void* r2r_header_ptr;
    size_t image_size;
    void* image_base;
};

// Any callbacks set on this contract are expected to be valid for the lifetime of the process
struct host_runtime_contract
{
    size_t size;

    // Context for the contract. Pass to functions taking a contract context.
    void* context;

    size_t(HOST_CONTRACT_CALLTYPE* get_runtime_property)(
        const char* key,
        /*out*/ char* value_buffer,
        size_t value_buffer_size,
        void* contract_context);

    bool(HOST_CONTRACT_CALLTYPE* bundle_probe)(
        const char* path,
        /*out*/ int64_t* offset,
        /*out*/ int64_t* size,
        /*out*/ int64_t* compressedSize);

    const void* (HOST_CONTRACT_CALLTYPE* pinvoke_override)(
        const char* library_name,
        const char* entry_point_name);

    bool(HOST_CONTRACT_CALLTYPE* external_assembly_probe)(
        const char* path,
        /*out*/ void **data_start,
        /*out*/ int64_t* size);

    bool(HOST_CONTRACT_CALLTYPE* get_native_code_data)(
       const struct host_runtime_contract_native_code_context* context,
       /*out*/ struct host_runtime_contract_native_code_data* data);
};
#endif // __HOST_RUNTIME_CONTRACT_H__
