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

__import ShaderCommonImpl;
__import Shading;
__import Interfaces;

// Debug modes
#define ShowPos         1
#define ShowNormals     2
#define ShowAlbedo      3
#define ShowLighting    4

#ifdef FALCOR_HLSL
// Some macros to help us call this function from HLSL
#define vec3 float3
#define vec4 float4
#endif

struct LightingPassParams
{
    // G-Buffer
    // Lighting params
	LightData gDirLight;
	LightData gPointLight;
	float3 gAmbient;
    // Debug mode
	uint gDebugMode;
};

vec3 shade(LightingPassParams params, vec3 posW, vec3 normalW, vec4 albedo)
{
    // Discard empty pixels
    if (albedo.a <= 0)
    {
        discard;
    }

    /* Reconstruct shading attributes */
    ShadingAttribsImpl<PreparedMaterialData> shAttr;
    shAttr.geom.P = posW;
    shAttr.geom.E = normalize(gCam.position - posW);
    shAttr.geom.N = normalW;

    /* Reconstruct layers (one diffuse layer) */
    initDiffuseLayer(shAttr.preparedMat.desc.layers[0], shAttr.preparedMat.values.layers[0], albedo.rgb);
    initNullLayer(shAttr.preparedMat.desc.layers[1]);

    /* Do lighting */
    ShadingOutput result;
    // Directional light
    evalMaterial(shAttr, params.gDirLight, result, true);
    // Point light
    evalMaterial(shAttr, params.gPointLight, result, false);
    // Add ambient term
    result.finalValue += params.gAmbient * result.diffuseAlbedo;
    result.diffuseIllumination += params.gAmbient;

    // Debug vis
    if (params.gDebugMode != 0)
    {
        if (params.gDebugMode == ShowPos)
            result.finalValue = posW;
        else if (params.gDebugMode == ShowNormals)
            result.finalValue = 0.5 * normalW + 0.5f;
        else if (params.gDebugMode == ShowAlbedo)
            result.finalValue = albedo.rgb;
        else
            result.finalValue = result.diffuseIllumination;
    }

    return result.finalValue;
}