#include "HostDeviceData.h"

// SLANG-INTEGRATION: move ShadingAttribs from HostDeviceData.h to Shading.slang
// Rename ShadingAttribs to ShadingAttribsImpl,
// ShadingAttribsImpl now becomes a generic type 
// (features a generic type parameter for the prepared material field)
// Original ShadingAttribs now maps to ShadingAttribsImpl<TMaterial.EvaluatedMaterial>

/**
    The structure stores the complete information about the shading point,
    except for a light source information.
    It stores pre-evaluated material parameters with pre-fetched textures,
    shading point position, normal, viewing direction etc.
*/

// SLANG-INTEGRATION: move all geometry attributes to ShadingGeometry type.
struct ShadingGeometry
{
    float3    P;                                  ///< Shading hit position in world space
    float3    E;                                  ///< Direction to the eye at shading hit
    float3    N;                                  ///< Shading normal at shading hit
    float3    T;                                  ///< Shading tangent at shading hit
    float3    B;                                  ///< Shading bitangent at shading hit
    float2    UV;                                 ///< Texture mapping coordinates

#ifdef _MS_USER_DERIVATIVES
    float2    DPDX            DEFAULTS(float2(0, 0));                                  
    float2    DPDY            DEFAULTS(float2(0, 0)); ///< User-provided 2x2 full matrix of duv/dxy derivatives of a shading point footprint in texture space
#else
    float   lodBias         DEFAULTS(0);        ///< LOD bias to use when sampling textures
#endif

#ifdef _MS_USER_HALF_VECTOR_DERIVATIVES
    float2    DHDX            DEFAULTS(float2(0, 0));
    float2    DHDY            DEFAULTS(float2(0, 0));  ///< User-defined half-vector derivatives
#endif
};

// SLANG-INTEGRATION: 
// original ShadingAttribs now becomes ShadingAttribsImpl, which contains two fields:
// geom field for all the geometry attributes, and preparedMat for the evaluated material values

struct ShadingAttribsImpl<TEvaluatedMaterial>
{
    ShadingGeometry geom;
    TEvaluatedMaterial preparedMat;   ///< Copy of the original material with evaluated parameters (i.e., textures are fetched etc.)
};

ShadingAttribsImpl<TEvaluatedMaterial> makeShadingAttribs<TEvaluatedMaterial>(ShadingGeometry geom, TEvaluatedMaterial mat)
{
    ShadingAttribsImpl<TEvaluatedMaterial> rs;
    rs.geom = geom;
    rs.preparedMat = mat;
    return rs;
}