
__exported import ShaderCommonImpl;
__import Shading;
__import Interfaces;
__import Lights;
__generic_param TMaterial : IMaterial;
typedef ShadingAttribsImpl<TMaterial.EvaluatedMaterial> ShadingAttribs;
ParameterBlock<TMaterial> gMaterial;
ParameterBlock<LightEnv> gLightEnv;