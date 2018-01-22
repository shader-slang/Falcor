/***************************************************************************
# Copyright (c) 2015, NVIDIA CORPORATION. All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
#  * Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
#  * Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#  * Neither the name of NVIDIA CORPORATION nor the names of its
#    contributors may be used to endorse or promote products derived
#    from this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS ``AS IS'' AND ANY
# EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
# PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
# CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
# EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
# PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
# PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
# OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
***************************************************************************/

#ifndef _FALCOR_SHADING_H_
#define _FALCOR_SHADING_H_

// Make sure we get the macros like `_fn` and `_ref`
// TODO: just eliminate these since we know this is pure Slang.
#include "HostDeviceData.h"

__import Helpers;
__import Interfaces;
/*******************************************************************
Documentation
*******************************************************************/

// Possible user-defined global macros to configure shading 
//#define _MS_DISABLE_ALPHA_TEST    ///< Disables alpha test (handy for early-z etc.)
//#define _MS_DISABLE_TEXTURES      ///< Disables material texture fetches, all materials are solid color
//#define _MS_USER_DERIVATIVES      ///< Use user-passed dx/dy derivatives for texture filtering during shading
//#define _MS_USER_NORMAL_MAPPING   ///< Use user-defined callback of a form void PerturbNormal(SMaterial mat, inout ShadingAttribs ShAttr) to perform normal mapping
//#define _MS_NUM_LAYERS            ///< Use a pre-specified number of layers to use in the material
//#define _MS_IMPORTANCE_SAMPLING   ///< Use BSDF importance sampling for path tracer next event estimation

/*******************************************************************
Shading routines
*******************************************************************/

/**
This is an output resulting radiance of a full pass over all material layers
after evaluating the material for a single light source.
This result can be accumulated to a total shading result for all light sources.
*/
struct PassOutput
{
    float3  value;                  ///< Outgoing radiance after evaluating the complete material for a single light
    float3  diffuseAlbedo;          ///< Total view-independent albedo color component of the material
    float3  diffuseIllumination;    ///< Total view-independent outgoing radiance from one light before multiplication by albedo
    float3  specularAlbedo;         ///< Total view-dependent albedo (specular) color component of the material
    float3  specularIllumination;   ///< Total view-dependent outgoing radiance from one light before multiplication by albedo

    float2  roughness;              ///< Roughness from the last layer
    float2  effectiveRoughness;     ///< Accumulated effective roughness
};

/**
This is an accumulative structure that collects the resulting output
of material evaluations with all light sources.
*/
struct ShadingOutput
{
    float3  diffuseAlbedo;          ///< Total view-independent albedo color component of the material
    float3  diffuseIllumination;    ///< Total view-independent outgoing radiance from all lights before multiplication by albedo
    float3  specularAlbedo;         ///< Total view-dependent albedo (specular) color component of the material
    float3  specularIllumination;   ///< Total view-dependent outgoing radiance from all light before multiplication by albedo

    float3  finalValue;             ///< Outgoing radiance after evaluating the complete material for all lights

    float3  wi;                     ///< Incident direction after importance sampling the BRDF
    float   pdf;                    ///< Probability density function for choosing the incident direction
    float3  thp;                    ///< Current path throughput

    float2  effectiveRoughness;     ///< Sampled brdf roughness, or for evaluated material, an effective roughness
};

// SLANG-INTEGRATION: define interfaces

interface IBRDF
{
    void eval(ShadingGeometry geom, LightAttribs lAttr, inout ShadingOutput result);
    float4 getAlbedo();
    float getRoughness();
}

interface IMaterial
{
    associatedtype EvaluatedMaterial : IBRDF;
    void prepareForDepthPass(ShadingGeometry geom);
    ShadingAttribsImpl<EvaluatedMaterial> prepare(ShadingGeometry geom);
}

interface ILight
{
    void evalLighting<TBRDF:IBRDF>(ShadingAttribsImpl<TBRDF> shAttr, float shadowFactor, inout ShadingOutput result);
}

struct InfinitessimalLight : ILight
{
    LightData light;
    void evalLighting<TBxDF:IBRDF>(ShadingAttribsImpl<TBxDF> shAttr, float shadowFactor, inout ShadingOutput result)
    {
        /* Prepare lighting attributes */
        LightAttribs LAttr = prepareLightAttribs(light, shAttr.geom, shadowFactor);

        /* Evaluate material with lighting attributes */
        shAttr.preparedMat.eval(shAttr.geom, LAttr, result);
    }
};

struct PointLight : ILight
{
    LightData light;
    void evalLighting<TBxDF:IBRDF>(ShadingAttribsImpl<TBxDF> shAttr, float shadowFactor, inout ShadingOutput result)
    {
        LightAttribs LightAttr;
        /* Evaluate direction to the light */
        LightAttr.P = getLightPos(light, shAttr.geom.P);
        LightAttr.pdf = 0;
        LightAttr.N = 0;
        LightAttr.shadowFactor = light.isShadowed ? shadowFactor : 1.0;
        float3 PosToLight = LightAttr.P - shAttr.geom.P;
        if(dot(PosToLight, PosToLight) > 1e-3f)
        {
            LightAttr.L = normalize(PosToLight);
        }
        else
        {
            LightAttr.L = 0;
        }
        LightAttr.lightIntensity = light.intensity;
        /* Evaluate various attenuation factors: cosine, 1/r^2, etc. */
        float Atten = 1.f;

        float cosTheta = -dot(LightAttr.L, light.worldDir);	// cos of angle of light orientation with outgoing direction

        // Spot light cone angle
        if(cosTheta < light.cosOpeningAngle)
            Atten = 0.f;
        if(light.penumbraAngle > 0.f)	// Compute cone attenuation of a spot light
        {
            float deltaAngle = light.openingAngle - acos(cosTheta);
            Atten *= clamp((deltaAngle - light.penumbraAngle) / light.penumbraAngle, 0.f, 1.f);
        }

        // Quadratic attenuation
        Atten /= max(1e-3f, dot(PosToLight, PosToLight));
        LightAttr.lightIntensity *= Atten;

        /* Evaluate material with lighting attributes */
        shAttr.preparedMat.eval(shAttr.geom, LightAttr, result);
    }
};

struct DirectionalLight : ILight
{
    LightData light;
    void evalLighting<TBxDF:IBRDF>(ShadingAttribsImpl<TBxDF> shAttr, float shadowFactor, inout ShadingOutput result)
    {
        LightAttribs LightAttr;
        /* Evaluate direction to the light */
        LightAttr.P = getLightPos(light, shAttr.geom.P);
        LightAttr.pdf = 0;
        LightAttr.N = 0;
        LightAttr.shadowFactor = light.isShadowed ? shadowFactor : 1.0;
        LightAttr.lightIntensity = light.intensity;
        LightAttr.L = -light.worldDir;
        /* Evaluate material with lighting attributes */
        shAttr.preparedMat.eval(shAttr.geom, LightAttr, result);
    }
};

// Define an interface that reflectance functions must implement in order to
// support illumination with quad light sources.
interface IAcceptQuadLight
{
    void acceptQuadLight(QuadLight quadLight, LightAttribs LAttr, ShadingGeometry geom, float shadowFactor, inout ShadingOutput result);
}

struct QuadLight : ILight
{
    LightData light;

Texture2D g_ltc_mat;
Texture2D g_ltc_mag;
SamplerState g_light_texSampler;

    void evalLighting<TBxDF:IBRDF>(ShadingAttribsImpl<TBxDF> shAttr, float shadowFactor, inout ShadingOutput result)
    {
        /* Prepare lighting attributes */
        LightAttribs LAttr = prepareLightAttribs(light, shAttr.geom, shadowFactor);

        shAttr.preparedMat.acceptQuadLight(this, LAttr, shAttr.geom, shadowFactor, result);
    }
};

// Make every BxDF have a new requirement: they must conform to `IAcceptQuadLight`
extension IBRDF : IAcceptQuadLight
{
}

// Implement the new requirement for the `PreparedMaterialData` type (the default BxDF)
extension PreparedMaterialData
{
    void acceptQuadLight(QuadLight quadLight, LightAttribs LAttr, ShadingGeometry geom, float shadowFactor, inout ShadingOutput result)
    {
        evalQuadLight(this, geom, quadLight, LAttr, result);
    }
}

__generic<let HasDiffuse:int, let HasSpecular:int, let HasDieletric:int, let HasEmisive:int>
extension StandardPreparedMaterialData<HasDiffuse,HasSpecular,HasDieletric, HasEmisive>
{
    void acceptQuadLight(QuadLight quadLight, LightAttribs LAttr, ShadingGeometry geom, float shadowFactor, inout ShadingOutput result)
    {
        evalQuadLight(this, geom, quadLight, LAttr, result);
    }
}

#define pi 3.14159265
#define LUT_SIZE 32.0
#define LUT_SCALE (LUT_SIZE - 1.0)/LUT_SIZE
#define LUT_BIAS 0.5/LUT_SIZE


void evalAreaLight(float3 N, float3 V, float3 P, float roughness, float3 intensity, 
                    float3 points[4], bool twoSided,
    
    QuadLight               quadLight, 
    out float3 diffLighting, out float3 specLighting)
{
    float theta = acos(dot(N, V));
    float2 uv = float2(roughness, theta/(0.5*pi));
    uv = uv*LUT_SCALE + LUT_BIAS;
        
    float4 t = quadLight.g_ltc_mat.SampleBias(quadLight.g_light_texSampler, uv, 0.0);
    float3x3 Minv = float3x3(
        float3(  1,   0, t.y),
        float3(  0, t.z,   0),
        float3(t.w,   0, t.x)
    );
    specLighting = intensity*LTC_Evaluate(N, V, P, Minv, points, twoSided);
    specLighting *= quadLight.g_ltc_mag.SampleBias(quadLight.g_light_texSampler, uv, 0.0).w;
    specLighting = float3(0.0f);
        
    diffLighting = intensity*LTC_Evaluate(N, V, P, float3x3(1,0,0,0,1,0,0,0,1), points, twoSided); 
}

float3 LTC_Evaluate(float3 N, float3 V, float3 P, float3x3 Minv, float3 points[4], bool twoSided)
{
        
    // construct orthonormal basis around N
    float3 T1, T2;
    T1 = normalize(V - N*dot(V, N));
    T2 = cross(N, T1);

    // rotate area light in (T1, T2, N) basis
    Minv = mul(transpose(float3x3(T1, T2, N)), Minv);

    // polygon (allocate 5 vertices for clipping)
    float3 L[5];
    L[0] = mul(points[0] - P, Minv);
    L[1] = mul(points[1] - P, Minv);
    L[2] = mul(points[2] - P, Minv);
    L[3] = mul(points[3] - P, Minv);
    L[4] = float3(0,0,0);

    int n;
    ClipQuadToHorizon(L, n);
    
    if (n == 0)
        return float3(0, 0, 0);

    // project onto sphere
    L[0] = normalize(L[0]);
    L[1] = normalize(L[1]);
    L[2] = normalize(L[2]);
    L[3] = normalize(L[3]);
    L[4] = normalize(L[4]);

    // integrate
    float sum = 0.0;

    sum += IntegrateEdge(L[0], L[1]);
    sum += IntegrateEdge(L[1], L[2]);
    sum += IntegrateEdge(L[2], L[3]);
    if (n >= 4)
        sum += IntegrateEdge(L[3], L[4]);
    if (n == 5)
        sum += IntegrateEdge(L[4], L[0]);

    sum = twoSided ? abs(sum) : max(0.0, sum);

    float3 Lo_i = float3(sum, sum, sum);

    return Lo_i;
}

float IntegrateEdge(float3 v1, float3 v2)
{
    float cosTheta = dot(v1, v2);
    float theta = acos(cosTheta);    
    float res = cross(v1, v2).z * ((theta > 0.001) ? theta/sin(theta) : 1.0);

    return res;
}

void ClipQuadToHorizon(inout float3 L[5], out int n)
{
    // detect clipping config
    int config = 0;
    if (L[0].z > 0.0) config += 1;
    if (L[1].z > 0.0) config += 2;
    if (L[2].z > 0.0) config += 4;
    if (L[3].z > 0.0) config += 8;

    // clip
    n = 0;

    if (config == 0)
    {
        // clip all
    }
    else if (config == 1) // V1 clip V2 V3 V4
    {
        n = 3;
        L[1] = -L[1].z * L[0] + L[0].z * L[1];
        L[2] = -L[3].z * L[0] + L[0].z * L[3];
    }
    else if (config == 2) // V2 clip V1 V3 V4
    {
        n = 3;
        L[0] = -L[0].z * L[1] + L[1].z * L[0];
        L[2] = -L[2].z * L[1] + L[1].z * L[2];
    }
    else if (config == 3) // V1 V2 clip V3 V4
    {
        n = 4;
        L[2] = -L[2].z * L[1] + L[1].z * L[2];
        L[3] = -L[3].z * L[0] + L[0].z * L[3];
    }
    else if (config == 4) // V3 clip V1 V2 V4
    {
        n = 3;
        L[0] = -L[3].z * L[2] + L[2].z * L[3];
        L[1] = -L[1].z * L[2] + L[2].z * L[1];
    }
    else if (config == 5) // V1 V3 clip V2 V4) impossible
    {
        n = 0;
    }
    else if (config == 6) // V2 V3 clip V1 V4
    {
        n = 4;
        L[0] = -L[0].z * L[1] + L[1].z * L[0];
        L[3] = -L[3].z * L[2] + L[2].z * L[3];
    }
    else if (config == 7) // V1 V2 V3 clip V4
    {
        n = 5;
        L[4] = -L[3].z * L[0] + L[0].z * L[3];
        L[3] = -L[3].z * L[2] + L[2].z * L[3];
    }
    else if (config == 8) // V4 clip V1 V2 V3
    {
        n = 3;
        L[0] = -L[0].z * L[3] + L[3].z * L[0];
        L[1] = -L[2].z * L[3] + L[3].z * L[2];
        L[2] =  L[3];
    }
    else if (config == 9) // V1 V4 clip V2 V3
    {
        n = 4;
        L[1] = -L[1].z * L[0] + L[0].z * L[1];
        L[2] = -L[2].z * L[3] + L[3].z * L[2];
    }
    else if (config == 10) // V2 V4 clip V1 V3) impossible
    {
        n = 0;
    }
    else if (config == 11) // V1 V2 V4 clip V3
    {
        n = 5;
        L[4] = L[3];
        L[3] = -L[2].z * L[3] + L[3].z * L[2];
        L[2] = -L[2].z * L[1] + L[1].z * L[2];
    }
    else if (config == 12) // V3 V4 clip V1 V2
    {
        n = 4;
        L[1] = -L[1].z * L[2] + L[2].z * L[1];
        L[0] = -L[0].z * L[3] + L[3].z * L[0];
    }
    else if (config == 13) // V1 V3 V4 clip V2
    {
        n = 5;
        L[4] = L[3];
        L[3] = L[2];
        L[2] = -L[1].z * L[2] + L[2].z * L[1];
        L[1] = -L[1].z * L[0] + L[0].z * L[1];
    }
    else if (config == 14) // V2 V3 V4 clip V1
    {
        n = 5;
        L[4] = -L[0].z * L[3] + L[3].z * L[0];
        L[0] = -L[0].z * L[1] + L[1].z * L[0];
    }
    else if (config == 15) // V1 V2 V3 V4
    {
        n = 4;
    }
    
    if (n == 3)
        L[3] = L[0];
    if (n == 4)
        L[4] = L[0];
}


////////////

struct AmbientLight : ILight
{
    float3 ambientLight;
    void evalLighting<TBxDF:IBRDF>(ShadingAttribsImpl<TBxDF> shAttr, float shadowFactor, inout ShadingOutput result)
    {
        result.finalValue += ambientLight * shAttr.preparedMat.getAlbedo().xyz;
    }
};

struct LightArray<TLight:ILight, let N:int> : ILight
{   
    TLight lights[N];
    void evalLighting<TBxDF:IBRDF>(ShadingAttribsImpl<TBxDF> shAttr, float shadowFactor, inout ShadingOutput result)
    {
        for (int i = 0; i < N; i++)
        {
            lights[i].evalLighting(shAttr, shadowFactor, result);
        }
    }
};

struct LightPair<TLight1 : ILight, TLight2 : ILight> : ILight
{
    TLight1 light1;
    TLight2 light2;
    void evalLighting<TBxDF:IBRDF>(ShadingAttribsImpl<TBxDF> shAttr, float shadowFactor, inout ShadingOutput result)
    {
        light1.evalLighting(shAttr, shadowFactor, result);
        light2.evalLighting(shAttr, shadowFactor, result);
    }
};

ShadingOutput initShadingOutput()
{
    ShadingOutput result;
    result.diffuseAlbedo = 0;
    result.diffuseIllumination = 0;
    result.specularAlbedo = 0;
    result.specularIllumination = 0;
    result.finalValue = 0;
    result.effectiveRoughness = 0;
    result.wi = 0;
    result.pdf = 0;
    result.thp = 0;
    return result;
}

/* Include all shading routines, including endpoints (camera and light) */

__import Cameras;
__import Lights;
__import BSDFs;

/*******************************************************************
Material shading building blocks
*******************************************************************/

struct PreparedMaterialData : IBRDF
{
    MaterialDesc    desc;
    MaterialValues  values;
    
    // SLANG-INTEGRATION: move aoFactor from ShadingAttribs to PreparedMaterialData
    float aoFactor;


    // SLANG-INTEGRATION: PreparedMaterialData now implements IBRDF interface

    void eval(ShadingGeometry geom, LightAttribs lAttr, inout ShadingOutput result)
    {
        // call previous evalMaterial (now evalDefaultMaterial) function 
        ShadingAttribsImpl<PreparedMaterialData> shAttr = makeShadingAttribs(geom, this);
        evalDefaultMaterial(shAttr, lAttr, result, false);
    }

    float getRoughness()
    {
        return values.layers[desc.layerIdByType[MatConductor].id].albedo.a;
    }
    
    float4 getAlbedo()
    {
        return values.layers[desc.layerIdByType[MatLambert].id].albedo;
    }
};

ShadingGeometry prepareShadingGeometry(float3 P, float3 camPos, 
        float3 normal, float3 bitangent, float2 uv,
        #ifdef _MS_USER_DERIVATIVES
            float2 dPdx, float2 dPdy,
        #else
            float lodBias,
        #endif
    )
{
    /* Prepare shading geometry attributes */
    ShadingGeometry geom;
    geom.P = P;
    geom.E = normalize(camPos - P);
    geom.N = normalize(normal);
    geom.B = normalize(bitangent - geom.N * (dot(bitangent, geom.N)));
    geom.T = normalize(cross(geom.B, geom.N));
    geom.UV = uv;
    #ifdef _MS_USER_DERIVATIVES
        geom.DPDX = dPdx;
        geom.DPDY = dPdy;
    #else
        geom.lodBias = lodBias;
    #endif
    return geom;
}

struct Material : IMaterial
{
    typedef PreparedMaterialData EvaluatedMaterial;
    
    MaterialData materialData;
    void prepareForDepthPass(ShadingGeometry geom)
    {
         applyAlphaTest(materialData, geom, geom.P);
    }
    ShadingAttribsImpl<PreparedMaterialData> prepare(ShadingGeometry geom)
    {
        ShadingAttribsImpl<PreparedMaterialData> shAttr;
        shAttr.geom = geom;

        /* Copy the input material parameters */
#ifdef _MS_STATIC_MATERIAL_DESC
        MaterialDesc desc = _MS_STATIC_MATERIAL_DESC;
#else
        MaterialDesc desc = materialData.desc;
#endif

        shAttr.preparedMat.values = materialData.values;
        shAttr.preparedMat.desc = desc;

        /* Evaluate alpha test material modifier */
        applyAlphaTest(materialData, shAttr.geom, shAttr.geom.P);
        shAttr.preparedMat.aoFactor = 1;

        bool done = false;
        $for(iLayer in Range(0, MatMaxLayers))
        {
            if (shAttr.preparedMat.desc.layers[iLayer].type == MatNone)
                done = true;

            if (!done)
            {
                shAttr.preparedMat.values.layers[iLayer].albedo =
                    evalWithColor(desc.layers[iLayer].hasTexture, 
                    materialData.textures.layers[iLayer], materialData.samplerState, 
                    materialData.values.layers[iLayer].albedo, shAttr.geom);
            }
        }

        /* Perturb shading normal is needed */
        perturbNormal(materialData, shAttr.geom);
        return shAttr;
    }
};

struct StandardPreparedMaterialData<let HasDiffuse:int, let HasSpecular:int, let HasDieletric:int, let HasEmisive:int> : IBRDF
{
    MaterialDesc    desc;
    MaterialValues  values;
    
    // SLANG-INTEGRATION: move aoFactor from ShadingAttribs to PreparedMaterialData
    float aoFactor;

    // SLANG-INTEGRATION: PreparedMaterialData now implements IBRDF interface

    void eval(ShadingGeometry geom, LightAttribs lAttr, inout ShadingOutput result)
    {
        // call previous evalMaterial (now evalDefaultMaterial) function
        PreparedMaterialData pdata;
        pdata.desc = desc;
        pdata.values = values;
        pdata.aoFactor = aoFactor; 
        ShadingAttribsImpl<PreparedMaterialData> attr = makeShadingAttribs(geom, pdata);
        
        PassOutput passResult;
        passResult.value = 0;
        passResult.diffuseAlbedo = 0;
        passResult.diffuseIllumination = 0;
        passResult.specularAlbedo = 0;
        passResult.specularIllumination = 0;
        passResult.roughness = 0;
        passResult.effectiveRoughness = 0;

        int iLayer = 0;
        if (HasDiffuse)
        {
            MaterialLayerValues lvalues = values.layers[iLayer];
            float4 value = evalDiffuseLayer(lvalues, lAttr.lightIntensity, lAttr.L, attr.geom.N, passResult) * lAttr.shadowFactor;
            float3 oldValue = passResult.value;
            passResult.value = blendLayer(lvalues.albedo, value, BlendAdd, passResult.value);
            float delta = max(1e-3f, luminance(passResult.value - oldValue));
            passResult.effectiveRoughness += passResult.roughness * delta;
            iLayer++;
        }
        if (HasSpecular)
        {
            MaterialLayerValues lvalues = values.layers[iLayer];
            MaterialLayerDesc ldesc = desc.layers[iLayer];
            ldesc.ndf = NDFGGX;
            float4 value = evalSpecularLayer(ldesc, lvalues, attr.geom, lAttr, passResult) * lAttr.shadowFactor;
            float3 oldValue = passResult.value;
            passResult.value = blendLayer(lvalues.albedo, value, BlendAdd, passResult.value);
            float delta = max(1e-3f, luminance(passResult.value - oldValue));
            passResult.effectiveRoughness += passResult.roughness * delta;
            iLayer++;
        }
        if (HasDieletric)
        {
            MaterialLayerValues lvalues = values.layers[iLayer];
            MaterialLayerDesc ldesc = desc.layers[iLayer];
            ldesc.ndf = NDFGGX;
            float4 value = evalSpecularLayer(ldesc, lvalues, attr.geom, lAttr, passResult) * lAttr.shadowFactor;
            float3 oldValue = passResult.value;
            passResult.value = blendLayer(lvalues.albedo, value, BlendFresnel, passResult.value);
            float delta = max(1e-3f, luminance(passResult.value - oldValue));
            passResult.effectiveRoughness += passResult.roughness * delta;
            iLayer++;
        }
        if (HasEmisive)
        {
            MaterialLayerValues lvalues = values.layers[iLayer];
            float4 value = evalEmissiveLayer(lvalues, passResult);
            float3 oldValue = passResult.value;
            passResult.value = blendLayer(lvalues.albedo, value, BlendAdd, passResult.value);
            float delta = max(1e-3f, luminance(passResult.value - oldValue));
            passResult.effectiveRoughness += passResult.roughness * delta;
        }

        /* Accumulate the results of the pass */
        result.finalValue += passResult.value;
        result.effectiveRoughness += passResult.effectiveRoughness / max(1e-3f, luminance(passResult.value));
        result.diffuseIllumination += passResult.diffuseIllumination;
        result.specularIllumination += passResult.specularIllumination;
        result.diffuseAlbedo = passResult.diffuseAlbedo;
        result.specularAlbedo = passResult.specularAlbedo;
    }
    float getRoughness()
    {
        return values.layers[HasDiffuse].albedo.a;
    }
    
    float4 getAlbedo()
    {
        return values.layers[0].albedo;
    }
};

struct StandardMaterial<let HasDiffuse:int, let HasSpecular:int, let HasDieletric:int, let HasEmisive:int> : IMaterial
{
    typedef StandardPreparedMaterialData<HasDiffuse, HasSpecular, HasDieletric, HasEmisive> EvaluatedMaterial;
    
    MaterialData materialData;
    void prepareForDepthPass(ShadingGeometry geom)
    {
         applyAlphaTest(materialData, geom, geom.P);
    }
    ShadingAttribsImpl<StandardPreparedMaterialData<HasDiffuse, HasSpecular, HasDieletric, HasEmisive> > prepare(ShadingGeometry geom)
    {
        ShadingAttribsImpl<StandardPreparedMaterialData<HasDiffuse, HasSpecular, HasDieletric, HasEmisive> > shAttr;
        shAttr.geom = geom;
        
        shAttr.preparedMat.values = materialData.values;
        shAttr.preparedMat.desc = materialData.desc;

        /* Evaluate alpha test material modifier */
        applyAlphaTest(materialData, shAttr.geom, shAttr.geom.P);
        shAttr.preparedMat.aoFactor = 1;

        bool done = false;

        int layerCount = HasDiffuse + HasSpecular + HasDieletric + HasEmisive;
        for (int iLayer = 0; iLayer < layerCount; iLayer++)
        {
            shAttr.preparedMat.values.layers[iLayer].albedo =
                    evalWithColor(materialData.desc.layers[iLayer].hasTexture, 
                    materialData.textures.layers[iLayer], materialData.samplerState, 
                    materialData.values.layers[iLayer].albedo, shAttr.geom);
        }

        /* Perturb shading normal is needed */
        perturbNormal(materialData, shAttr.geom);
        return shAttr;
    }
};

/**
Prepares all light-independent attributes needed to perform shading at a hit point.
This includes fetching all textures and computing final shading attributes, like albedo and roughness.
After this step, one can save these shading attributes, e.g., in a G-Buffer to perform lighting afterwards.
This routine also applies all material modifiers, like performs alpha test and applies a normal map.
*/

void prepareShadingAttribs<TMaterial:IMaterial>(TMaterial material, in float3 P, in float3 camPos,
    in float3 normal, in float3 bitangent, in float2 uv,
#ifdef _MS_USER_DERIVATIVES
    float2 dPdx, float2 dPdy,
#else
    float lodBias,
#endif
    _ref(ShadingAttribsImpl<TMaterial.EvaluatedMaterial>) shAttr)
{
    ShadingGeometry geom = prepareShadingGeometry(P, camPos, normal, bitangent, uv,
    #ifdef _MS_USER_DERIVATIVES
        dPdx, dPdy,
    #else
        lodBias
    #endif
    );
    shAttr = material.prepare(geom);
}

/**
Another overload of PrepareShadingAttribs(), which does not require tangents.
Instead it constructs a world-space axis-aligned tangent frame on the fly.
*/
void _fn prepareShadingAttribs<TMaterial:IMaterial>(TMaterial material, in float3 P, in float3 camPos,
    in float3 normal, in float2 uv,
#ifdef _MS_USER_DERIVATIVES
    float2 dPdx, float2 dPdy,
#else
    float lodBias,
#endif
    _ref(ShadingAttribsImpl<TMaterial.EvaluatedMaterial>) shAttr)
{
    /* Generate an axis-aligned tangent frame */
    float3 bitangent;
    createTangentFrame(normal, bitangent);

    prepareShadingAttribs(material, P, camPos, normal, bitangent, uv,
#ifdef _MS_USER_DERIVATIVES
        dPdx, dPdy,
#else
        lodBias,
#endif
        shAttr);
}

#ifndef _MS_USER_DERIVATIVES
// Legacy version of prepareShadingAttribs() without LOD bias
void _fn prepareShadingAttribs<TMaterial:IMaterial>(TMaterial material, in float3 P, 
    in float3 camPos, in float3 normal, in float2 uv, 
    _ref(ShadingAttribsImpl<TMaterial.EvaluatedMaterial>) shAttr)
{
    prepareShadingAttribs(material, P, camPos, normal, uv, 0, shAttr);
}

void _fn prepareShadingAttribs<TMaterial:IMaterial>(TMaterial material, in float3 P, 
    in float3 camPos, in float3 normal, in float3 bitangent, in float2 uv, 
    _ref(ShadingAttribsImpl<TMaterial.EvaluatedMaterial>) shAttr)
{
    prepareShadingAttribs(material, P, camPos, normal, bitangent, uv, 0, shAttr);
}
#endif

float4 _fn evalEmissiveLayer(MaterialLayerValues layer, _ref(PassOutput) result)
{
    result.diffuseAlbedo += 1.f;
    result.diffuseIllumination += layer.albedo.rgb;
    return (1).rrrr;
}

float4 _fn evalDiffuseLayer(MaterialLayerValues layer, float3 lightIntensity, float3 lightDir, float3 normal, _ref(PassOutput) result)
{
    float3 value = lightIntensity;
    float weight = 0;
    float4 albedo = layer.albedo;
    result.roughness = 1;
#ifndef _MS_DISABLE_DIFFUSE
    value *= evalDiffuseBSDF(normal, lightDir);
    weight = albedo.w;
    result.diffuseAlbedo += albedo.rgb * layer.pmf;
    result.diffuseIllumination += value;
#else
    value = 0;
#endif
    return float4(value, weight);
}

// Implementation of NDF filtering code from the HPG'16 submission
// The writeup is here: //research/graphics/projects/halfvectorSpace/SAA/paper/specaa-sub.pdf
float2 _fn filterRoughness(ShadingGeometry shAttr, LightAttribs lAttr, in float2 roughness)
{
#ifdef _MS_USER_HALF_VECTOR_DERIVATIVES
    float2  hppDx = shAttr.DHDX;
    float2  hppDy = shAttr.DHDY;
#else
    // Compute half-vector derivatives
    float3  H = normalize(shAttr.E + lAttr.L);
    float2  hpp = float2(dot(H, shAttr.T), dot(H, shAttr.B));
    float2  hppDx = ddx_fine(hpp);
    float2  hppDy = ddy_fine(hpp);
#endif
    // Compute filtering region
    float2 rectFp = (abs(hppDx) + abs(hppDy)) * 0.5f;

    // For grazing angles where the first-order footprint goes to very high values
    // Usually you don’t need such high values and the maximum value of 1.0 or even 0.1 is enough for filtering.
    rectFp = min(0.7f, rectFp);

    // Covariance matrix of pixel filter's Gaussian (remapped in roughness units)
    float2 covMx = rectFp * rectFp * 2.f;   // Need to x2 because roughness = sqrt(2) * pixel_sigma_hpp

    roughness = sqrt(roughness*roughness + covMx);          // Beckmann proxy convolution for GGX

    return roughness;
}

float4 _fn evalSpecularLayer(MaterialLayerDesc desc, MaterialLayerValues data, ShadingGeometry shAttr, LightAttribs lAttr, _ref(PassOutput) result)
{
#ifndef _MS_DISABLE_SPECULAR
    /* Add albedo regardless of facing */
    result.specularAlbedo += data.albedo.rgb * data.pmf;

    /* Ignore the layer if it's a transmission or backfacing */
    if (dot(lAttr.L, shAttr.N) * dot(shAttr.E, shAttr.N) <= 0.f)
    {
        return 0;
    }

    float3 value = lAttr.lightIntensity;

    float2 roughness;
    if(desc.hasTexture & ROUGHNESS_CHANNEL_BIT)
    {
        roughness = float2(data.albedo.w, data.albedo.w);
    }
    else
    {
        roughness = data.roughness.rg;
    }

#ifndef _MS_DISABLE_ROUGHNESS_FILTERING
    roughness = filterRoughness(shAttr, lAttr, roughness);
#endif

    // Respect perfect specular cutoff
    if(max(roughness.x, roughness.y) < 1e-3f)
    {
        return 0;
    }
    
    // compute halfway vector
    float3 hW = normalize(shAttr.E + lAttr.L);
    float3 h = normalize(float3(dot(hW, shAttr.T), dot(hW, shAttr.B), dot(hW, shAttr.N)));

    result.roughness = roughness;

    switch (desc.ndf)
    {
    case NDFBeckmann: /* Beckmann microfacet distribution */
    {
        value *= evalBeckmannDistribution(h, roughness);
    }
    break;
    case NDFGGX: /* GGX */
    {
        value *= evalGGXDistribution(h, roughness);
    }
    break;
    }

    /* Evaluate standard microfacet model terms */
    value *= evalMicrofacetTerms(shAttr.T, shAttr.B, shAttr.N, h, shAttr.E, lAttr.L, roughness, desc.ndf, (desc.type) == MatDielectric);

    /* Cook-Torrance Jacobian */
    value /= 4.f * dot(shAttr.E, shAttr.N);

    /* Fresnel conductor/dielectric term */
    float HoE = dot(hW, shAttr.E);
    float IoR = data.extraParam.x;
    float kappa = data.extraParam.y;
    float F_term = (desc.type == MatConductor) ? conductorFresnel(HoE, IoR, kappa) : 1.f - dielectricFresnel(HoE, IoR);
    value *= F_term;
    float weight = F_term;

    result.specularIllumination += value;

    return float4(value, weight);
#else
    return 0;
#endif
}

float3 _fn blendLayer(float4 albedo, float4 layerOut, uint blendType, float3 currentValue)
{
    /* Account for albedo */
    float3 scaledLayerOut = layerOut.rgb * albedo.rgb;
    float weight = layerOut.w;

    /* Perform layer blending */
    if(blendType == BlendConstant)
    {
        weight = albedo.w;
    }

    float3 result;
    if(blendType != BlendAdd)
    {
        result = lerp(currentValue, scaledLayerOut, weight);
    }
    else
    {
        result = currentValue + scaledLayerOut;
    }
    return result;
}

/**
A helper routine for evaluating a single layer of a layered material, given a shading point and a point on a light source.
The routine takes a layer index, as well as shading attributes, including prepared layers of the material;
it also takes prepared attributes of a light source, such as incident radiance and a world-space direction to the light.
The output is the illumination of the current layer, blended into the results of the previous layers with a specified blending mode.
*/
void _fn evalMaterialLayer(int iLayer, ShadingAttribsImpl<PreparedMaterialData> attr, LightAttribs lAttr,
    _ref(PassOutput) result)
{
    float4 value = 0;

    MaterialLayerValues values = attr.preparedMat.values.layers[iLayer];
    MaterialLayerDesc desc = attr.preparedMat.desc.layers[iLayer];
    switch(desc.type)
    {
    case MatLambert: /* Diffuse BRDF */
        value = evalDiffuseLayer(values, lAttr.lightIntensity, lAttr.L, attr.geom.N, result) * lAttr.shadowFactor;
        break;
    case MatEmissive:
        value = evalEmissiveLayer(values, result);
        break;
    case MatConductor:
    case MatDielectric:
        value = evalSpecularLayer(desc, values, attr.geom, lAttr, result) * lAttr.shadowFactor;
        break;
    };

    float3 oldValue = result.value;
    result.value = blendLayer(values.albedo, value, desc.blending, result.value);

    float delta = max(1e-3f, luminance(result.value - oldValue));
    result.effectiveRoughness += result.roughness * delta;
}

// SLANG-INTEGRATION: evalMaterial function now becomes a generic function that
// calls the IBRDF.eval() method
void evalMaterial<TBRDF : IBRDF>(
    ShadingAttribsImpl<TBRDF> shAttr,
    LightAttribs lAttr,
    _ref(ShadingOutput) result,
    bool initializeShadingOut DEFAULTS(false))
{
    if (initializeShadingOut)
        result = initShadingOutput();
    shAttr.preparedMat.eval(shAttr.geom, lAttr, result);
}

// SLANG-INTEGRATION: rename all evalMaterial functions to evalDefaultMaterial
// and these functions takes renamed ShadingAttribs (now ShadingAttribsImpl<PreparedMaterialData>)
// as its argument

/**	The highest-level material evaluation function.
This is the main routing for evaluating a complete PBR material, given a shading point and a light source.
Should be called once per light.
*/
void _fn evalDefaultMaterial(
    ShadingAttribsImpl<PreparedMaterialData> shAttr,
    LightAttribs lAttr,
    _ref(ShadingOutput) result,
    bool initializeShadingOut DEFAULTS(false))
{
    /* Go through all layers and perform a layer-by-layer shading and compositing */
    PassOutput passResult;
    passResult.value = 0;
    passResult.diffuseAlbedo = 0;
    passResult.diffuseIllumination = 0;
    passResult.specularAlbedo = 0;
    passResult.specularIllumination = 0;
    passResult.roughness = 0;
    passResult.effectiveRoughness = 0;

#if 0
    [unroll]
    for(uint iLayer = 0 ; iLayer < MatMaxLayers ; iLayer++)
    {
        if(shAttr.preparedMat.desc.layers[iLayer].type == MatNone) break;
        evalMaterialLayer(iLayer, shAttr, lAttr, passResult);
    }
#else
    bool done = false;
    $for(iLayer in Range(0, MatMaxLayers))
    {
        if(shAttr.preparedMat.desc.layers[iLayer].type == MatNone) done = true;
        if( !done )
        {
            evalMaterialLayer(iLayer, shAttr, lAttr, passResult);
        }
    }
#endif
    /* Accumulate the results of the pass */
    result.finalValue += passResult.value;
    result.effectiveRoughness += passResult.effectiveRoughness / max(1e-3f, luminance(passResult.value));
    result.diffuseIllumination += passResult.diffuseIllumination;
    result.specularIllumination += passResult.specularIllumination;
    result.diffuseAlbedo = passResult.diffuseAlbedo;
    result.specularAlbedo = passResult.specularAlbedo;
}

void evalQuadLight(
    PreparedMaterialData    bxdf,
    ShadingGeometry         geom,
    QuadLight               quadLight, 
    LightAttribs            lAttr,
    inout ShadingOutput     result)
{
    PassOutput passResult;
    passResult.value = 0;
    passResult.diffuseAlbedo = 0;
    passResult.diffuseIllumination = 0;
    passResult.specularAlbedo = 0;
    passResult.specularIllumination = 0;
    passResult.roughness = 0;
    passResult.effectiveRoughness = 0;

    float3 diff, spec;
    evalAreaLight(geom.N, geom.E, geom.P, 
        bxdf.getRoughness(), 
        lAttr.lightIntensity, 
        lAttr.points, false,
        quadLight,
        diff,
        spec);

    diff *= bxdf.getAlbedo().xyz;
    spec *= bxdf.getAlbedo().xyz;

    passResult.value += diff + spec;
    passResult.diffuseIllumination += diff;
    passResult.specularIllumination += spec;

    result.finalValue += passResult.value;
    result.effectiveRoughness += passResult.effectiveRoughness / max(1e-3f, luminance(passResult.value));
    result.diffuseIllumination += passResult.diffuseIllumination;
    result.specularIllumination += passResult.specularIllumination;
    result.diffuseAlbedo = passResult.diffuseAlbedo;
    result.specularAlbedo = passResult.specularAlbedo;
}

void evalQuadLight<let HasDiffuse:int, let HasSpecular:int, let HasDieletric:int, let HasEmisive:int>(
    StandardPreparedMaterialData<HasDiffuse,HasSpecular,HasDieletric, HasEmisive>    bxdf,
    ShadingGeometry         geom,
    QuadLight               quadLight, 
    LightAttribs            lAttr,
    inout ShadingOutput     result)
{
    PassOutput passResult;
    passResult.value = 0;
    passResult.diffuseAlbedo = 0;
    passResult.diffuseIllumination = 0;
    passResult.specularAlbedo = 0;
    passResult.specularIllumination = 0;
    passResult.roughness = 0;
    passResult.effectiveRoughness = 0;

    float3 diff, spec;
    evalAreaLight(geom.N, geom.E, geom.P, 
        bxdf.getRoughness(), 
        lAttr.lightIntensity, 
        lAttr.points, false,
        quadLight,
        diff,
        spec);

    diff *= bxdf.getAlbedo().xyz;
    spec *= bxdf.getAlbedo().xyz;

    passResult.value += diff + spec;
    passResult.diffuseIllumination += diff;
    passResult.specularIllumination += spec;

    result.finalValue += passResult.value;
    result.effectiveRoughness += passResult.effectiveRoughness / max(1e-3f, luminance(passResult.value));
    result.diffuseIllumination += passResult.diffuseIllumination;
    result.specularIllumination += passResult.specularIllumination;
    result.diffuseAlbedo = passResult.diffuseAlbedo;
    result.specularAlbedo = passResult.specularAlbedo;
}


void _fn evalMaterial<TBRDF : IBRDF, TLight : ILight>(
    ShadingAttribsImpl<TBRDF> shAttr,
    TLight light,
    float shadowFactor,
    _ref(ShadingOutput) result,
    bool initializeShadingOut DEFAULTS(false))
{
    if(initializeShadingOut)
    {
        result.diffuseAlbedo = 0;
        result.diffuseIllumination = 0;
        result.specularAlbedo = 0;
        result.specularIllumination = 0;
        result.finalValue = 0;
        result.effectiveRoughness = 0;
        result.wi = 0;
        result.pdf = 0;
        result.thp = 0;
    }
    light.evalLighting(shAttr, shadowFactor, result);
}

/**
Another overload of material evaluation function, which prepares light attributes internally.
*/
void _fn evalMaterial<TBRDF : IBRDF, TLight : ILight>(
    ShadingAttribsImpl<TBRDF> shAttr,
    TLight light,
    _ref(ShadingOutput) result,
    bool initializeShadingOut DEFAULTS(false))
{
    evalMaterial(shAttr, light, 1, result, initializeShadingOut);
}

/*******************************************************************
Material building helpers
*******************************************************************/

/**
Initializes a material layer with an empty layer
*/
void _fn initNullLayer(_ref(MaterialLayerDesc) layer)
{
    layer.type = MatNone;
    layer.blending = BlendAdd;
    layer.hasTexture = false;
    layer.ndf = NDFUser;
}

/**
Initializes a material layer with diffuse BRDF
*/
void _fn initDiffuseLayer(_ref(MaterialLayerDesc) desc, _ref(MaterialLayerValues) data, float3 albedo)
{
    desc.type = MatLambert;
    desc.blending = BlendAdd;
    desc.hasTexture = false;
    desc.ndf = NDFGGX;
    data.albedo = float4(albedo, 1.f);
    data.extraParam = float4(0,0,0,0);
    data.roughness = float4(0,0,0,0);
    data.pad = float3(0,0,0);
    data.pmf = 1;
}

/**
Initializes a material layer with conductor BRDF. IoR and Kappa are set to the values of chrome by default.
*/
void _fn initConductorLayer(_ref(MaterialLayerDesc) desc, _ref(MaterialLayerValues) data, float3 color, float roughness, float IoR = 3.f, float kappa = 4.2f)
{
    desc.type = MatConductor;
    desc.blending = BlendAdd;
    data.albedo = float4(color, 1.f);
    data.roughness = roughness.rrrr;
    data.extraParam.x = IoR;
    data.extraParam.y = kappa;
    data.pmf = 1;
}

/**
Initializes a material layer with dielectric BRDF.
*/
void _fn initDielectricLayer(_ref(MaterialLayerDesc) desc, _ref(MaterialLayerValues) data, float3 color, float roughness, float IoR)
{
    desc.type = MatDielectric;
    desc.blending = BlendFresnel;
    data.albedo = float4(color, 1.f);
    data.roughness = roughness.rrrr;
    data.extraParam.x = IoR;
    data.pmf = 1;
}

/*******************************************************************
Simple material helpers
*******************************************************************/

/**
Tries to find a layer data for a given material type (diffuse/conductor/etc).
\param[in] material         Material to look in
\param[in] layerType        Material layer Type (MatLambert/MatConductor etc.)
\param[out] data           Layer data, if found
returns false if the layer is not found, true otherwise
*/
bool _fn getLayerByType(PreparedMaterialData material, uint layerType, _ref(MaterialLayerValues) data, _ref(MaterialLayerDesc) desc)
{
    int layerId = material.desc.layerIdByType[layerType].id;
    if(layerId != -1)
    {
        data = material.values.layers[layerId];
        desc = material.desc.layers[layerId];
        return true;
    }
    return false;
}

/**
Tries to find a diffuse albedo color for a given material
\param[in] Material Material to look in
returns black if the layer is not found, diffuse albedo color otherwise
*/
float4 _fn getDiffuseColor(ShadingAttribsImpl<PreparedMaterialData> shAttr)
{
    float4 ret = 0;
    // This is here because the HLSL compiler complains about 'data' not being completely initialized when used
    int layerId = shAttr.preparedMat.desc.layerIdByType[MatLambert].id;
    if (layerId != -1)
    {
        MaterialLayerValues data;
        MaterialLayerDesc   desc;
        getLayerByType(shAttr.preparedMat, MatLambert, data, desc);
        ret = data.albedo;
    }
    return ret;
}

/**
Tries to override a diffuse albedo color for all layers within a given material
\param[in] Material Material to look in
returns true if succeeded
*/
bool _fn overrideDiffuseColor(_ref(ShadingAttribsImpl<PreparedMaterialData>) shAttr, float4 albedo, bool allLayers = true)
{
    bool found = false;
    if(!allLayers)
    {
        int layerId = shAttr.preparedMat.desc.layerIdByType[MatLambert].id;
        if(layerId != -1)
        {
            found = true;
            shAttr.preparedMat.values.layers[layerId].albedo = albedo;
        }
    }
    else
    {
        for(uint iLayer = 0 ; iLayer < MatMaxLayers ; iLayer++)
        {
            if(shAttr.preparedMat.desc.layers[iLayer].type == MatNone) break;

            if(shAttr.preparedMat.desc.layers[iLayer].type == MatLambert)
            {
                shAttr.preparedMat.values.layers[iLayer].albedo = albedo;
                found = true;
            }
        }
    }
    return found;
}

/**
Tries to find a specular albedo color for a given material
\param[in] material Material to look in
returns black if the layer is not found, specular color otherwise
*/
float4 _fn getSpecularColor(ShadingAttribsImpl<PreparedMaterialData> shAttr)
{
    float4 ret = 0;
    MaterialLayerValues data;
    MaterialLayerDesc   desc;
    if(getLayerByType(shAttr.preparedMat, MatConductor, data, desc))
    {
        ret = data.albedo;
    }
    return ret;
}

/**
    This routine importance samples the BRDF for path tracer next event
    estimation. A new direction is chosen based on the material properties.

    \param[in] shAttr Complete information about the shading point
    \param[in] rSample Random numbers for sampling
    \param[out] result Gather incident direction, probability density function, and path throughput
*/
void _fn sampleMaterial(
    ShadingAttribsImpl<PreparedMaterialData> shAttr,
    in float2 rSample,
    _ref(ShadingOutput) result)
{
    bool sampleDiffuse = true;

    // Set the initial path throughput
    result.thp = 0;
    result.diffuseAlbedo = 0;
    result.specularAlbedo = 0;

    // Sample specular layer if it exists
    MaterialLayerValues specData;
    MaterialLayerDesc   specDesc;
    if(getLayerByType(shAttr.preparedMat, MatConductor, specData, specDesc))
    {
        // Randomly sample the specular component by using the probability mass function
        if (rSample.x < specData.pmf)
        {
            // Rescale random number value
            rSample.x /= specData.pmf;

            sampleDiffuse = false;

            float3 m;
            float3 wo = toLocal(shAttr.geom.E, shAttr.geom.T, shAttr.geom.B, shAttr.geom.N);
            float2 roughness = float2(specData.roughness.x, specData.roughness.y);

            // Set the specular reflectivity
            result.specularAlbedo = specData.albedo.rgb;
            result.thp = result.specularAlbedo;

            // Choose the appropriate normal distribution function
            switch(specDesc.ndf)
            {
            case NDFBeckmann: // Beckmann normal distribution function 
            {
                result.thp *= sampleBeckmannDistribution(wo, roughness, rSample, m, result.wi, result.pdf);
            }
            break;

            case NDFGGX: // GGX normal distribution function
            {
                result.thp *= sampleGGXDistribution(wo, roughness, rSample, m, result.wi, result.pdf);
            }
            break;
            }

            // Convert direction vector from local to global frame
            // global space coordinates
            result.wi = fromLocal(result.wi, shAttr.geom.T, shAttr.geom.B, shAttr.geom.N);

            // Evaluate standard microfacet model terms
            result.thp *= evalMicrofacetTerms(shAttr.geom.T, shAttr.geom.B, shAttr.geom.N, m, shAttr.geom.E, result.wi, roughness, specDesc.ndf, (specDesc.type) == MatDielectric);

            // Fresnel conductor/dielectric term
            float HoE = dot(m, shAttr.geom.E);
            float IoR = specData.extraParam.x;
            float kappa = specData.extraParam.y;
            float F_term = (specDesc.type == MatConductor) ? conductorFresnel(HoE, IoR, kappa) : 1.f - dielectricFresnel(HoE, IoR);
            result.thp *= F_term;

            result.effectiveRoughness = roughness;
        }
        else
        {
            // Rescale random number value
            rSample.x -= specData.pmf;
            rSample.x /= 1.f - specData.pmf;
        }
    }

    // Sample the diffuse component
    if (sampleDiffuse)
    {
        // Cosine lobe sampling
        result.wi = cosine_sample_hemisphere(rSample.x, rSample.y);

        // Convert direction vector from local to global frame
        // global space coordinates
        result.wi = fromLocal(result.wi, shAttr.geom.T, shAttr.geom.B, shAttr.geom.N);

        // Ideally thp = (\rho / \pi) * |\omega_i . n| / bsdfPdf
        // By importance sampling the cosine lobe, we can set bsdfPdf = |\omega_i . n| / \pi
        // Thus, we can simplify thp = \rho
        result.thp = getDiffuseColor(shAttr).rgb;
        result.diffuseAlbedo = result.thp;

        // Probability density function for perfect importance sampling of cosine lobe 
        result.pdf = M_1_PIf;

        // Record roughness for diffuse brdf
        result.effectiveRoughness = 1;
    }
}

#endif	// _FALCOR_SHADING_H_
