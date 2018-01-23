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
#include "Framework.h"
#include "Material.h"
#include "API/ConstantBuffer.h"
#include "API/Texture.h"
#include "API/Buffer.h"
#include "Utils/Platform/OS.h"
#include "Utils/Math/FalcorMath.h"
#include "MaterialSystem.h"
#include "Graphics/Program/ProgramVars.h"
#include "Graphics/Program/GraphicsProgram.h"
#include <cstring>
#include <sstream>
namespace Falcor
{
    static const char* kMaterialVarName = "materialBlock";
    uint32_t Material::sMaterialCounter = 0;
    std::vector<Material::DescId> Material::sDescIdentifier;
    ParameterBlockReflection::SharedConstPtr Material::spBlockReflection;

    Material::Material(const std::string& name) : mName(name)
    {
        mData.values.id = sMaterialCounter;
        sMaterialCounter++;
        createParameterBlock();
    }

    Material::SharedPtr Material::create(const std::string& name)
    {
        Material* pMaterial = new Material(name);
        gEventCounter.numMaterials++;
        return SharedPtr(pMaterial);
    }

    Material::~Material()
    {
        gEventCounter.numMaterials--;
        removeDescIdentifier();
    }
    
    void Material::resetGlobalIdCounter()
    {
        sMaterialCounter = 0;
    }

    uint32_t Material::getNumLayers() const
    {
        finalize();
        uint32_t i = 0;
        for(; i < MatMaxLayers; ++i)
        {
            if(mData.desc.layers[i].type == MatNone)
            {
                break;
            }
        }
        return i;
    }

    Material::Layer Material::getLayer(uint32_t layerIdx) const
    {
        finalize();
        Layer layer;
        if(layerIdx < getNumLayers())
        {
            const auto& desc = mData.desc.layers[layerIdx];
            const auto& vals = mData.values.layers[layerIdx];

            layer.albedo = vals.albedo;
            layer.roughness = vals.roughness;
            layer.extraParam = vals.extraParam;
            layer.pTexture = mData.textures.layers[layerIdx];

            layer.type = (Layer::Type)desc.type;
            layer.ndf = (Layer::NDF)desc.ndf;
            layer.blend = (Layer::Blend)desc.blending;
            layer.pmf = vals.pmf;
        }

        return layer;
    }

    bool Material::addLayer(const Layer& layer)
    {
        size_t numLayers = getNumLayers();
        if(numLayers >= MatMaxLayers)
        {
            logError("Exceeded maximum number of layers in a material");
            return false;
        }

        auto& desc = mData.desc.layers[numLayers];
        auto& vals = mData.values.layers[numLayers];
        
        vals.albedo = layer.albedo;
        vals.roughness = layer.roughness;
        vals.extraParam = layer.extraParam;

        mData.textures.layers[numLayers] = layer.pTexture;
        desc.hasTexture = (layer.pTexture != nullptr);

        desc.type = (uint32_t)layer.type;
        desc.ndf = (uint32_t)layer.ndf;
        desc.blending = (uint32_t)layer.blend;
        vals.pmf = layer.pmf;
        mDescDirty = true;

        // Update the index by type
        if(desc.type != MatNone && mData.desc.layerIdByType[desc.type].id == -1)
        {
            mData.desc.layerIdByType[desc.type].id = (int)numLayers;
        }
        
        // For dielectric and conductors, check if we have roughness
        if (layer.type == Layer::Type::Dielectric || layer.type == Layer::Type::Conductor)
        {
            if (desc.hasTexture)
            {
                ResourceFormat texFormat = layer.pTexture->getFormat();
                if (getFormatChannelCount(texFormat) == 4)
                {
                    switch (texFormat)
                    {
                    case ResourceFormat::BGRX8Unorm:
                    case ResourceFormat::BGRX8UnormSrgb:
                        break;
                    default:
                        desc.hasTexture |= ROUGHNESS_CHANNEL_BIT;
                    }
                }
            }
        }
        return true;
    }

    void Material::removeLayer(uint32_t layerIdx)
    {
        if(layerIdx >= getNumLayers())
        {
            assert(false);
            return;
        }

        const bool needCompaction = layerIdx + 1 < getNumLayers();
        mData.desc.layers[layerIdx].type = MatNone;
        mData.values.layers[layerIdx] = MaterialLayerValues();

        /* If it's not the last material, compactify layers */
        if(needCompaction)
        {
            for(int i = 0; i < MatMaxLayers - 1; ++i)
            {
                bool hasHole = mData.desc.layers[i].type == MatNone && mData.desc.layers[i + 1].type != MatNone;
                if(!hasHole)
                {
                    continue;
                }
                std::memmove(&mData.desc.layers[i], &mData.desc.layers[i+1], sizeof(mData.desc.layers[0]));
                std::memmove(&mData.values.layers[i], &mData.values.layers[i + 1], sizeof(mData.values.layers[0]));
                mData.desc.layers[i+1].type = MatNone;
                mData.values.layers[i+1] = MaterialLayerValues();
            }
        }

        // Update indices by type
        memset(&mData.desc.layerIdByType, -1, sizeof(mData.desc.layerIdByType));
        for(int i = 0; i < MatMaxLayers - 1; ++i)
        {
            if(mData.desc.layers[i].type != MatNone && mData.desc.layerIdByType[mData.desc.layers[i].type].id != -1)
            {
                mData.desc.layerIdByType[mData.desc.layers[i].type].id = i;
            }
        }

        mDescDirty = true;
    }

    void Material::normalize() const
    {
        float totalAlbedo = 0.f;

        /* Compute a conservative worst-case albedo from all layers */
        for(size_t i=0;i < MatMaxLayers;++i)
        {
            const MaterialLayerValues& values = mData.values.layers[i];
            const MaterialLayerDesc& desc = mData.desc.layers[i];

            if(desc.type != MatLambert && desc.type != MatConductor && desc.type != MatDielectric)
            {
                break;
            }

            // TODO: compute maximum texture albedo once there is an interface for it in the future
            float albedo = luminance(glm::vec3(values.albedo));

            if(desc.blending == BlendAdd || desc.blending == BlendFresnel)
            {
                totalAlbedo += albedo;
            }
            else
            {
                totalAlbedo += glm::mix(totalAlbedo, albedo, values.albedo.w);
            }
        }

        if(totalAlbedo == 0.f)
        {
            logWarning("Material " + mName + " is pitch black");
            totalAlbedo = 1.f;
        }
        else if(totalAlbedo > 1.f)
        {
            logWarning("Material " + mName + " is not energy conserving. Renormalizing...");

            /* Renormalize all albedos assuming linear blending between layers */
            for(size_t i = 0;i < MatMaxLayers;++i)
            {
                MaterialLayerValues& values = mData.values.layers[i];
                const MaterialLayerDesc& desc = mData.desc.layers[i];
                if (desc.type != MatLambert && desc.type != MatConductor && desc.type != MatDielectric)
                {
                    break;
                }

                glm::vec3 newAlbedo = glm::vec3(values.albedo);
                newAlbedo /= totalAlbedo;
                values.albedo = glm::vec4(newAlbedo, values.albedo.w);
            }
            totalAlbedo = 1.f;
        }

        /* Construct the normalized PMF for sampling layers based on albedos and assuming linear blending between layers */
        float currentWeight = 1.f;
        for(int i = MatMaxLayers-1;i >=0;--i)
        {
            MaterialLayerValues& values = mData.values.layers[i];
            const MaterialLayerDesc& desc = mData.desc.layers[i];
            if (desc.type != MatLambert && desc.type != MatConductor && desc.type != MatDielectric)
            {
                continue;
            }

            float albedo = luminance(glm::vec3(values.albedo));
            /* Embed the expected probability that is based on the constant blending */
            if(desc.blending == BlendConstant)
            {
                albedo *= values.albedo.w;
            }
            albedo *= currentWeight;

            values.pmf = albedo / totalAlbedo;

            /* Maintain the expected blending probability for the next level*/
            if(desc.blending == BlendConstant)
            {
                currentWeight = max(0.f, 1.f - currentWeight);
                assert(currentWeight > 0.f);
            }
            else
            {
                currentWeight = 1.f;
            }
        }
    }

    void Material::updateTextureCount() const
    {
        mTextureCount = 0;
        auto pTextures = (Texture::SharedPtr*)&mData.textures;

        for (uint32_t i = 0; i < kTexCount; i++)
        {
            if (pTextures[i] != nullptr)
            {
                mTextureCount++;
            }
        }
    }

#if _LOG_ENABLED
#define check_offset(_a) assert(pCB->getVariableOffset(std::string(varName) + #_a) == (offsetof(MaterialData, _a) + offset))
#else
#define check_offset(_a)
#endif

    static void setMaterialIntoBlockCommon(ParameterBlock* pBlock, ConstantBuffer* pCB, size_t offset, const std::string& varName, const MaterialData& data)
    {
        // First set the desc and the values
        static const size_t dataSize = sizeof(MaterialDesc) + sizeof(MaterialValues);
        static_assert(dataSize % sizeof(glm::vec4) == 0, "Material::MaterialData size should be a multiple of 16");

        check_offset(values.layers[0].albedo);
        check_offset(values.id);
        assert(offset + dataSize <= pCB->getSize());

        pCB->setBlob(&data, offset, dataSize);

        // Now set the textures
        std::string resourceName = varName + "textures.layers";
        const auto binding = pBlock->getReflection()->getResourceBinding(resourceName);
        if (binding.setIndex == ParameterBlockReflection::BindLocation::kInvalidLocation)
        {
            logWarning(std::string("setMaterialIntoBlockCommon() - can't find the first texture object"));
            return;
        }

        // Bind the layers (they are an array)
        for (uint32_t i = 0; i < MatMaxLayers; i++)
        {
            const auto& pSrv = (data.textures.layers[i] != nullptr) ? data.textures.layers[i]->getSRV() : nullptr;
            pBlock->setSrv(binding, i, pSrv);
        }

        pBlock->setTexture(varName + "textures.normalMap", data.textures.normalMap);
        pBlock->setTexture(varName + "textures.ambientMap", data.textures.ambientMap);
        pBlock->setTexture(varName + "textures.alphaMap", data.textures.alphaMap);
        pBlock->setTexture(varName + "textures.heightMap", data.textures.heightMap);
        pBlock->setSampler(varName + "samplerState", data.samplerState);
    }

    void Material::setIntoParameterBlock(ParameterBlock* pBlock) const
    {
        finalize();
        ConstantBuffer* pCB = pBlock->getConstantBuffer(pBlock->getReflection()->getName()).get();
        setMaterialIntoBlockCommon(pBlock, pCB, 0, "materialData.", mData);
    }

    void Material::setIntoProgramVars(ProgramVars* pVars, ConstantBuffer* pCb, const char varName[]) const
    {
        finalize();
        size_t offset = pCb->getVariableOffset(varName);

        if (offset == ConstantBuffer::kInvalidOffset)
        {
            logError(std::string("Material::setIntoProgramVars() - variable \"") + varName + "\" not found in constant buffer\n");
            return;
        }
        setMaterialIntoBlockCommon(pVars->getDefaultBlock().get(), pCb, offset, std::string(varName) + '.', mData);
    }

    void Material::setSampler(const Sampler::SharedPtr& pSampler)
    {
        mData.samplerState = pSampler;
        mpParamBlock->setSampler("materialData.samplerState", pSampler);
    }

    bool Material::operator==(const Material& other) const
    {
        return std::memcmp(&mData, &other.mData, sizeof(mData)) == 0 && mData.samplerState == other.mData.samplerState;
    }

    void Material::setLayerTexture(uint32_t layerId, const Texture::SharedPtr& pTexture)
    {
        mData.textures.layers[layerId] = pTexture;
        mData.desc.layers[layerId].hasTexture = (pTexture != nullptr);
        mDescDirty = true;
    }

    void Material::setNormalMap(Texture::SharedPtr& pNormalMap)
    {
        mData.textures.normalMap = pNormalMap; 
        mData.desc.hasNormalMap = (pNormalMap != nullptr);
        mDescDirty = true;
    }

    void Material::setAlphaMap(const Texture::SharedPtr& pAlphaMap)
    { 
        mData.textures.alphaMap = pAlphaMap;
        mData.desc.hasAlphaMap = (pAlphaMap != nullptr);
        mDescDirty = true;
    }

    void Material::setAmbientOcclusionMap(const Texture::SharedPtr& pAoMap)
    {
        mData.textures.ambientMap = pAoMap;
        mData.desc.hasAmbientMap = (pAoMap != nullptr);
        mDescDirty = true;
    }

    void Material::setHeightMap(const Texture::SharedPtr& pHeightMap)
    { 
        mData.textures.heightMap = pHeightMap;
        mData.desc.hasHeightMap = (pHeightMap != nullptr);
        mDescDirty = true;
    }

    void Material::removeDescIdentifier() const
    {
        for(size_t i = 0 ; i < sDescIdentifier.size() ; i++)
        {
            if(mDescIdentifier == sDescIdentifier[i].id)
            {
                sDescIdentifier[i].refCount--;
                if(sDescIdentifier[i].refCount == 0)
                {
                    MaterialSystem::removeMaterial(mDescIdentifier);
                    sDescIdentifier.erase(sDescIdentifier.begin() + i);
                }
            }
        }
    }

    void Material::updateDescIdentifier() const
    {
        static uint64_t identifier = 0;

        removeDescIdentifier();
        mDescDirty = false;
        for(auto& a : sDescIdentifier)
        {
            if(std::memcmp(&mData.desc, &a.desc, sizeof(mData.desc)) == 0)
            {
                mDescIdentifier = a.id;
                a.refCount++;
                return;
            }
        }

        // Not found, add it to the vector
        sDescIdentifier.push_back({mData.desc, identifier, 1});
        mDescIdentifier = identifier;
        identifier++;
    }

    size_t Material::getDescIdentifier() const
    {
        finalize();
        return mDescIdentifier;
    }

    void Material::finalize() const
    {
        if(mDescDirty)
        {
            updateDescIdentifier();
            normalize();
            updateTextureCount();
            updateDescString();
            mDescDirty = false; // setIntoParameterBlock() calls finalize(), need to clear the flag
            setIntoParameterBlock(mpParamBlock.get());
        }
    }

#define case_return_self(_a) case _a: return #_a;

    static std::string getLayerTypeStr(uint32_t type)
    {
        switch(type)
        {
            case_return_self(MatNone);
            case_return_self(MatLambert);
            case_return_self(MatConductor);
            case_return_self(MatDielectric);
            case_return_self(MatEmissive);
            case_return_self(MatUser);
        default:
            should_not_get_here();
            return "";
        }
    }

    static std::string getLayerNdfStr(uint32_t ndf)
    {
        switch(ndf)
        {
            case_return_self(NDFBeckmann);
            case_return_self(NDFGGX);
            case_return_self(NDFUser);
        default:
            should_not_get_here();
            return "";
        }
    }

    static std::string getLayerBlendStr(uint32_t blend)
    {
        switch(blend)
        {
            case_return_self(BlendFresnel);
            case_return_self(BlendConstant);
            case_return_self(BlendAdd);
        default:
            should_not_get_here();
            return "";
        }
    }

    static std::string getLayerIdByTypeString(const LayerIdxByType& lid)
    {
        std::string s = "{float3(0,0,0),";
        s += std::to_string(lid.id) + '}';
        return s;
    }

    void Material::updateDescString() const
    {
        mDescString = "{{";
        for (uint32_t layerId = 0; layerId < arraysize(mData.desc.layers); layerId++)
        {
            const MaterialLayerDesc& layer = mData.desc.layers[layerId];
            mDescString += '{' + getLayerTypeStr(layer.type) + ',';
            mDescString += getLayerNdfStr(layer.ndf) + ',';
            mDescString += getLayerBlendStr(layer.blending) + ',';
            mDescString += std::to_string(layer.hasTexture);
            mDescString += '}';
            if (layerId != arraysize(mData.desc.layers) - 1)
            {
                mDescString += ',';
            }
        }
        mDescString += "},";
        mDescString += std::to_string(mData.desc.hasAlphaMap) + ',' + std::to_string(mData.desc.hasNormalMap) + ',' + std::to_string(mData.desc.hasHeightMap) + ',' + std::to_string(mData.desc.hasAmbientMap);

        mDescString += ",{";
        for (uint32_t layerType = 0; layerType < MatNumTypes; layerType++)
        {
            mDescString += getLayerIdByTypeString(mData.desc.layerIdByType[layerType]);
            if (layerType != MatNumTypes - 1) mDescString += ',';
        }
        mDescString += "}}";
    }

    ParameterBlock::SharedConstPtr Material::getParameterBlock() const
    {
        finalize();
        return ParameterBlock::SharedConstPtr(mpParamBlock);
    }

    ReflectionType::SharedPtr reflectType(slang::TypeLayoutReflection* pSlangType);

    void Material::createParameterBlock()
    {
        // SLANG-INTEGRATION
        // to create a parameter block for material,
        // we only need to use reflection information from the `Material` shader struct type.
        if (spBlockReflection == nullptr)
        {
            GraphicsProgram::SharedPtr pProgram = GraphicsProgram::createFromFile("", "Framework/Shaders/MaterialBlock.slang");
            ProgramReflection::SharedConstPtr pReflection = pProgram->getActiveVersion()->getReflector();
            auto slangReq = pProgram->getActiveVersion()->slangRequest;
            auto reflection = spGetReflection(slangReq);
            auto materialType = spReflection_FindTypeByName(reflection, "Material");
            auto layout = spReflection_GetTypeLayout(reflection, materialType, SLANG_LAYOUT_RULES_DEFAULT);
            auto blockType = reflectType((slang::TypeLayoutReflection*)layout);
            auto blockReflection = ParameterBlockReflection::create("");
            blockReflection->setElementType(blockType);
            blockReflection->finalize();
            spBlockReflection = blockReflection;
            assert(spBlockReflection);
        }
        mpParamBlock = ParameterBlock::create(spBlockReflection, true);
    }
    StandardMaterial::SharedPtr StandardMaterial::create(const std::string & name)
    {
        auto mat = new StandardMaterial(name);
        return StandardMaterial::SharedPtr(mat);
    }
    StandardMaterial::~StandardMaterial()
    {
    }
    void StandardMaterial::createParameterBlock()
    {
        Material::createParameterBlock();
    }
    void StandardMaterial::finalize() const
    {
        if (mDescDirty)
        {
            bool hasDiffuse = false, hasSpecular = false, hasDielectric = false, hasEmisive = false;
            for (auto i = 0; i < MatMaxLayers; ++i)
            {
                auto t = mData.desc.layers[i].type;
                if (t == MatLambert)
                    hasDiffuse = true;
                else if (t == MatConductor)
                    hasSpecular = true;
                else if (t == MatDielectric)
                    hasDielectric = true;
                else if (t == MatEmissive)
                    hasEmisive = true;
            }
            std::stringstream strStream;
            strStream << "StandardMaterial<" << (hasDiffuse ? "1" : "0") << ", "
                << (hasSpecular ? "1" : "0") << ", "
                << (hasDielectric ? "1" : "0") << ", "
                << (hasEmisive ? "1" : "0") << ">";
            mpParamBlock->setTypeName(strStream.str());
        }
        Material::finalize();
    }
}
