
__exported import ShaderCommonImpl;
__import Shading;
__import Interfaces;
__generic_param TMaterial : IMaterial;
typedef ShadingAttribsImpl<TMaterial.EvaluatedMaterial> ShadingAttribs;
ParameterBlock<TMaterial> gMaterial;