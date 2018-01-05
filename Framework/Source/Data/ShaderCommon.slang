
__exported import ShaderCommonImpl;
__import Shading;
__import Interfaces;
__generic_param TMaterial : IMaterial;
//typedef TMaterial.EvaluatedMaterialValues ShadingAttribs;
typedef ShadingAttribsImpl<PreparedMaterialData> ShadingAttribs;
ParameterBlock<TMaterial> gMaterial;